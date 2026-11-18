#!/usr/bin/env bash
#
# git-purge-history.sh - remove files or directories from the entire history of a remote Git
# repository, with a full backup, an automated verification and a guarded, resumable push.
#
# Run "git-purge-history.sh help" for usage.
# Requirements: bash >= 4, git >= 2.36, git-filter-repo in PATH (https://github.com/newren/git-filter-repo).

set -euo pipefail
export LC_ALL=C

readonly PROG="${0##*/}"
readonly PUSH_BATCH_SIZE=100
readonly TAB=$'\t'

# Globals filled by argument parsing or load_workdir.
PATHS=()
WD="" BACKUP="" WORK="" URL=""
TMP_ROOT=""

usage() {
  cat <<EOF
Usage:
  $PROG analyze [--repo DIR] [--depth N] [--top N]
      Read-only size report of the whole history of a local clone (default: current directory).
      Run "git fetch --all --prune" first so that every remote branch is taken into account.

  $PROG rewrite --url URL --workdir DIR (--path PATH)... [--paths-file FILE]
      1. mirror-clones URL into DIR/backup.git (never modified: keep it until the end);
      2. rewrites a copy, DIR/work.git, with git-filter-repo, removing PATH from every commit;
      3. verifies the result (see "verify"). Nothing is pushed.
      PATH is relative to the repository root: "uploads" removes the file or directory "uploads"
      at the root, not "src/uploads". DIR must be absent or empty.

  $PROG verify --workdir DIR
      Re-runs the checks done at the end of "rewrite":
        - no purged path remains in any rewritten branch or tag;
        - every branch and tag still exists and its tree is identical to the original tree minus
          the purged paths (no other file was changed or lost);
        - commit counts and repository sizes before/after, largest remaining blobs.

  $PROG push --workdir DIR [--yes] [--no-atomic]
      Force-pushes the rewritten branches and tags. Refuses if branches or tags changed on the
      remote since the backup (new commit, new branch, deleted branch). Every ref is pushed with
      --force-with-lease against its expected value, in atomic batches of $PUSH_BATCH_SIZE refs.
      Safe to re-run after a failure: refs already rewritten on the remote are skipped.

  $PROG update-checkout --repo DIR (--path PATH)... [--paths-file FILE] [--gc]
      For a deployed working copy (e.g. production) that cannot simply be re-cloned: untracks the
      purged paths while keeping their files on disk, fetches, and resets the current branch to
      its rewritten upstream. Refuses if tracked files outside the purged paths have local
      changes, or if the upstream still contains the purged paths. --gc then removes the old
      history from the local object store.

Paths files: one path per line; blank lines and lines starting with # are ignored.
EOF
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

info()  { printf '%s\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
title() { printf '\n== %s ==\n' "$*"; }

human_kib() {
  awk -v k="$1" 'BEGIN {
    split("KiB MiB GiB TiB", u, " "); i = 1
    while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf "%.1f %s", k, u[i] }'
}

# Size of the object store of a repository, in KiB (packed + loose).
repo_kib() {
  git -C "$1" count-objects -v | awk '$1 == "size:" || $1 == "size-pack:" { s += $2 } END { print s + 0 }'
}

count_lines() { awk 'END { print NR }' "$1"; }

# Prints stdin indented, at most 10 lines, then the total when there were more. Path lists can
# hold thousands of entries: per-path output must go through this.
print_some() {
  awk 'NR <= 10 { print "  " $0 } END { if (NR > 10) print "  ... (" NR " in total)" }'
}

require_git_version() {
  local v major minor
  v="$(git --version | awk '{ print $3 }')"
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  if (( major < 2 || (major == 2 && minor < 36) )); then
    die "git >= 2.36 is required (found $v)"
  fi
}

require_filter_repo() {
  require_git_version
  if ! git filter-repo --version >/dev/null 2>&1; then
    die "git-filter-repo not found in PATH.
  Install it:  pip install git-filter-repo   (Windows: py -m pip install --user git-filter-repo)
  and make sure the Python 'Scripts' directory is in PATH (git must find 'git-filter-repo')."
  fi
}

# Normalizes a user-supplied path to the form used by git-filter-repo: relative to the repository
# root, forward slashes, no leading "./" or "/", no trailing "/".
normalize_path() {
  local p="$1"
  # Paths reach git-filter-repo through a line-based file (see cmd_rewrite).
  case "$p" in
    *$'\n'* | *$'\r'*) die "invalid path: line breaks are not supported" ;;
    *'==>'*) die "invalid path '$1': git-filter-repo would read '==>' as a rename" ;;
  esac
  p="${p//\\//}"
  while [[ "$p" == ./* ]]; do p="${p#./}"; done
  while [[ "$p" == /* ]]; do p="${p#/}"; done
  while [[ "$p" == */ ]]; do p="${p%/}"; done
  [[ -n "$p" ]] || die "invalid path '$1': empty after normalization"
  case "/$p/" in
    */../* | */./* | *//*) die "invalid path '$1'" ;;
  esac
  printf '%s\n' "$p"
}

add_path() {
  local p
  p="$(normalize_path "$1")" || exit 1
  PATHS+=("$p")
}

read_paths_file() {
  local file="$1" line
  [[ -f "$file" ]] || die "paths file not found: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]]; then continue; fi
    add_path "$line"
  done < "$file"
}

# Filters out of stdin the lines whose path is one of the paths listed in file $1, or is below one
# of them. Line format $2: "ls-tree" (path after the first TAB) or "plain" (the whole line).
filter_out_paths() {
  awk -v pf="$1" -v fmt="$2" '
    BEGIN { n = 0; while ((getline line < pf) > 0) { sub(/\r$/, "", line); if (line != "") P[++n] = line } close(pf) }
    {
      if (fmt == "ls-tree") { path = substr($0, index($0, "\t") + 1) } else { path = $0 }
      for (k = 1; k <= n; k++) {
        if (path == P[k] || substr(path, 1, length(P[k]) + 1) == P[k] "/") next
      }
      print
    }'
}

# Prints the first commit reachable from REV (a revision or --all) whose tree contains PATH.
first_commit_with_path() {
  local repo="$1" rev="$2" path="$3"
  git --literal-pathspecs -C "$repo" log "$rev" --full-history --format=%H -n 1 -- "$path"
}

# Writes one line per blob reachable from any ref: "raw_size TAB stored_size TAB path".
scan_blobs() {
  local repo="$1" out="$2"
  git -C "$repo" rev-list --objects --all \
    | git -C "$repo" cat-file --batch-check="%(objecttype)${TAB}%(objectsize)${TAB}%(objectsize:disk)${TAB}%(rest)" \
    | awk -F'\t' '$1 == "blob" { print $2 "\t" $3 "\t" $4 }' > "$out"
}

# Sums stored sizes by path prefix of the given depth. With a HEAD path list, only counts blobs
# whose path is absent from HEAD (files that only exist in history).
report_by_dir() {
  local blobs="$1" depth="$2" top="$3" head_file="${4:-}"
  awk -F'\t' -v depth="$depth" -v head="$head_file" '
    BEGIN { if (head != "") while ((getline l < head) > 0) inhead[l] = 1 }
    {
      path = $3
      if (head != "" && (path in inhead)) next
      n = split(path, parts, "/")
      key = parts[1]
      for (i = 2; i <= depth && i <= n; i++) key = key "/" parts[i]
      if (n > depth) key = key "/"
      stored[key] += $2; count[key]++
    }
    END { for (k in stored) printf "%d\t%d\t%s\n", stored[k], count[k], k }' "$blobs" \
    | sort -t"$TAB" -k1,1nr \
    | awk -F'\t' -v top="$top" 'NR <= top { printf "%10.1f MiB %8d blobs  %s\n", $1 / 1048576, $2, $3 }'
}

report_by_extension() {
  local blobs="$1" top="$2"
  awk -F'\t' '
    {
      n = split($3, parts, "/"); base = parts[n]
      m = split(base, dot, "."); ext = (m > 1 && dot[1] != "" ? tolower(dot[m]) : "(none)")
      if (m > 2 && dot[1] == "") ext = tolower(dot[m])
      stored[ext] += $2; count[ext]++
    }
    END { for (k in stored) printf "%d\t%d\t%s\n", stored[k], count[k], k }' "$blobs" \
    | sort -t"$TAB" -k1,1nr \
    | awk -F'\t' -v top="$top" 'NR <= top { printf "%10.1f MiB %8d blobs  %s\n", $1 / 1048576, $2, $3 }'
}

report_largest_blobs() {
  local blobs="$1" top="$2" head_file="$3"
  sort -t"$TAB" -k2,2nr "$blobs" \
    | awk -F'\t' -v top="$top" -v head="$head_file" '
        BEGIN { while ((getline l < head) > 0) inhead[l] = 1 }
        NR <= top { printf "%10.1f MiB  %s%s\n", $2 / 1048576, $3, ($3 in inhead ? "" : "  [not in HEAD]") }'
}

# Warns when purged paths are not ignored by the root .gitignore of the default branch of REPO:
# otherwise they will be committed again sooner or later.
warn_if_not_ignored() {
  local repo="$1" probe="$TMP_ROOT/ignore-probe" p not_ignored=()
  rm -rf "$probe"
  git init -q "$probe"
  git -C "$probe" config core.excludesFile .git/info/no-global-excludes
  git -C "$repo" show HEAD:.gitignore > "$probe/.gitignore" 2>/dev/null || : > "$probe/.gitignore"
  for p in "${PATHS[@]}"; do
    if ! git -C "$probe" check-ignore -q --no-index -- "$p" && ! git -C "$probe" check-ignore -q --no-index -- "$p/probe"; then
      not_ignored+=("$p")
    fi
  done
  if (( ${#not_ignored[@]} > 0 )); then
    warn "${#not_ignored[@]} purged path(s) not ignored by the root .gitignore of the default branch: add them, or they will be committed again."
    printf '%s\n' "${not_ignored[@]}" | print_some >&2
  fi
}

load_workdir() {
  local wd="$1" line
  [[ -n "$wd" ]] || die "--workdir is required"
  for f in backup.git work.git paths.txt original-refs.txt remote-url.txt; do
    [[ -e "$wd/$f" ]] || die "not a workdir created by '$PROG rewrite' ($f missing): $wd"
  done
  WD="$(cd "$wd" && pwd)"
  BACKUP="$WD/backup.git"
  WORK="$WD/work.git"
  URL="$(awk 'NR == 1' "$WD/remote-url.txt")"
  PATHS=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then PATHS+=("$line"); fi
  done < "$WD/paths.txt"
  (( ${#PATHS[@]} > 0 )) || die "no path in $WD/paths.txt"
}

# ---------------------------------------------------------------------------------------------
# analyze
# ---------------------------------------------------------------------------------------------

cmd_analyze() {
  local repo="." depth=2 top=20
  while (( $# )); do
    case "$1" in
      --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
      --depth) depth="${2:?--depth needs a value}"; shift 2 ;;
      --top) top="${2:?--top needs a value}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "analyze: unknown argument '$1'" ;;
    esac
  done
  [[ "$depth" =~ ^[1-9][0-9]*$ && "$top" =~ ^[1-9][0-9]*$ ]] || die "--depth and --top must be positive integers"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $repo"

  local blobs="$TMP_ROOT/blobs.tsv" head="$TMP_ROOT/head.txt"
  info "Scanning every object reachable from any ref (can take a few minutes on large repositories)..."
  scan_blobs "$repo" "$blobs"
  if ! git -C "$repo" ls-tree -r -z --name-only HEAD 2>/dev/null | tr '\0' '\n' > "$head"; then
    : > "$head"
  fi

  title "Totals"
  info "Object store on disk: $(human_kib "$(repo_kib "$repo")")"
  awk -F'\t' '{ n++; raw += $1; disk += $2 }
    END { printf "Blobs in history:     %d (%.1f MiB uncompressed, %.1f MiB stored)\n", n, raw / 1048576, disk / 1048576 }' "$blobs"

  title "Stored size by path, depth $depth (whole history)"
  report_by_dir "$blobs" "$depth" "$top"
  title "Stored size by path, depth $depth (paths absent from HEAD: history only)"
  report_by_dir "$blobs" "$depth" "$top" "$head"
  title "Stored size by extension"
  report_by_extension "$blobs" "$top"
  title "Largest blobs (stored size)"
  report_largest_blobs "$blobs" "$top" "$head"
  info ""
  info "Stored sizes are delta-compressed sizes in the packs: they add up to the object store size."
}

# ---------------------------------------------------------------------------------------------
# rewrite / verify
# ---------------------------------------------------------------------------------------------

cmd_rewrite() {
  local url="" wd=""
  PATHS=()
  while (( $# )); do
    case "$1" in
      --url) url="${2:?--url needs a value}"; shift 2 ;;
      --workdir) wd="${2:?--workdir needs a value}"; shift 2 ;;
      --path) add_path "${2:?--path needs a value}"; shift 2 ;;
      --paths-file) read_paths_file "${2:?--paths-file needs a value}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "rewrite: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$url" ]] || die "rewrite: --url is required"
  [[ -n "$wd" ]] || die "rewrite: --workdir is required"
  (( ${#PATHS[@]} > 0 )) || die "rewrite: at least one --path or --paths-file is required"
  require_filter_repo

  if [[ -e "$wd" && -n "$(ls -A "$wd")" ]]; then
    die "workdir is not empty: $wd (use a new directory for each attempt)"
  fi
  mkdir -p "$wd"
  WD="$(cd "$wd" && pwd)"
  BACKUP="$WD/backup.git"
  WORK="$WD/work.git"
  URL="$url"
  printf '%s\n' "$URL" > "$WD/remote-url.txt"
  printf '%s\n' "${PATHS[@]}" > "$WD/paths.txt"

  title "1/5 Backup: mirror clone of $URL"
  git clone --mirror "$URL" "$BACKUP"

  title "2/5 Working copy of the backup"
  git clone --mirror --quiet "$BACKUP" "$WORK"
  git -C "$WORK" for-each-ref --format='%(refname)' | awk '$0 !~ /^refs\/(heads|tags)\//' > "$WD/dropped-refs.txt"
  if [[ -s "$WD/dropped-refs.txt" ]]; then
    awk '{ print "delete " $0 }' "$WD/dropped-refs.txt" | git -C "$WORK" update-ref --stdin
    warn "$(count_lines "$WD/dropped-refs.txt") ref(s) outside refs/heads and refs/tags are neither rewritten nor pushed (list: $WD/dropped-refs.txt). They are usually server-managed (merge/pull requests, notes) and keep the old history alive on the server until it is cleaned up."
  fi
  git -C "$WORK" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$WD/original-refs.txt"
  [[ -s "$WD/original-refs.txt" ]] || die "the remote has no branch and no tag"
  info "$(count_lines "$WD/original-refs.txt") branch(es)/tag(s) to rewrite."

  title "3/5 Checking the paths to purge"
  info "Looking for ${#PATHS[@]} path(s) in the history (one history walk per path)..."
  local p hit missing=()
  for p in "${PATHS[@]}"; do
    hit="$(first_commit_with_path "$WORK" --all "$p")"
    if [[ -z "$hit" ]]; then missing+=("$p"); fi
  done
  if (( ${#missing[@]} > 0 )); then
    printf '%s\n' "${missing[@]}" | print_some >&2
    die "${#missing[@]} path(s) above are not in the history of any branch or tag (typo? case? paths are relative to the repository root)"
  fi
  info "ok   all ${#PATHS[@]} path(s) found in history:"
  printf '%s\n' "${PATHS[@]}" | print_some
  warn_if_not_ignored "$WORK"

  title "4/5 Rewriting history with git-filter-repo"
  # The paths go through a file: as --path arguments, a long list exceeds the Windows command-line
  # limit (32767 characters). The "literal:" prefix keeps a path that starts with "glob:", "regex:"
  # or "#" literal; normalize_path rejects the rename marker "==>" and line breaks.
  local fr_paths="$TMP_ROOT/filter-repo-paths.txt"
  printf 'literal:%s\n' "${PATHS[@]}" > "$fr_paths"
  git -C "$WORK" filter-repo --invert-paths --paths-from-file "$fr_paths" 2>&1 | tee "$WD/filter-repo.log"

  title "5/5 Verification"
  verify_workdir
}

cmd_verify() {
  local wd=""
  while (( $# )); do
    case "$1" in
      --workdir) wd="${2:?--workdir needs a value}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "verify: unknown argument '$1'" ;;
    esac
  done
  load_workdir "$wd"
  verify_workdir
}

verify_workdir() {
  local failures=0 p hit old ref new checked=0 skipped=0
  local tree_old="$TMP_ROOT/tree.old" tree_new="$TMP_ROOT/tree.new"
  rm -f "$WD/verified.ok"

  info "Purged paths absent from every branch and tag:"
  local left=()
  for p in "${PATHS[@]}"; do
    hit="$(first_commit_with_path "$WORK" --all "$p")"
    if [[ -n "$hit" ]]; then left+=("$p (commit $hit)"); fi
  done
  if (( ${#left[@]} > 0 )); then
    warn "  FAIL ${#left[@]} purged path(s) still present:"
    printf '%s\n' "${left[@]}" | print_some >&2
    failures=$((failures + ${#left[@]}))
  else
    info "  ok   none of the ${#PATHS[@]} path(s) is left"
  fi

  info "Every branch and tag has the same files as before, minus the purged paths:"
  while read -r old ref; do
    new="$(git -C "$WORK" rev-parse -q --verify "$ref" || true)"
    if [[ -z "$new" ]]; then
      warn "  FAIL $ref no longer exists (all its commits only touched purged paths?)"
      failures=$((failures + 1))
      continue
    fi
    if ! git -C "$BACKUP" rev-parse -q --verify "$old^{tree}" >/dev/null; then
      info "  skip $ref (points to neither a commit nor a tree)"
      skipped=$((skipped + 1))
      continue
    fi
    git -C "$BACKUP" ls-tree -r -z --full-tree "$old^{tree}" | tr '\0' '\n' | filter_out_paths "$WD/paths.txt" ls-tree > "$tree_old"
    git -C "$WORK" ls-tree -r -z --full-tree "$new^{tree}" | tr '\0' '\n' > "$tree_new"
    if cmp -s "$tree_old" "$tree_new"; then
      checked=$((checked + 1))
    else
      warn "  FAIL $ref: files differ (first differences below, < original, > rewritten)"
      { diff "$tree_old" "$tree_new" || true; } | awk 'NR <= 20' >&2
      failures=$((failures + 1))
    fi
  done < "$WD/original-refs.txt"
  info "  ok   $checked ref(s) identical, $skipped skipped"

  local commits_old commits_new
  commits_old="$(awk '{ print $1 }' "$WD/original-refs.txt" | git -C "$BACKUP" rev-list --count --stdin 2>/dev/null || echo '?')"
  commits_new="$(git -C "$WORK" for-each-ref --format='%(objectname)' refs/heads refs/tags | git -C "$WORK" rev-list --count --stdin 2>/dev/null || echo '?')"
  info "Commits: $commits_old -> $commits_new (commits that only touched purged paths are dropped)"
  info "Object store: $(human_kib "$(repo_kib "$BACKUP")") -> $(human_kib "$(repo_kib "$WORK")")"

  info "Largest blobs left in the rewritten history:"
  local blobs="$TMP_ROOT/work-blobs.tsv" head="$TMP_ROOT/work-head.txt"
  scan_blobs "$WORK" "$blobs"
  git -C "$WORK" ls-tree -r -z --name-only HEAD | tr '\0' '\n' > "$head"
  report_largest_blobs "$blobs" 10 "$head"

  if (( failures > 0 )); then
    die "verification failed ($failures problem(s)). Nothing was pushed. Inspect $WORK, fix the cause and run 'rewrite' again in a new workdir."
  fi
  date '+%Y-%m-%d %H:%M:%S' > "$WD/verified.ok"
  info ""
  info "Verification passed. Next step, once nobody pushes anymore:"
  info "  $PROG push --workdir '$WD'"
}

# ---------------------------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------------------------

# Lists the branches and tags of the remote as "sha ref", sorted by ref.
remote_refs() {
  git ls-remote --refs "$URL" | awk -F'\t' '$2 ~ /^refs\/(heads|tags)\// { print $1 " " $2 }' | sort -k2,2
}

push_batch() {
  local atomic="$1"
  shift
  local opts=()
  if (( atomic )); then opts+=(--atomic); fi
  git -C "$WORK" push "${opts[@]}" "$@"
}

cmd_push() {
  local wd="" yes=0 atomic=1
  while (( $# )); do
    case "$1" in
      --workdir) wd="${2:?--workdir needs a value}"; shift 2 ;;
      --yes) yes=1; shift ;;
      --no-atomic) atomic=0; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "push: unknown argument '$1'" ;;
    esac
  done
  load_workdir "$wd"
  [[ -f "$WD/verified.ok" ]] || die "the rewrite has not passed verification: run '$PROG verify --workdir $WD'"

  local remote_now="$TMP_ROOT/remote.txt" rewritten="$TMP_ROOT/rewritten.txt" plan="$TMP_ROOT/plan.txt"
  local original="$TMP_ROOT/original.txt"

  title "Preflight: remote branches and tags compared with the snapshot"
  remote_refs > "$remote_now"
  sort -k2,2 "$WD/original-refs.txt" > "$original"
  git -C "$WORK" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort -k2,2 > "$rewritten"

  # One line per ref: "TODO ref expected_remote_sha", "DONE ref sha" or "ERROR ref reason".
  awk -v f_orig="$original" -v f_new="$rewritten" '
    FILENAME == f_orig { orig[$2] = $1; next }
    FILENAME == f_new  { neu[$2] = $1; next }
    { remote[$2] = $1 }
    END {
      for (r in orig) {
        if (!(r in neu))          { print "ERROR " r " is missing from the rewritten repository"; continue }
        if (!(r in remote))       { print "ERROR " r " was deleted on the remote since the snapshot"; continue }
        if (remote[r] == neu[r])  { print "DONE " r " " neu[r]; continue }
        if (remote[r] == orig[r]) { print "TODO " r " " orig[r]; continue }
        print "ERROR " r " was updated on the remote since the snapshot (now " remote[r] ")"
      }
      for (r in remote) if (!(r in orig)) print "ERROR " r " was created on the remote since the snapshot"
    }' "$original" "$rewritten" "$remote_now" | sort -k2,2 > "$plan"

  if grep -q '^ERROR' "$plan"; then
    sed -n 's/^ERROR /  /p' "$plan" >&2
    die "the remote changed since the snapshot taken by 'rewrite'. Nothing was pushed.
  Make sure nobody pushes anymore, then run 'rewrite' again in a new workdir.
  A branch pushed from a clone made before the rewrite carries the old history: delete it on the
  remote, or port its commits onto the rewritten history, before running 'rewrite' again."
  fi

  local other_refs
  other_refs="$(git ls-remote --refs "$URL" | awk -F'\t' '$2 !~ /^refs\/(heads|tags)\// { print $2 }')"
  if [[ -n "$other_refs" ]]; then
    warn "the remote has refs outside refs/heads and refs/tags; they are not touched and keep the old history alive until the server is cleaned up:"
    printf '%s\n' "$other_refs" | awk 'NR <= 10 { print "  " $0 } END { if (NR > 10) print "  ... (" NR " in total)" }' >&2
  fi

  local todo done_count
  todo="$(grep -c '^TODO' "$plan" || true)"
  done_count="$(grep -c '^DONE' "$plan" || true)"
  info "$todo ref(s) to push, $done_count already rewritten on the remote."

  if (( todo > 0 )); then
    info ""
    info "About to force-push $todo branch(es)/tag(s) to: $URL"
    if (( ! yes )); then
      [[ -t 0 ]] || die "stdin is not a terminal: re-run with --yes to confirm non-interactively"
      local answer
      read -r -p "Type PUSH to continue: " answer
      [[ "$answer" == "PUSH" ]] || die "aborted, nothing pushed"
    fi

    title "Push"
    local state ref expected batch=0
    local leases=() specs=()
    while read -r state ref expected; do
      [[ "$state" == "TODO" ]] || continue
      leases+=("--force-with-lease=$ref:$expected")
      specs+=("$ref:$ref")
      if (( ${#specs[@]} >= PUSH_BATCH_SIZE )); then
        batch=$((batch + 1))
        push_batch "$atomic" "${leases[@]}" "$URL" "${specs[@]}" \
          || die "push failed (batch $batch). Earlier batches are pushed; fix the cause (protected branch?) and re-run push: it resumes."
        leases=()
        specs=()
      fi
    done < "$plan"
    if (( ${#specs[@]} > 0 )); then
      batch=$((batch + 1))
      push_batch "$atomic" "${leases[@]}" "$URL" "${specs[@]}" \
        || die "push failed (batch $batch). Earlier batches are pushed; fix the cause (protected branch?) and re-run push: it resumes."
    fi
  else
    info "Nothing to push."
  fi

  title "Post-push check"
  remote_refs > "$remote_now"
  if cmp -s "$remote_now" "$rewritten"; then
    info "ok   remote branches and tags are identical to the rewritten repository."
  else
    { diff "$rewritten" "$remote_now" || true; } | awk 'NR <= 20' >&2
    die "remote branches and tags differ from the rewritten repository (< expected, > remote)"
  fi

  print_followups
}

print_followups() {
  cat <<EOF

Remaining steps:
 1. Server-side cleanup: the old objects stay on the server until it garbage-collects them.
    - GitLab: Settings > Repository > Repository cleanup, upload
      $WORK/filter-repo/commit-map
    - GitHub: contact GitHub Support (pull request refs, cached views).
    - Gitea/Forgejo: Site administration > Maintenance > garbage collect, or git gc on the server.
    - Plain bare repository: git reflog expire --expire=now --all && git gc --prune=now
 2. Restore the branch protection rules lifted for the push, if any.
 3. Every developer deletes their clone and clones again. Never push from a pre-rewrite clone:
    it would push the old history back.
 4. Deployed working copies (keep the purged files on disk):
    $PROG update-checkout --repo <dir> --paths-file $WD/paths.txt --gc
 5. Keep $BACKUP until everything is checked, then delete $WD.
EOF
}

# ---------------------------------------------------------------------------------------------
# update-checkout
# ---------------------------------------------------------------------------------------------

count_files_on_disk() {
  local p n=0 c
  for p in "${PATHS[@]}"; do
    if [[ -e "$p" ]]; then
      c="$(find "$p" -type f | awk 'END { print NR }')"
      n=$((n + c))
    fi
  done
  printf '%s\n' "$n"
}

cmd_update_checkout() {
  local repo="." gc=0
  PATHS=()
  while (( $# )); do
    case "$1" in
      --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
      --path) add_path "${2:?--path needs a value}"; shift 2 ;;
      --paths-file) read_paths_file "${2:?--paths-file needs a value}"; shift 2 ;;
      --gc) gc=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "update-checkout: unknown argument '$1'" ;;
    esac
  done
  (( ${#PATHS[@]} > 0 )) || die "update-checkout: at least one --path or --paths-file is required"
  require_git_version
  [[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] || die "not a working copy: $repo"
  cd "$(git -C "$repo" rev-parse --show-toplevel)"
  local paths_file="$TMP_ROOT/paths.txt"
  printf '%s\n' "${PATHS[@]}" > "$paths_file"

  local branch upstream remote
  branch="$(git symbolic-ref --short -q HEAD)" || die "HEAD is detached: check out the deployed branch first"
  upstream="$(git rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null)" || die "branch '$branch' has no upstream"
  remote="$(git config "branch.$branch.remote")" || die "branch '$branch' has no remote"
  info "Working copy: $(pwd)  branch: $branch  upstream: $upstream"

  title "1/6 Local changes outside the purged paths"
  local changes="$TMP_ROOT/changes.txt"
  git diff --name-only -z HEAD | tr '\0' '\n' | filter_out_paths "$paths_file" plain > "$changes"
  if [[ -s "$changes" ]]; then
    awk 'NR <= 20 { print "  " $0 }' "$changes" >&2
    die "tracked files have local changes (above). Commit and push them, or save them, then re-run. Nothing was changed."
  fi
  info "ok   none"

  title "2/6 Files on disk under the purged paths"
  local before after
  before="$(count_files_on_disk)"
  info "$before file(s)"

  title "3/6 Fetching $remote"
  git fetch --prune --force --tags "$remote"

  title "4/6 Checking that $upstream has been rewritten"
  local p hit
  for p in "${PATHS[@]}"; do
    hit="$(first_commit_with_path . "$upstream" "$p")"
    [[ -z "$hit" ]] || die "$upstream still contains '$p' (commit $hit): the remote has not been rewritten, or the path list differs. Nothing was changed apart from the fetch."
  done
  info "ok   no purged path in $upstream"

  title "5/6 Untracking the purged paths (files stay on disk), resetting $branch to $upstream"
  git --literal-pathspecs rm -r --cached --quiet --ignore-unmatch -- "${PATHS[@]}"
  git reset --hard --quiet "$upstream"
  after="$(count_files_on_disk)"
  if (( after < before )); then
    die "files under the purged paths went from $before to $after: restore them from your backup."
  fi
  info "ok   $after file(s) kept on disk, HEAD is now $(git rev-parse --short HEAD)"
  if [[ -n "$(git --literal-pathspecs status --porcelain --untracked-files=normal -- "${PATHS[@]}")" ]]; then
    warn "the purged paths show up as untracked: they are not in .gitignore, so 'git add -A' would commit them again."
  fi

  title "6/6 Local refs still holding the old history"
  local ref stale=()
  while IFS= read -r ref; do
    for p in "${PATHS[@]}"; do
      if [[ -n "$(first_commit_with_path . "$ref" "$p")" ]]; then
        stale+=("$ref")
        break
      fi
    done
  done < <(git for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags refs/stash)
  if (( ${#stale[@]} > 0 )); then
    warn "these local refs still point to the old history and prevent reclaiming disk space; delete them if they are not needed (git branch -D / git tag -d / git stash clear):"
    printf '  %s\n' "${stale[@]}" >&2
  else
    info "ok   none"
  fi

  if (( gc )); then
    title "Reclaiming disk space"
    local size_before
    size_before="$(repo_kib .)"
    git reflog expire --expire=now --expire-unreachable=now --all
    git gc --prune=now --quiet
    info "Object store: $(human_kib "$size_before") -> $(human_kib "$(repo_kib .)")"
  fi
}

# ---------------------------------------------------------------------------------------------

main() {
  if (( $# == 0 )); then
    usage
    exit 1
  fi
  local cmd="$1"
  shift
  TMP_ROOT="$(mktemp -d)"
  trap 'rm -rf "$TMP_ROOT"' EXIT
  case "$cmd" in
    analyze) cmd_analyze "$@" ;;
    rewrite) cmd_rewrite "$@" ;;
    verify) cmd_verify "$@" ;;
    push) cmd_push "$@" ;;
    update-checkout) cmd_update_checkout "$@" ;;
    help | -h | --help) usage ;;
    *) usage >&2; die "unknown command: $cmd" ;;
  esac
}

main "$@"
