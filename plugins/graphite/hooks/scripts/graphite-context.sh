#!/bin/bash
# SessionStart hook: inject Graphite context if in a Graphite-enabled repo.
# Role-aware: emits ORCHESTRATOR context in the primary checkout and
# WORKER context in a linked git worktree (multi-agent mode).

set -euo pipefail

# Resolve git dirs. --git-common-dir points at the shared .git even from a
# linked worktree, where .git is a file and the old `[ -f .git/... ]` check
# would silently fail. Bail quietly if not in a git repo at all.
git_dir="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0

# Only fire in Graphite-initialized repos
if [ ! -f "$common_dir/.graphite_repo_config" ]; then
  exit 0
fi

if [ "$(cd "$git_dir" && pwd)" != "$(cd "$common_dir" && pwd)" ]; then
  # Linked worktree -> WORKER role
  cat << 'EOF'
You are a WORKER agent in a Graphite agent worktree (multi-agent mode).

**Your contract — work ONLY on the branch checked out here:**
- Do not checkout, create, or delete other branches.
- Allowed: edit files, `git add` + `git commit` on this branch, `gt modify -a`,
  `gt submit --no-interactive` (this branch only), read-only `gt log` / `gt ls` / `gt info`.
- FORBIDDEN (the orchestrator owns these): `gt sync`, `gt restack`, `gt move`,
  `gt fold`, `gt reorder`, `gt split`, `gt absorb`, `gt delete`, `gt submit --stack` / `gt ss`.
- If your work depends on another slice, or you hit a merge/rebase conflict:
  STOP and report it in your final message. Never resolve across branches.

**Commit style:** conventional commits (feat:, fix:, etc.), casual and concise,
no LLM fluff, no em dashes. Each commit atomic.

**When done:** report branch name, commits made, whether you submitted, and
anything you were blocked on — as raw data for the orchestrator, not prose.
EOF
else
  # Primary checkout -> ORCHESTRATOR role
  cat << 'EOF'
This repo uses Graphite CLI for stacked PRs.

**IMPORTANT: Use gt commands instead of git:**
- `gt create -am "msg"` instead of `git commit` - creates new branch/PR
- `gt modify -a` instead of `git commit --amend` - amends current PR
- `gt submit --no-interactive` instead of `git push` - submits stack
- `gt sync` instead of `git pull` - pulls trunk, restacks, cleans merged

**Before writing code for a feature:**
1. Plan the stack structure (use TodoWrite - each todo = one PR)
2. Present the plan and ask for confirmation
3. Each PR must be atomic and pass CI independently

**Commit style:** conventional commits (feat:, fix:, etc.), casual and concise, no LLM fluff, no em dashes.

**PR bodies:** what changed, why, and the benefit.

When conflicts occur during restack: check what each branch does, auto-resolve obvious ones, ask about ambiguous ones.

**Multi-agent fan-out:** when parallelizing work across agents, you are the
ORCHESTRATOR — you own `gt sync`/`gt restack`/stack topology and the worktree
lifecycle. See the "Multi-Agent Orchestration" section of the graphite skill
(references/multi-agent.md). Never restack while agent worktrees are live.
EOF
fi
