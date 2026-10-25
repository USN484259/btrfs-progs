#!/bin/bash
# Reproduce the "btrfs check --mode lowmem --repair SIGSEGV" issue.
#
# Usage:
#   repro.sh --src <src-tree> [--btrfs <btrfs-binary>] [--label NAME]
#            [--workdir DIR] [--scenario a|b|c|all] [--keep]
#
# The script builds a set of helper tools from <src-tree>, creates synthetic
# filesystems that are corrupted the same way as the reported one (tree
# blocks that are still referenced but have lost their extent tree items),
# then runs `btrfs check --mode lowmem --repair` on them with the binary
# under test and reports what happens.
#
# Run it twice: once with a tree *without* the fix commits ("before") and
# once with them applied ("after").  Compare the summaries.
#
# Must be run on a filesystem that allows executing binaries (not noexec).

set -u

WORK=${WORK:-"$PWD/repro-work"}
LABEL=""
SCEN="all"
KEEP=0
BTRFS=""

usage() {
	cat <<EOF
usage: $0 --src <src-tree> [options]
  --src <dir>      btrfs-progs checkout with a built btrfs binary (required)
  --btrfs <path>   binary under test (default: <src>/btrfs)
  --label <name>   label printed in the summary (e.g. before/after/fixed)
  --workdir <dir>  scratch dir (default: ./repro-work, must allow exec)
  --scenario <a|b|c|all>  which scenario to run
  --keep           do not clean the scratch dir
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--src) SRC=$(realpath "$2"); shift 2;;
		--btrfs) BTRFS=$(realpath "$2"); shift 2;;
		--label) LABEL="$2"; shift 2;;
		--workdir) WORK=$(realpath "$2"); shift 2;;
		--scenario) SCEN="$2"; shift 2;;
		--keep) KEEP=1; shift;;
		-h|--help) usage;;
		*) echo "unknown option: $1"; usage;;
	esac
done

if [ -z "${SRC:-}" ]; then usage; fi
if [ ! -x "$SRC/btrfs" ]; then
	echo "error: $SRC/btrfs not found or not executable. Configure and build the tree first." >&2
	exit 1
fi
BTRFS=${BTRFS:-$SRC/btrfs}
BINDIR=$(dirname "$BTRFS")
mkdir -p "$WORK/bin"
if ! cmp -s "$BTRFS" "$SRC/btrfs"; then
	echo "note: --btrfs is not $SRC/btrfs, but mkfs/corrupt-block/dump-tree will be"
	echo "      taken from $SRC. For a meaningful comparison use the same build."
fi

# ---------------------------------------------------------------------------
# build the helper tools from the same source tree
# ---------------------------------------------------------------------------
HERE=$(dirname "$(realpath "$0")")
if ! bash "$HERE/build-tools.sh" "$SRC" "$WORK/bin" >"$WORK/build.log" 2>&1; then
	echo "error: could not build helper tools (see $WORK/build.log)" >&2
	exit 1
fi
NOCW_DEL="$WORK/bin/btrfs-nocow-del"
NOCW_KEY="$WORK/bin/btrfs-nocow-key"
TXABORT="$WORK/bin/btrfs-txabort"

# on-disk format constants, detected from the source tree
fs_tree=$(sed -n 's/^#define BTRFS_FS_TREE_OBJECTID[[:space:]]*//p' \
	"$SRC/kernel-shared/uapi/btrfs_tree.h" | head -1)
meta_key=$(sed -n 's/^#define BTRFS_METADATA_ITEM_KEY[[:space:]]*//p' \
	"$SRC/kernel-shared/uapi/btrfs_tree.h" | head -1)
fs_tree=${fs_tree%ULL}; meta_key=${meta_key%ULL}
echo "detected: FS_TREE=$fs_tree METADATA_ITEM_KEY=$meta_key"

dump_tree() {
	"$SRC/btrfs" inspect-internal dump-tree "$@"
}

