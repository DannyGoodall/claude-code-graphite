#!/bin/bash
# PreToolUse guard for multi-agent Graphite workflows.
#
# Enforces the role contract deterministically:
#   - WORKER (linked git worktree): blocks repo-wide gt verbs that rewrite
#     refs across the stack. Workers may only commit/amend/submit their own
#     branch.
#   - ORCHESTRATOR (primary checkout): blocks `gt sync` / `gt restack` while
#     agent worktrees are still live — a restack cannot rewrite a branch
#     checked out in another worktree, so prune first.
#
# Exit codes: 0 = allow, 2 = block (stderr is fed back to the model).
# Fails open: if we can't parse the input or aren't in a Graphite repo,
# the call is allowed.

set -uo pipefail

input="$(cat)"

# Extract the Bash command from the hook payload (prefer jq, fall back to python3)
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)"
else
  exit 0
fi
[ -z "${cmd:-}" ] && exit 0

# Fast path: nothing gt-related in the command
case "$cmd" in
  *gt*) ;;
  *) exit 0 ;;
esac

git_dir="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
[ -f "$common_dir/.graphite_repo_config" ] || exit 0

# Regexes for gt invocations (handle start-of-string and `&& gt ...` chains)
GT='(^|[;&|[:space:]])gt[[:space:]]+'
REPO_WIDE="${GT}(sync|restack|move|fold|reorder|split|sp|absorb|ab|delete|repo)([[:space:]]|$)"
STACK_SUBMIT_FLAG="${GT}(submit|s)([[:space:]].*)?[[:space:]]--stack"
STACK_SUBMIT_SHORT="${GT}ss([[:space:]]|$)"
RESTACKING="${GT}(sync|restack)([[:space:]]|$)"

if [ "$(cd "$git_dir" && pwd)" != "$(cd "$common_dir" && pwd)" ]; then
  # ---- WORKER role (linked worktree) ----
  if printf '%s' "$cmd" | grep -qE "$REPO_WIDE|$STACK_SUBMIT_FLAG|$STACK_SUBMIT_SHORT"; then
    cat >&2 << 'EOF'
BLOCKED by gt-guard: you are a WORKER agent in a linked worktree. Repo-wide
Graphite commands (gt sync/restack/move/fold/reorder/split/absorb/delete and
gt submit --stack / gt ss) rewrite refs across the stack and are owned by the
ORCHESTRATOR in the primary checkout.

Allowed here: git add/commit on this branch, gt modify -a,
gt submit --no-interactive (this branch only), gt log / gt ls / gt info.
If you are blocked on another slice or a conflict, stop and report it instead.
EOF
    exit 2
  fi
else
  # ---- ORCHESTRATOR role (primary checkout) ----
  if printf '%s' "$cmd" | grep -qE "$RESTACKING"; then
    linked_count="$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"
    if [ "${linked_count:-1}" -gt 1 ]; then
      cat >&2 << EOF
BLOCKED by gt-guard: $((linked_count - 1)) linked worktree(s) are still
attached. A restack cannot rewrite branches checked out in other worktrees,
so 'gt sync' / 'gt restack' must wait until agent worktrees are removed.

Run first:
  git worktree list
  git worktree remove -f -f <path>   # for each finished agent worktree
  git worktree prune

Then retry the sync/restack.
EOF
      exit 2
    fi
  fi
fi

exit 0
