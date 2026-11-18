# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script, `git-purge-history.sh`, that removes paths from the whole history of a remote Git repository with git-filter-repo. It wraps the rewrite in a backup, an automated verification and a guarded push. `README.md` is the operator runbook. It is written in French and should stay in French. Code, comments and CLI messages are in English.

The tool force-pushes over shared repositories, so its value is in its safety checks. Any change must preserve the invariants below, and every new failure mode needs a test that asserts the refusal.

## Commands

```bash
./test.sh                  # full end-to-end suite (needs git >= 2.36 and git-filter-repo in PATH)
KEEP_TMP=1 ./test.sh       # keep the sandbox directory for inspection
bash -n git-purge-history.sh test.sh   # syntax check (no linter is configured)
```

No single test can be run on its own. `test.sh` is one sequential scenario, and later sections depend on the state left by earlier ones (`WD1` is rewritten and then refused at push because of a racing commit, `WD2` is pushed, then the prod copy is updated). To add a test, insert it at the point in the sequence where its preconditions hold.

Install git-filter-repo with `pip install git-filter-repo` (Windows: `py -m pip install --user git-filter-repo`), and make sure `git filter-repo --version` works.

Status as of 2026-11-18: the suite was written but has never been run. The first run may show bugs in either file.

## Architecture

### Subcommands and shared state

`main` creates `TMP_ROOT` (removed by an `EXIT` trap) and dispatches to `cmd_analyze`, `cmd_rewrite`, `cmd_verify`, `cmd_push` or `cmd_update_checkout`. Each of them parses its own arguments. Shared state lives in the globals `PATHS`, `WD`, `BACKUP`, `WORK`, `URL` and `TMP_ROOT`. Never create a temp directory inside `$(...)`: its trap would fire when the subshell exits.

`rewrite`, `verify` and `push` communicate only through the workdir, which `load_workdir` validates:

- `backup.git`: untouched mirror clone of the remote.
- `work.git`: a local mirror clone of `backup.git`. Every ref outside `refs/heads`/`refs/tags` is deleted from it (and listed in `dropped-refs.txt`), then git-filter-repo rewrites it without `--force`.
- `original-refs.txt`: `sha ref` lines for every branch and tag at snapshot time. It is the reference for both verification and push.
- `paths.txt` (normalized paths), `remote-url.txt`, `filter-repo.log`.
- `verified.ok`: the gate that `push` requires. `verify_workdir` deletes it first and recreates it only when every check passes.

`rewrite` refuses a non-empty workdir. A retry always starts from a fresh clone; nothing is reused.

### Path matching must stay consistent in three places

A purged path P is root-anchored: it matches the path P itself or anything under `P/`, never `P2/` nor `src/P`. Three places implement this, and they must agree:

1. git-filter-repo `--invert-paths --path P`.
2. `filter_out_paths` (awk). Verification uses it to compute "original tree minus purged paths".
3. `first_commit_with_path`: `git --literal-pathspecs log --full-history -- P`. It is used for the "path exists" check before rewriting, the "path gone" check after, the "upstream rewritten?" check in `update-checkout` and stale-ref detection.

`normalize_path` turns user input into this form: no leading `./` or `/`, no trailing `/`, and `..` is rejected. If you add another filter-repo option (globs, regexes, size limits), the verification must model it too. Otherwise it reports false failures or, worse, misses changes.

### Verification

For every ref in `original-refs.txt`, the script compares `ls-tree -r -z` of the old tree, filtered by `filter_out_paths`, with `ls-tree -r -z` of the rewritten tree. The two listings must be byte-identical (same blob SHAs, modes and paths). This proves that nothing outside the purged paths changed. Commit counts can differ, because filter-repo prunes commits that become empty.

### Push protocol (`cmd_push`)

An awk join of `original-refs.txt`, the rewritten refs and `git ls-remote --refs` gives each ref one of these states:

- `TODO`: the remote ref still equals the original. It is pushed with `--force-with-lease=ref:original_sha`.
- `DONE`: the remote ref already equals the rewritten ref. It is skipped, which is what makes `push` resumable after a partial failure.
- `ERROR`: the ref was updated, created or deleted on the remote since the snapshot. Any `ERROR` aborts before anything is pushed. This is also how a branch pushed again from a pre-rewrite clone is detected.

The `TODO` refs are pushed in `--atomic` batches of `PUSH_BATCH_SIZE`; batching keeps the command line under the Windows length limit. The push always targets the URL in `remote-url.txt`, never a configured remote. Afterwards, `ls-remote` must equal `work.git` exactly.

### `update-checkout` ordering is load-bearing

This subcommand updates a deployed copy, such as prod. Its steps must keep this order:

1. Refuse if tracked files outside the purged paths have local changes.
2. Count the files on disk under the purged paths.
3. Run `fetch --prune --force --tags`. Without `--force`, fetch refuses to update the rewritten tags.
4. Refuse if the upstream still contains a purged path. Otherwise, `reset --hard` would overwrite the on-disk files with the repository versions.
5. Run `rm -r --cached` on the purged paths, then `reset --hard`. Files that are no longer in the index are left alone.
6. Count again. If the count dropped, fail loudly.

## Shell conventions in this codebase

- The script runs with `set -euo pipefail` and `LC_ALL=C`. Under these settings:
  - Never pipe into `head`: it causes SIGPIPE failures under pipefail. Use `awk 'NR <= n'` instead.
  - Wrap `diff`, `grep -c` and similar commands with `|| true` wherever a non-zero exit is expected.
  - Use `x=$((x + 1))` rather than `((x++))`.
- `die` inside `$(...)` only exits the subshell. Propagate the failure explicitly with `p="$(normalize_path ...)" || exit 1`, as `add_path` does.
- Read git path listings with `-z | tr '\0' '\n'`, to avoid git's quoting of special characters.
- The target is bash >= 4 on Linux and on Windows Git Bash; macOS's bash 3.2 is not supported. On Git Bash, `git.exe` is a native binary and MSYS converts path arguments for it, so do not set `MSYS_NO_PATHCONV`. A `file://` URL needs the Windows form of the path (`pwd -W`; see `file_url` in `test.sh`).

## Test harness (`test.sh`)

- **Isolation**: git is cut off from the user's configuration (`GIT_CONFIG_GLOBAL` points to a sandbox file, `GIT_CONFIG_NOSYSTEM=1`). Remotes are bare repositories served over `file://`, so the suite makes no network access.
- **Fixture**: it covers every edge case the checks rely on: paths under `uploads/`, `vmlinuz`, look-alike paths that must survive (`uploads2/`, `uploads.txt`, `dir with space/uploads/`), a non-ASCII filename, an annotated tag, a lightweight tag, a merge, `refs/notes`, a commit that only touches purged paths, a prod clone with a modified and a new upload, a prod clone with an uncommitted code change, and a pre-rewrite clone used to re-push the old history.
- **Running the tool**: `run_tool` runs the script with stdin from `/dev/null`, so `push` without `--yes` exercises the non-terminal refusal.
- **Negative tests** assert both the non-zero exit and the error message, and, where relevant, that nothing changed (remote SHA, prod index).