# ---------------------------------------------------------------------------
# shared helpers to build the corrupted filesystem images
# ---------------------------------------------------------------------------
make_seed() {
	local img=$1
	# enough files (with subdirectories) to get a level >= 1 fs tree
	local rd="$WORK/rootdir"
	rm -rf "$rd"; mkdir -p "$rd/d1/d2/d3"
	for i in $(seq 1 180); do echo "payload $i" > "$rd/f$i.txt"; done
	for i in $(seq 1 120); do echo "payload $i" > "$rd/d1/d2/d3/g$i.txt"; done
	# disable the free space tree: with it, the check would abort in
	# add_new_free_space() once the corrupted blocks get reused, which is
	# a different (related) crash and distracts from the target signature
	"$BINDIR/mkfs.btrfs" -f -O ^free-space-tree -r "$rd" -b 500M "$img" \
		>"$WORK/mkfs.log" 2>&1 || {
		echo "error: mkfs.btrfs failed (see $WORK/mkfs.log)"; exit 1; }
}

# fs tree root node: bytenr and level; first (lowest) DIR_ITEM hash of inode 256
fs_info() {
	dump_tree -t "$fs_tree" "$1" 2>/dev/null | awk '
		/^node [0-9]+ level [0-9]+/{ if (!node) { node=$2; level=$4 } }
		/key \(256 DIR_ITEM [0-9]+\)/{ if (!di) di=$6 }
		END { gsub(/[()]/, "", di); print node, level, di }'
}

# root directory (inode 256) leaf bytenr
rootdir_leaf() {
	dump_tree -t "$fs_tree" "$1" 2>/dev/null |
		awk '/key \(256 INODE_ITEM 0\) block [0-9]+/{ print $6; exit }'
}

# slot sanity helper: this really is a node/leaf of the fs tree
check_block() {
	local img=$1 bytenr=$2 what=$3
	dump_tree -t "$fs_tree" "$img" 2>/dev/null |
		grep -E "^(node|leaf) $bytenr " | grep -q "owner FS_TREE" || {
			echo "error: block $bytenr is not an fs-tree $what (unexpected layout)" >&2
			return 1; }
}

check_one() {
	local img=$1 base
	local rc sig
	base=$(basename "$img")
	timeout 600 "$BTRFS" check --mode lowmem -p --repair --force "$img" \
		> "$WORK/$base.check.log" 2>&1
	rc=$?
	sig=$(grep -ac "Segmentation fault" "$WORK/$base.check.log")
	c1=$(grep -ac "commit_root already set when starting transaction" "$WORK/$base.check.log")
	c2=$(grep -ac "unable to find ref byte nr" "$WORK/$base.check.log")
	c3=$(grep -ac "Failed to find \[" "$WORK/$base.check.log")
	echo "      exit code      : $rc"
	echo "      SIGSEGV        : $([ "$sig" -gt 0 ] && echo yes || echo no)"
	echo "      'commit_root already set' x $c1"
	echo "      'unable to find ref byte nr' x $c2"
	echo "      'Failed to find [..]' x $c3"
}

