/*
 * Regression test for "btrfs check --repair" crash in btrfs_commit_transaction
 * (https://github.com/kdave/btrfs-progs issue-style analysis).
 *
 * Two bugs are exercised here:
 *
 *  1) kernel-shared/transaction.c error path of btrfs_commit_transaction()
 *     never marked the transaction aborted and never cleaned up the
 *     transaction handle nor root->commit_root, so all subsequent
 *     btrfs_start_transaction() calls failed with -EINVAL and the message
 *     "commit_root already set when starting transaction".
 *
 *  2) check/mode-lowmem.c repair_ternary_lowmem() did not check the return
 *     value of btrfs_start_transaction() and passed the ERR_PTR to
 *     btrfs_commit_transaction(), dereferencing garbage -> SIGSEGV.
 *
 * This test verifies that after a failed transaction commit the fs state is
 * cleaned up so that a new transaction can be started (or, when explicitly
 * aborted, that the failure is coherent -EROFS instead of a state leak).
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include "kerncompat.h"
#include "kernel-shared/ctree.h"
#include "kernel-shared/disk-io.h"
#include "kernel-shared/transaction.h"
#include "kernel-shared/volumes.h"

static int test_scenario_commit_root_cleared(struct btrfs_fs_info *fs_info)
{
	struct btrfs_root *root = fs_info->tree_root;
	struct btrfs_trans_handle *trans;
	int ret = 0;
	int start_ret;

	/*
	 * Start a transaction and force the error path in
	 * btrfs_commit_transaction() ("transaction_aborted" entry check ->
	 * goto error).
	 */
	trans = btrfs_start_transaction(root, 0);
	if (IS_ERR(trans)) {
		fprintf(stderr, "FAIL: cannot start transaction: %ld\n",
			PTR_ERR(trans));
		return 1;
	}

	btrfs_abort_transaction(trans, -EIO);

	ret = btrfs_commit_transaction(trans, root);
	if (ret != -EROFS) {
		fprintf(stderr, "FAIL: commit should return -EROFS, got %d\n",
			ret);
		return 1;
	}

	/*
	 * The buggy code left root->commit_root set and fs_info-
	 * >running_transaction dangling after a failed commit.  This caused
	 * every later btrfs_start_transaction() to fail with -EINVAL and the
	 * message "commit_root already set when starting transaction", which
	 * finally crashed the lowmem repair in repair_ternary_lowmem() by
	 * dereferencing the ERR_PTR.
	 * Ensure the failed commit left a clean state:
	 */
	if (root->commit_root != NULL || fs_info->running_transaction != NULL) {
		fprintf(stderr,
			"FAIL: leaked commit_root=%p running_transaction=%p after "
			"failed commit\n",
			(void *)root->commit_root,
			(void *)fs_info->running_transaction);
		return 1;
	}

	/*
	 * A subsequent start must fail coherently with -EROFS (fs aborted),
	 * not with -EINVAL due to leaked state.  -EROFS is handled properly
	 * by all repair call sites (IS_ERR check) -- most importantly by
	 * repair_ternary_lowmem() which must no longer crash.
	 */
	trans = btrfs_start_transaction(root, 0);
	start_ret = PTR_ERR(trans);
	if (!IS_ERR(trans)) {
		fprintf(stderr,
			"FAIL: transaction unexpectedly started after abort\n");
		btrfs_commit_transaction(trans, root);
		return 1;
	}
	if (start_ret != -EROFS) {
		fprintf(stderr,
			"FAIL: expected -EROFS after aborted fs, got %d\n",
			start_ret);
		return 1;
	}

	return 0;
}

int main(int argc, char **argv)
{
	struct btrfs_fs_info *fs_info;
	const char *mkfs_path = argc > 1 ? argv[1] : "./mkfs.btrfs";
	char devpath[] = "/tmp/tx_test_dev.XXXXXX";
	char cmd[512];
	int fd;
	int ret;

	fd = mkstemp(devpath);
	if (fd < 0) {
		perror("mkstemp");
		return 1;
	}
	if (ftruncate(fd, 256 * 1024 * 1024) < 0) {
		perror("ftruncate");
		unlink(devpath);
		return 1;
	}
	close(fd);

	snprintf(cmd, sizeof(cmd),
		 "%s -f -b 256M %s 2>/dev/null", mkfs_path, devpath);
	ret = system(cmd);
	if (ret) {
		fprintf(stderr, "mkfs failed: %d\n", ret);
		unlink(devpath);
		return 1;
	}

	fs_info = open_ctree_fs_info(&(struct open_ctree_args){
				.filename = devpath, .flags = 0 });
	if (!fs_info) {
		fprintf(stderr, "open_ctree failed\n");
		unlink(devpath);
		return 1;
	}

	ret = test_scenario_commit_root_cleared(fs_info);
	if (ret)
		fprintf(stderr, "SCENARIO 1 FAILED\n");
	else
		printf("SCENARIO 1 PASSED (state cleaned up after failed commit)\n");

	close_ctree_fs_info(fs_info);
	unlink(devpath);
	return ret;
}