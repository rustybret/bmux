#!/usr/bin/env bash
# Fork sync — fast-forward-or-merge model.
#
# Syncs this fork (rustybret/bmux) with upstream (manaflow-ai/cmux)
# WITHOUT ever rebasing or force-pushing.
#
# Steps:
#   1. fetch upstream and origin
#   2. merge upstream/<branch> into <local_branch>
#   3. auto-resolve conflicts from scripts/fork-sync-exclusions:
#        - keep-deleted -> removed from working tree and index
#        - take-theirs  -> checked out from upstream (--theirs)
#   4. sweep any newly added upstream files matching keep-deleted
#   5. commit (--no-verify) and push to origin
#
# Usage:
#   scripts/fork-sync.sh                     # full sync
#   scripts/fork-sync.sh <remote> <branch>   # custom upstream
#   FORK_SYNC_NO_PUSH=1 scripts/fork-sync.sh # dry/local run without push
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXCLUSIONS="$ROOT/scripts/fork-sync-exclusions"
REMOTE="${1:-upstream}"
BRANCH="${2:-main}"
LOCAL_BRANCH="${3:-main}"
NO_PUSH="${FORK_SYNC_NO_PUSH:-0}"

if [[ ! -f "$EXCLUSIONS" ]]; then
  echo "error: exclusion manifest not found: $EXCLUSIONS" >&2
  exit 2
fi

# --- guards ---
if git rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1; then
  echo "error: a rebase is in progress. The fork model is merge-only: abort or finish it first." >&2
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean. Commit or stash before syncing." >&2
  exit 2
fi

# --- parse exclusion manifest ---
KEEP_DELETED=()
TAKE_THEIRS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"                          # strip comments
  line="${line#"${line%%[![:space:]]*}"}"     # trim leading whitespace
  [[ -z "$line" ]] && continue
  case "$line" in
    keep-deleted:*) KEEP_DELETED+=("${line#keep-deleted:}") ;;
    take-theirs:*)  TAKE_THEIRS+=("${line#take-theirs:}") ;;
    *) echo "warning: unrecognized manifest line: $line" >&2 ;;
  esac
done < "$EXCLUSIONS"

matches_keep_deleted() {
  local p="$1" g
  for g in "${KEEP_DELETED[@]}"; do
    g="${g#"${g%%[![:space:]]*}"}"
    [[ "$p" == $g ]] && return 0
    # Also support directory globbing e.g. .github/workflows/*
    if [[ "$g" == *"/*" && "$p" == "${g%/*}"/* ]]; then
      return 0
    fi
  done
  return 1
}

matches_take_theirs() {
  local p="$1" g
  for g in "${TAKE_THEIRS[@]}"; do
    g="${g#"${g%%[![:space:]]*}"}"
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

# --- 1. fetch ---
echo "== fetch $REMOTE and origin =="
git fetch "$REMOTE" "$BRANCH"
git fetch origin "$LOCAL_BRANCH" || true

# --- 2. merge upstream into local branch ---
echo "== merge $REMOTE/$BRANCH into $LOCAL_BRANCH =="
git checkout -q "$LOCAL_BRANCH"
PRE_MERGE_HEAD="$(git rev-parse HEAD)"
MERGE_CREATED_COMMIT=0

if git merge --ff-only "$REMOTE/$BRANCH" >/dev/null 2>&1; then
  if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$PRE_MERGE_HEAD")" ]]; then
    echo "$LOCAL_BRANCH already up to date with $REMOTE/$BRANCH"
  else
    echo "$LOCAL_BRANCH fast-forwarded to $REMOTE/$BRANCH"
  fi
else
  echo "$LOCAL_BRANCH has diverged: merging with a merge commit"
  if ! git merge --no-edit "$REMOTE/$BRANCH"; then
    echo "== auto-resolving known conflict classes =="
    for f in $(git diff --name-only --diff-filter=U); do
      if ! git cat-file -e ":2:$f" 2>/dev/null; then
        # deleted by us, modified by them
        if matches_keep_deleted "$f"; then
          git rm -f --quiet "$f"
          echo "  removed (keep-deleted): $f"
        fi
      elif matches_keep_deleted "$f"; then
        git rm -f --quiet "$f"
        echo "  removed (keep-deleted): $f"
      elif matches_take_theirs "$f"; then
        git checkout --theirs --quiet -- "$f"
        git add -- "$f"
        echo "  took theirs: $f"
      fi
    done

    if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
      echo "error: unresolved conflicts remain (not covered by the manifest):" >&2
      git status --short | grep -E '^(UU|DU|UD|AA|DD|AU|UA)' >&2 || true
      echo "resolve them manually, then finish with:" >&2
      echo "  git add <resolved-files> && git commit --no-verify" >&2
      echo "then push: git push origin $LOCAL_BRANCH" >&2
      exit 1
    fi
    git commit --no-verify -m "merge: sync $REMOTE/$BRANCH ($(git rev-parse --short "$REMOTE/$BRANCH")) into $LOCAL_BRANCH"
  fi
  MERGE_CREATED_COMMIT=1
fi

# --- 3. sweep newly-added upstream files that match keep-deleted globs ---
SWEPT=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if matches_keep_deleted "$f"; then
    git rm -f --quiet "$f" 2>/dev/null || rm -f "$f"
    echo "  swept (keep-deleted, new from upstream): $f"
    SWEPT=1
  fi
done < <(git diff --name-only --diff-filter=A "$PRE_MERGE_HEAD" HEAD 2>/dev/null || true)

if [[ "$SWEPT" == "1" ]]; then
  git commit --amend --no-verify --no-edit
fi

# --- 4. push ---
if [[ "$NO_PUSH" != "1" ]]; then
  echo "== pushing to origin/$LOCAL_BRANCH =="
  git push origin "$LOCAL_BRANCH"
fi

echo "== sync complete =="
git log --oneline --first-parent -3
