#!/usr/bin/env bash
#
# End-to-end tests for git-purge-history.sh, on a synthetic repository served over file://.
# Requirements: the same as the script (git >= 2.36, git-filter-repo in PATH).
# Usage: ./test.sh            (KEEP_TMP=1 ./test.sh keeps the sandbox for inspection)

set -eEuo pipefail
export LC_ALL=C

if ! git filter-repo --version >/dev/null 2>&1; then
  echo "git-filter-repo is not reachable ('git filter-repo --version' fails): add its directory to PATH first." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/git-purge-history.sh"
SANDBOX="$(mktemp -d)"

# A failure outside any assertion aborts the run (set -e): remember where, report it on exit.
# Failures inside assertions run in a condition context and do not trigger the ERR trap.
ERR_AT=""
FINISHED=0
trap 'ERR_AT="${ERR_AT:-line $LINENO: $BASH_COMMAND}"' ERR
on_exit() {
  local status=$?
  if (( status != 0 && FINISHED == 0 )); then
    echo "ABORTED (exit $status) at ${ERR_AT:-an unknown location}" >&2
  fi
  if [[ "${KEEP_TMP:-0}" == "1" ]]; then
    echo "sandbox kept: $SANDBOX"
  else
    rm -rf "$SANDBOX"
  fi
}
trap on_exit EXIT

# Isolate git from the user's configuration.
printf '[init]\n\tdefaultBranch = master\n[user]\n\tname = test\n\temail = test@example.invalid\n[advice]\n\tdetachedHead = false\n' > "$SANDBOX/gitconfig"
export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" GIT_CONFIG_NOSYSTEM=1

# file:// URL of a directory; on Git for Windows the URL needs the Windows form of the path.
file_url() { local d; d="$(cd "$1" && { pwd -W 2>/dev/null || pwd; })"; printf 'file:///%s\n' "${d#/}"; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok     - %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf 'NOT OK - %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else ko "$desc"; fi; }
summary() { echo; printf '%d passed, %d failed\n' "$PASS" "$FAIL"; }
run_tool() { local log="$1"; shift; bash "$SCRIPT" "$@" < /dev/null > "$log" 2>&1; }
# Runs a step that later tests depend on: stop everything if it fails.
setup_step() {
  local log="$1"; shift
  if ! run_tool "$log" "$@"; then
    echo "SETUP FAILED: $*" >&2
    cat "$log" >&2
    summary
    FINISHED=1
    exit 1
  fi
}
random_file() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/urandom > "$1"; }

# Assertion helpers. Each one fails when its log or repository cannot be read, so that a missing
# workdir never makes a negative assertion ("X is absent") pass.
contains() { [[ -f "$1" ]] && grep -q -- "$2" "$1"; }
not_contains() { [[ -f "$1" ]] && ! grep -q -- "$2" "$1"; }
paths_in_history() {
  local objects
  objects="$(git -C "$1" rev-list --objects --all)" || return 1
  awk '{ $1 = ""; print substr($0, 2) }' <<< "$objects"
}
has_history_path() { local p; p="$(paths_in_history "$1")" || return 1; grep -qx -- "$2" <<< "$p"; }
no_history_path_prefix() { local p; p="$(paths_in_history "$1")" || return 1; ! grep -q -- "^$2" <<< "$p"; }
commit_subject_absent() { local s; s="$(git -C "$1" log --all --format=%s)" || return 1; ! grep -qx -- "$2" <<< "$s"; }
ref_count_is() { local r; r="$(git -C "$1" for-each-ref refs/heads refs/tags)" || return 1; [[ "$(grep -c . <<< "$r")" -eq "$2" ]]; }
pack_kib() { git -C "$1" count-objects -v | awk '$1 == "size-pack:" { print $2 }'; }
at_least_4x_smaller() { local a b; a="$(pack_kib "$1")" && b="$(pack_kib "$2")" && [[ -n "$a" && -n "$b" ]] && (( a * 4 < b )); }
same_rev() { local a b; a="$(git -C "$1" rev-parse --verify -q "$2")" && b="$(git -C "$3" rev-parse --verify -q "$4")" && [[ "$a" == "$b" ]]; }
tracked() { local s; s="$(git -C "$1" ls-files -- "$2")" || return 1; [[ -n "$s" ]]; }
untracked() { local s; s="$(git -C "$1" ls-files -- "$2")" || return 1; [[ -z "$s" ]]; }
clean_worktree() { local s; s="$(git -C "$1" status --porcelain)" || return 1; [[ -z "$s" ]]; }
no_blob_at_least() {
  local s
  s="$(git -C "$1" cat-file --batch-all-objects --batch-check='%(objecttype) %(objectsize)')" || return 1
  ! awk -v min="$2" '$1 == "blob" && $2 >= min { found = 1 } END { exit !found }' <<< "$s"
}

