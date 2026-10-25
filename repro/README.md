# Reproduction package: `btrfs check --mode lowmem --repair` crash

This directory contains a self-contained way to reproduce the issue
reported and verified for this btrfs-progs patch series:

1. `btrfs check --mode lowmem --repair` crashes (SIGSEGV/abort) when a
   transaction commit fails because the filesystem has live tree blocks
   whose extent-tree items are missing (I/O-error type corruption).
2. The crash is caused by two bugs fixed by the accompanying commits:
   - `kernel-shared/transaction.c`: a failed `btrfs_commit_transaction()`
     no longer cleans up its state (regression from 7af89c33), leaking
     `root->commit_root`, so every later
     `btrfs_start_transaction()` fails with -EINVAL
     ("commit_root already set when starting transaction").
   - `check/mode-lowmem.c`: `repair_ternary_lowmem()` and `delete_item()`
     do not check `btrfs_start_transaction()` for errors and dereference
     the ERR_PTR in `btrfs_commit_transaction()`.  Corrupted metadata
     item levels additionally NULL-deref in `check_tree_block_backref()`.

## Contents

- `tools/btrfs-nocow-del.c`  - in-place (no CoW) deletion of extent tree
                              items; mimics blocks that lost their extent
                              item while staying referenced
- `tools/btrfs-nocow-key.c`  - in-place corruption of an extent item key
- `tools/btrfs-txabort.c`    - unit test of the transaction error path
                              cleanup (fails on unfixed code, passes on
                              fixed code)
- `build-tools.sh`           - builds the tools against a local
                              btrfs-progs checkout
- `repro.sh`                 - main driver: builds the tools, creates the
                              corrupted test images and runs the check
                              binary under test

## Prerequisites

- two btrfs-progs checkouts with the same configure options:
    * `before/`  - at the base commit (without the fix commits)
    * `after/`   - with the fix commits applied
  each built (`./autogen.sh && ./configure ... && make -j`).
- a scratch directory on a filesystem that allows executing binaries
  (`/tmp` on some systems is `noexec`; use your home directory).

## Usage

Run the repro once against each tree and compare the summaries:

    BEFORE=$(pwd)/before
    AFTER=$(pwd)/after

    bash repro/repro.sh --src $BEFORE --workdir $HOME/work-before --label "BEFORE (unfixed)"
    bash repro/repro.sh --src $AFTER  --workdir $HOME/work-after  --label "AFTER (fixed)"

(The `--force` option is used so the repair confirmation countdown is skipped.)

## Expected results

| | BEFORE (unfixed) | AFTER (fixed commits) |
|---|---|---|
| scenario A (missing extent items) | exit 1; log contains `unable to find ref byte nr ...`, `Failed to find [..]`, **`commit_root already set when starting transaction`** | exit 1; **no** `commit_root already set`, no crash |
| scenario B (corrupted metadata level) | **SIGSEGV, exit 139** | exit 1, no crash |
| scenario C (transaction cleanup) | **FAIL**: `leaked commit_root=0x...` + `extent buffer leak` | **PASS**: state cleaned up |

Scenario A reproduces the exact console signature of the original report:

    ERROR: unable to find ref byte nr <bytenr> parent 0 root <X> owner 0 offset 0 ret -2
    Failed to find [<bytenr>, 168, 16384]
    ERROR: commit_root already set when starting transaction

(On the reported system the numbers were `367116288`, root `259`; on
newer on-disk formats the tree objectids differ.)

Each scenario stores the full `btrfs check` log for closer inspection
under `$WORKdir/<img>.check.log`.

## Notes

- The helper tools are compiled from the same source tree as the `btrfs`
  binary under test, so the generated image formats always match.
- `repro.sh` derives the on-disk format constants (FS_TREE objectid,
  METADATA_ITEM key) from the source headers, so it works with both the
  classic and the renumbered on-disk format.
- The images are rebuilt from scratch on every run; nothing needs
  root privileges or loop devices.