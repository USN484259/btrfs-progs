/*
 * Nocow corrupt of an extent tree item key (changes the key offset).
 *
 * Rewrites the on-disk item key offset in place (no transaction/CoW), e.g.
 * to make a METADATA_ITEM's level value inconsistent so that the affected
 * tree block can not be referenced/freed anymore, while the block itself
 * remains accounted as used (item still present), mimicking I/O error
 * corruption on a real filesystem.
 *
 * Usage: btrfs-nocow-key <device> <bytenr> <type> <oldoffset> <newoffset> [...]
 */
#include <stdio.h>
#include <errno.h>
#include "kerncompat.h"
#include "kernel-shared/ctree.h"
#include "kernel-shared/disk-io.h"
#include "kernel-shared/transaction.h"
#include "kernel-shared/volumes.h"
#include "kernel-shared/accessors.h"

static int nocow_key(struct btrfs_fs_info *fs_info,
		     struct btrfs_root *extent_root, struct btrfs_key *key,
		     u64 new_offset)
{
	struct btrfs_path *path;
	struct btrfs_key new_key = *key;
	struct extent_buffer *leaf;
	int ret;

	path = btrfs_alloc_path();
	if (!path)
		return -ENOMEM;

	ret = btrfs_search_slot(NULL, extent_root, key, path, 0, 0);
	if (ret != 0) {
		fprintf(stderr, "search (%llu %u %llu) not found: %d\n",
			key->objectid, key->type, key->offset, ret);
		goto out;
	}

	leaf = path->nodes[0];
	if (path->slots[0] == 0) {
		fprintf(stderr, "refusing to corrupt leaf-first item\n");
		ret = -EINVAL;
		goto out;
	}

	new_key.offset = new_offset;
	printf("Corrupting (nocow) key (%llu %u %llu) -> offset %llu "
	       "in leaf %llu slot %d\n", key->objectid, key->type,
	       key->offset, new_offset, leaf->start, path->slots[0]);
	btrfs_set_item_key_safe(fs_info, path, &new_key);

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

	if (argc < 7 || (argc - 2) % 4 != 0) {
		fprintf(stderr,
			"usage: %s <dev> <bytenr type oldoff newoff> [<bytenr type oldoff newoff> ...]\n",
			argv[0]);
		return 1;
	}
	root = open_ctree(argv[1], 0, OPEN_CTREE_WRITES);
	if (!root) {
		fprintf(stderr, "open_ctree failed\n");
		return 1;
	}
	for (i = 2; i + 3 < argc; i += 4) {
		key.objectid = strtoull(argv[i], NULL, 0);
		key.type = strtoull(argv[i + 1], NULL, 0);
		key.offset = strtoull(argv[i + 2], NULL, 0);
		extent_root = btrfs_extent_root(root->fs_info, key.objectid);
		ret = nocow_key(root->fs_info, extent_root, &key,
				strtoull(argv[i + 3], NULL, 0));
		if (ret)
			break;
	}
	close_ctree(root);
	return ret;
}