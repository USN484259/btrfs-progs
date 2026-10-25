/*
 * Nocow delete of extent tree items (no transaction, no CoW, no commit).
 *
 * Deletes the given key from the extent tree by directly editing the leaf
 * in place and writing the leaf to disk.  The block data stays at its bytenr
 * and the free-space state is not updated, mimicking a filesystem where
 * extent items went missing due to I/O errors while blocks were still in use.
 *
 * Usage: btrfs-nocow-del <device> <bytenr> <type> <offset> [more keys...]
 */
#include <stdio.h>
#include <errno.h>
#include "kerncompat.h"
#include "kernel-shared/ctree.h"
#include "kernel-shared/disk-io.h"
#include "kernel-shared/transaction.h"
#include "kernel-shared/volumes.h"
#include "kernel-shared/accessors.h"

static int nocow_del(struct btrfs_fs_info *fs_info,
		     struct btrfs_root *extent_root, struct btrfs_key *key)
{
	struct btrfs_path *path;
	struct extent_buffer *leaf;
	u32 nritems;
	int slot, ret;

	path = btrfs_alloc_path();
	if (!path)
		return -ENOMEM;

	/* read-only search, no CoW */
	ret = btrfs_search_slot(NULL, extent_root, key, path, 0, 0);
	if (ret != 0) {
		fprintf(stderr, "search (%llu %u %llu) not found: %d\n",
			key->objectid, key->type, key->offset, ret);
		goto out;
	}

	leaf = path->nodes[0];
	slot = path->slots[0];
	nritems = btrfs_header_nritems(leaf);
	if (slot == 0 || nritems <= 1) {
		fprintf(stderr, "refusing to delete leaf-first/only item\n");
		ret = -EINVAL;
		goto out;
	}

	printf("Deleting (nocow) [%llu %u %llu] from leaf %llu slot %d\n",
	       key->objectid, key->type, key->offset, leaf->start, slot);
	ret = btrfs_del_items(NULL, extent_root, path, slot, 1);
	if (ret) {
		fprintf(stderr, "btrfs_del_items failed: %d\n", ret);
		goto out;
	}
	btrfs_mark_buffer_dirty(leaf);

	/* Write the modified leaf straight to disk, no transaction/commit. */
	ret = write_tree_block(NULL, fs_info, leaf);
	if (ret)
		fprintf(stderr, "write_tree_block failed: %d\n", ret);
out:
	btrfs_free_path(path);
	return ret;
}

int main(int argc, char **argv)
{
	struct btrfs_root *root, *extent_root;
	struct btrfs_key key;
	int i, ret = 0;

	if (argc < 5 || (argc - 2) % 3 != 0) {
		fprintf(stderr,
			"usage: %s <dev> <bytenr type offset> [<bytenr type offset> ...]\n",
			argv[0]);
		return 1;
	}
	root = open_ctree(argv[1], 0, OPEN_CTREE_WRITES);
	if (!root) {
		fprintf(stderr, "open_ctree failed\n");
		return 1;
	}
	for (i = 2; i + 2 < argc; i += 3) {
		key.objectid = strtoull(argv[i], NULL, 0);
		key.type = strtoull(argv[i + 1], NULL, 0);
		key.offset = strtoull(argv[i + 2], NULL, 0);
		extent_root = btrfs_extent_root(root->fs_info, key.objectid);
		ret = nocow_del(root->fs_info, extent_root, &key);
		if (ret)
			break;
	}
	close_ctree(root);
	return ret;
}