# ---------------------------------------------------------------------------------------------
# Fixture: a remote with large files under uploads/ and a vmlinuz file, two branches, an
# annotated and a lightweight tag, a merge, a note, and paths that look like the purged ones.
# ---------------------------------------------------------------------------------------------
REMOTE="$SANDBOX/remote.git"
DEV="$SANDBOX/dev"
git init -q --bare "$REMOTE"
URL="$(file_url "$REMOTE")"
git clone -q "$URL" "$DEV" 2>/dev/null

(
  cd "$DEV"
  mkdir -p src "dir with space/uploads"
  echo "readme" > README.md
  echo "<?php echo 1;" > src/app.php
  printf 'node_modules\n' > .gitignore
  git add -A && git commit -qm "c1 init"

  random_file uploads/images/a.jpg 200000
  random_file "uploads/files/doc é.pdf" 300000
  random_file uploads2/keep.bin 50000
  echo "not purged" > uploads.txt
  echo "nested, not purged" > "dir with space/uploads/x.txt"
  git add -A && git commit -qm "c2 uploads"

  random_file vmlinuz 400000
  echo "<?php echo 2;" > src/app.php
  git add -A && git commit -qm "c3 kernel by mistake"
  git tag -a v1 -m "release 1"

  git checkout -q -b feature
  random_file uploads/images/b.jpg 150000
  echo "<?php echo 'feature';" > src/feature.php
  git add -A && git commit -qm "f1 feature"
  git checkout -q master

  git rm -q vmlinuz && git commit -qm "c4 remove kernel"
  random_file uploads/images/a.jpg 200000
  git add -A && git commit -qm "c5 only uploads"
  printf 'node_modules\n/uploads\n' > .gitignore
  echo "<?php echo 3;" > src/app.php
  git add -A && git commit -qm "c6 ignore uploads"
  git merge -q --no-ff feature -m "c7 merge feature"
  git tag lw
  git notes add -m "a note" HEAD
  git push -q origin master feature v1 lw refs/notes/commits 2>/dev/null
)

# A deployed working copy (production): an upload modified in place by the CMS, a new upload.
PROD="$SANDBOX/prod"
git clone -q "$URL" "$PROD" 2>/dev/null
random_file "$PROD/uploads/images/a.jpg" 210000
cp "$PROD/uploads/images/a.jpg" "$SANDBOX/prod-a.jpg"
random_file "$PROD/uploads/images/new-upload.jpg" 1000

# A second deployed copy with an uncommitted code change.
PROD2="$SANDBOX/prod2"
git clone -q "$URL" "$PROD2" 2>/dev/null
echo "hotfix" >> "$PROD2/src/app.php"

# A clone made before the rewrite, used later to push the old history back.
OLD="$SANDBOX/old-clone"
git clone -q "$URL" "$OLD" 2>/dev/null

printf 'running tests in %s\n\n' "$SANDBOX"

# ---------------------------------------------------------------------------------------------
echo "# analyze"
run_tool "$SANDBOX/analyze.log" analyze --repo "$DEV" --top 5
check "analyze succeeds and reports uploads/" contains "$SANDBOX/analyze.log" "uploads/images/"
check "analyze flags vmlinuz as absent from HEAD" contains "$SANDBOX/analyze.log" "vmlinuz  \[not in HEAD\]"

# ---------------------------------------------------------------------------------------------
echo "# rewrite: argument and path validation"
if run_tool "$SANDBOX/typo.log" rewrite --url "$URL" --workdir "$SANDBOX/wd-typo" --path uplods; then
  ko "rewrite rejects a path absent from history"
else
  check "rewrite rejects a path absent from history" contains "$SANDBOX/typo.log" "is not in the history"
fi
if run_tool "$SANDBOX/badpath.log" rewrite --url "$URL" --workdir "$SANDBOX/wd-bad" --path ../etc; then
  ko "rewrite rejects '..' in paths"
else
  ok "rewrite rejects '..' in paths"
fi