# ---------------------------------------------------------------------------
# scenario A: live fs-tree blocks with their extent items missing
#   -> reproduces the reported console signature:
#      "unable to find ref byte nr ..." + "Failed to find [..]" +
#      "commit_root already set when starting transaction"
# ---------------------------------------------------------------------------
scenario_a() {
	echo
	echo "== scenario A: missing extent items for live fs-tree blocks"
	local img="$WORK/imgA"
	make_seed "$img"

	local di
	di=$(dump_tree -t "$fs_tree" "$img" 2>/dev/null | grep -m1 "key (256 DIR_ITEM" | awk '{gsub(/[()]/, "", $6); print $6}')
	if [ -z "$di" ]; then echo "error: no root dir item found"; return 1; fi

	# 1) corrupt the name of one root-dir dir item (hash mismatch).
	#    This CoWs the fs tree, so the block bytenrs must be re-read after
	#    this step.
	"$BINDIR/btrfs-corrupt-block" -D "256,84,$di" -f name "$img" >/dev/null 2>&1
	# 2) remove the extent tree items of the fs root node and the root dir leaf,
	#    in place (no CoW) so the blocks are still referenced and keep their data
	local node level leaf
	read -r node level _ <<< "$(fs_info "$img")"
	leaf=$(rootdir_leaf "$img")
	check_block "$img" "$node" node || return 1
	check_block "$img" "$leaf" leaf || return 1
	echo "   fs tree root node $node (level $level), root dir leaf $leaf, dir item hash $di"

	"$NOCW_DEL" "$img" "$node" "$meta_key" "$level" "$leaf" "$meta_key" 0 \
		>>"$WORK/scen_a.log" 2>&1 || {
			echo "error: nocow-del failed (see $WORK/scen_a.log)"; return 1; }

	echo "   running: $BTRFS check --mode lowmem --repair"
	check_one "$img"
}

# ---------------------------------------------------------------------------
# scenario B: extent items with a corrupted (too high) metadata level
#   -> the pre-fix code crashes with SIGSEGV in check_tree_block_backref()
# ---------------------------------------------------------------------------
scenario_b() {
	echo
	echo "== scenario B: extent item levels higher than the tree depth"
	local img="$WORK/imgB"
	make_seed "$img"

	local di
	di=$(dump_tree -t "$fs_tree" "$img" 2>/dev/null | grep -m1 "key (256 DIR_ITEM" | awk '{gsub(/[()]/, "", $6); print $6}')
	if [ -z "$di" ]; then echo "error: no root dir item found"; return 1; fi

	"$BINDIR/btrfs-corrupt-block" -D "256,84,$di" -f name "$img" >/dev/null 2>&1
	# set both metadata item levels to 6 (out of range for a 1-2 level tree)
	local node level leaf
	read -r node level _ <<< "$(fs_info "$img")"
	leaf=$(rootdir_leaf "$img")
	check_block "$img" "$node" node || return 1
	check_block "$img" "$leaf" leaf || return 1
	echo "   fs tree root node $node (level $level), root dir leaf $leaf, dir item hash $di"

	"$NOCW_KEY" "$img" "$node" "$meta_key" "$level" 6 "$leaf" "$meta_key" 0 6 \
		>>"$WORK/scen_b.log" 2>&1 || {
			echo "error: nocow-key failed (see $WORK/scen_b.log)"; return 1; }

	echo "   running: $BTRFS check --mode lowmem --repair"
	check_one "$img"
}

# ---------------------------------------------------------------------------
# scenario C: direct regression test of the failed-commit state cleanup
# ---------------------------------------------------------------------------
scenario_c() {
	echo
	echo "== scenario C: transaction error-path cleanup (unit test)"
	echo "   running: $TXABORT $BINDIR/mkfs.btrfs"
	"$TXABORT" "$BINDIR/mkfs.btrfs" 2>&1 | tail -3 | sed 's/^/   /'
	if "$TXABORT" "$BINDIR/mkfs.btrfs" >/dev/null 2>&1; then
		echo "   RESULT: PASS (aborted transaction cleaned up)"
	else
		echo "   RESULT: FAIL (transaction state leaked after failed commit)"
	fi
}

# ---------------------------------------------------------------------------
case "$SCEN" in
	a) scenario_a ;;
	b) scenario_b ;;
	c) scenario_c ;;
	all) scenario_a; scenario_b; scenario_c ;;
	*) echo "unknown scenario: $SCEN"; usage ;;
esac

echo
echo "===================== SUMMARY ($LABEL) ====================="
echo "src tree       : $SRC"
echo "binary under test : $BTRFS"
echo "logs           : $WORK/*.log"
[ "$KEEP" = 0 ] && { echo "(use --keep to retain $WORK)"; }
exit 0