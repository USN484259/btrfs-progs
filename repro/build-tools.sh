#!/bin/sh
# Build the reproduction helper tools against a local btrfs-progs source tree.
#
# Usage: build-tools.sh <src-tree> [<outdir>]
#
#   <src-tree>  a configured/built btrfs-progs checkout (make btrfs must work)
#   <outdir>    directory to place the built binaries into (default: ./bin)
#
# The tools use the same internal API as the btrfs binary, so they must be
# built from the same source tree (and with the same configure options) as
# the btrfs binary under test.
#
# Note: the tool sources are copied into the source tree temporarily because
# btrfs-progs' Makefile builds "btrfs-%" tools from top-level "btrfs-%.c"
# files.  They are removed again after the build.

set -u

SRC=${1:?usage: build-tools.sh <src-tree> [<outdir>]}
OUT=${2:-"$PWD/bin"}

if [ ! -f "$SRC/Makefile" ]; then
	echo "error: $SRC is not a btrfs-progs source tree (no Makefile)" >&2
	exit 1
fi
if [ ! -f "$SRC/include/config.h" ]; then
	echo "error: $SRC looks unconfigured (no include/config.h). Run autogen.sh + configure first." >&2
	exit 1
fi

HERE=$(dirname "$0")
TOOLS="btrfs-nocow-del btrfs-nocow-key btrfs-txabort"
DIRTY=""
trap 'for f in $DIRTY; do rm -f "$SRC/$f" "$SRC/$f.o"; done' EXIT

for t in $TOOLS; do
	cp "$HERE/tools/$t.c" "$SRC/" || exit 1
	DIRTY="$DIRTY $t"
done

( cd "$SRC" && make -j"$(nproc)" $TOOLS ) || exit 1

mkdir -p "$OUT"
for t in $TOOLS; do
	cp "$SRC/$t" "$OUT/" || exit 1
done
echo "tools installed in $OUT: $TOOLS"