# ---------------------------------------------------------------------------------------------
echo "# rewrite + verify"
printf '# comment\r\n\r\n./uploads/\r\n/vmlinuz\r\n' > "$SANDBOX/paths.txt"
WD1="$SANDBOX/wd1"
setup_step "$SANDBOX/rewrite1.log" rewrite --url "$URL" --workdir "$WD1" --paths-file "$SANDBOX/paths.txt"
ok "rewrite succeeds (paths file with CRLF, comments, ./ and / prefixes)"
check "paths normalized" bash -c "[[ \"\$(cat '$WD1/paths.txt')\" == \$'uploads\nvmlinuz' ]]"
check "verified.ok written" test -f "$WD1/verified.ok"
check "refs/notes/commits dropped and reported" contains "$WD1/dropped-refs.txt" "refs/notes/commits"
check "no uploads/ path left in rewritten history" no_history_path_prefix "$WD1/work.git" "uploads/"
check "no vmlinuz left in rewritten history" no_history_path_prefix "$WD1/work.git" "vmlinuz"
check "uploads2/keep.bin kept (prefix boundary)" has_history_path "$WD1/work.git" "uploads2/keep.bin"
check "uploads.txt kept" has_history_path "$WD1/work.git" "uploads.txt"
check "nested 'dir with space/uploads/x.txt' kept" has_history_path "$WD1/work.git" "dir with space/uploads/x.txt"
check "all 4 refs exist after rewrite" ref_count_is "$WD1/work.git" 4
check "commit that only touched uploads is dropped" commit_subject_absent "$WD1/work.git" "c5 only uploads"
check "rewritten repository is at least 4x smaller than the backup" at_least_4x_smaller "$WD1/work.git" "$WD1/backup.git"
check "commit-map available for server-side cleanup" test -s "$WD1/work.git/filter-repo/commit-map"
check "backup.git untouched (still contains uploads/)" has_history_path "$WD1/backup.git" "uploads/images/a.jpg"

if run_tool "$SANDBOX/reuse.log" rewrite --url "$URL" --workdir "$WD1" --path uploads; then
  ko "rewrite refuses a non-empty workdir"
else
  check "rewrite refuses a non-empty workdir" contains "$SANDBOX/reuse.log" "workdir is not empty"
fi

# Corrupt the rewritten repository behind the tool's back: verify must catch it.
WD_BAD="$SANDBOX/wd-corrupt"
setup_step "$SANDBOX/rewrite-bad.log" rewrite --url "$URL" --workdir "$WD_BAD" --path uploads --path vmlinuz
git clone -q "$WD_BAD/work.git" "$SANDBOX/corrupt-src" 2>/dev/null
echo "tampered" >> "$SANDBOX/corrupt-src/README.md"
git -C "$SANDBOX/corrupt-src" commit -qam "tamper"
git -C "$SANDBOX/corrupt-src" push -q origin master 2>/dev/null
if run_tool "$SANDBOX/verify-bad.log" verify --workdir "$WD_BAD"; then
  ko "verify detects a file changed outside the purged paths"
else
  check "verify detects a file changed outside the purged paths" contains "$SANDBOX/verify-bad.log" "FAIL refs/heads/master"
fi
check "verify failure removes verified.ok" test ! -f "$WD_BAD/verified.ok"
if run_tool "$SANDBOX/push-bad.log" push --workdir "$WD_BAD" --yes; then
  ko "push refuses an unverified workdir"
else
  check "push refuses an unverified workdir" contains "$SANDBOX/push-bad.log" "has not passed verification"
fi

# ---------------------------------------------------------------------------------------------
echo "# update-checkout before the remote is rewritten"
if run_tool "$SANDBOX/upd-early.log" update-checkout --repo "$PROD" --path uploads --path vmlinuz; then
  ko "update-checkout refuses while the upstream is not rewritten"
else
  check "update-checkout refuses while the upstream is not rewritten" contains "$SANDBOX/upd-early.log" "still contains"
fi
check "prod index untouched after refusal" tracked "$PROD" uploads

# ---------------------------------------------------------------------------------------------
echo "# push: interactive confirmation and race detection"
if run_tool "$SANDBOX/push-noyes.log" push --workdir "$WD1"; then
  ko "push without --yes and without a terminal refuses"
else
  check "push without --yes and without a terminal refuses" contains "$SANDBOX/push-noyes.log" "re-run with --yes"
fi

(cd "$DEV" && echo "late" > late.txt && git add late.txt && git commit -qm "late commit" && git push -q origin master 2>/dev/null)
RACER_SHA="$(git -C "$REMOTE" rev-parse refs/heads/master)"
if run_tool "$SANDBOX/push-race.log" push --workdir "$WD1" --yes; then
  ko "push refuses when the remote moved since the snapshot"
else
  check "push refuses when the remote moved since the snapshot" contains "$SANDBOX/push-race.log" "refs/heads/master was updated on the remote"
fi
check "remote untouched after refused push" bash -c "[[ \$(git -C '$REMOTE' rev-parse refs/heads/master) == '$RACER_SHA' ]]"

# ---------------------------------------------------------------------------------------------
echo "# rewrite again and push"
WD2="$SANDBOX/wd2"
setup_step "$SANDBOX/rewrite2.log" rewrite --url "$URL" --workdir "$WD2" --path uploads --path vmlinuz
ok "second rewrite succeeds"
if run_tool "$SANDBOX/push2.log" push --workdir "$WD2" --yes; then
  ok "push succeeds"
else
  ko "push succeeds"; cat "$SANDBOX/push2.log"
fi
check "push reports remote identical to rewritten repository" contains "$SANDBOX/push2.log" "remote branches and tags are identical"
check "push warns about refs/notes left on the remote" contains "$SANDBOX/push2.log" "refs/notes/commits"
FRESH="$SANDBOX/fresh-clone"
git clone -q --mirror "$URL" "$FRESH" 2>/dev/null
git -C "$FRESH" update-ref -d refs/notes/commits
check "fresh clone of the remote has no uploads/ in history" no_history_path_prefix "$FRESH" "uploads/"
check "fresh clone keeps late.txt pushed before the snapshot" has_history_path "$FRESH" "late.txt"
check "annotated tag v1 rewritten and still annotated" bash -c "[[ \$(git -C '$FRESH' cat-file -t v1) == tag ]]"

if run_tool "$SANDBOX/push3.log" push --workdir "$WD2" --yes; then
  check "push is idempotent (nothing to push on re-run)" contains "$SANDBOX/push3.log" "Nothing to push"
else
  ko "push is idempotent"; cat "$SANDBOX/push3.log"
fi

# A developer pushes an old branch from a pre-rewrite clone: the next push run must notice.
(cd "$OLD" && git checkout -q -b old-stuff && git push -q origin old-stuff 2>/dev/null)
if run_tool "$SANDBOX/push4.log" push --workdir "$WD2" --yes; then
  ko "push detects a branch created from a pre-rewrite clone"
else
  check "push detects a branch created from a pre-rewrite clone" contains "$SANDBOX/push4.log" "refs/heads/old-stuff was created"
fi
git -C "$REMOTE" update-ref -d refs/heads/old-stuff

# ---------------------------------------------------------------------------------------------
echo "# update-checkout on deployed copies"
if run_tool "$SANDBOX/upd2.log" update-checkout --repo "$PROD2" --path uploads --path vmlinuz; then
  ko "update-checkout refuses local changes outside purged paths"
else
  check "update-checkout refuses local changes outside purged paths" contains "$SANDBOX/upd2.log" "src/app.php"
fi
check "prod2 left untouched (uploads still tracked)" tracked "$PROD2" uploads

if run_tool "$SANDBOX/upd.log" update-checkout --repo "$PROD" --paths-file "$WD2/paths.txt" --gc; then
  ok "update-checkout succeeds on prod"
else
  ko "update-checkout succeeds on prod"; cat "$SANDBOX/upd.log"
fi
check "prod HEAD equals rewritten remote master" same_rev "$PROD" HEAD "$REMOTE" refs/heads/master
check "prod-modified upload kept byte for byte" cmp -s "$PROD/uploads/images/a.jpg" "$SANDBOX/prod-a.jpg"
check "untracked new upload kept" test -f "$PROD/uploads/images/new-upload.jpg"
check "other uploads kept" test -f "$PROD/uploads/files/doc é.pdf"
check "prod working copy clean" clean_worktree "$PROD"
check "prod no longer tracks uploads/" untracked "$PROD" uploads
check "prod tag v1 updated to the rewritten tag" same_rev "$PROD" v1 "$REMOTE" v1
check "prod reports no stale ref" not_contains "$SANDBOX/upd.log" "still point to the old history"
# Every purged blob in the fixture is >= 150000 bytes, every kept blob is smaller.
check "prod object store has no purged blob left after --gc" no_blob_at_least "$PROD" 150000

summary
FINISHED=1
if (( FAIL > 0 )); then exit 1; fi
