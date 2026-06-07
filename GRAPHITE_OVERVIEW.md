# Graphite: An Introduction to Stacked Pull Requests

A primer on [Graphite](https://graphite.dev) (`gt`), the stacked-PR and stacked-branch manager for Git repositories, written for people who are new to it. It covers the mental model, the everyday workflows (with the raw-git equivalents Graphite saves you from), a full command reference, and finally how the plugins in this repository let a Claude Code agent drive all of it for you.

Companion documents in this repo:

- [README.md](README.md) — what the plugins are and how to install them
- [MANUAL.md](MANUAL.md) — operating the plugins in single-agent and multi-agent modes

## Contents

- [High-level overview](#high-level-overview)
- [Workflow overviews](#workflow-overviews)
- [Command reference](#command-reference)
- [Gotchas for newcomers](#gotchas-for-newcomers)
- [Graphite and git worktrees: a forensic look](#graphite-and-git-worktrees-a-forensic-look)
- [Using Graphite with the Claude Code plugin](#using-graphite-with-the-claude-code-plugin)
- [Further reading](#further-reading)

---

## High-level overview

### The problem Graphite solves

On GitHub, the unit of review is the pull request, and the unit of work is the branch. When a feature is too big for one reviewable PR, you have two bad options with plain git:

1. **One giant PR** — slow to review, risky to merge, feedback arrives late.
2. **Sequential PRs** — open PR 1, wait for review and merge, then start PR 2. You are blocked at every step.

The third option is **stacking**: branch 2 is created *on top of* branch 1, branch 3 on top of branch 2, and each branch becomes its own small PR. You keep building while earlier PRs are in review; reviewers see small, focused diffs; PRs merge bottom-up as they are approved.

Git can technically represent a stack (branches off branches), but it gives you no help maintaining one. The moment branch 1 changes — an amend after review feedback, a rebase onto fresh `main`, a squash-merge — every branch above it is stranded on stale commits, and you must repair the chain yourself with a careful cascade of `git rebase --onto` commands, one per branch, in dependency order, followed by a force-push of each. Get one step wrong and you are in reflog archaeology.

**Graphite is a CLI (`gt`) that manages this for you.** Its two jobs:

1. **Track branch dependencies.** Git has no concept of a branch's "parent". Graphite records, for every branch, which branch it builds on and which commit corresponds to that parent (the *base*). That metadata is what makes everything else possible.
2. **Automate the maintenance.** When anything changes anywhere in a stack, one command (`gt restack`, usually run implicitly) rebases every affected descendant in the right order. Submitting (`gt submit`) force-pushes every branch and creates or updates one PR per branch, with each PR's base pointed at its parent branch.

### Core terms

| Term | Meaning |
|------|---------|
| **stack** | A sequence of branches (each one PR), each building off its parent. `main ← add-api ← add-frontend ← add-docs` |
| **trunk** | The branch stacks are merged into — usually `main`. Chosen at `gt init`. |
| **downstack** | Everything *below* the current branch: its ancestors, toward trunk. |
| **upstack** | Everything *above* the current branch: its descendants, away from trunk. |
| **restack** | Rebase branches so every branch sits on the current tip of its parent. |
| **tracked branch** | A branch Graphite knows the parent of. Untracked branches are plain git branches. |

### The mental model shift

Graphite's docs put it well: **Graphite treats branches the way git treats commits.** Work you would split into several commits on one git branch becomes several *single-commit branches* in a stack — because the branch is the unit of review. The recommended rhythm is one commit per branch, maintained by amending (`gt modify`) rather than appending commits.

A useful reframing from the community: a stack is *a queue of editable changes*. Anything in the queue can still be edited — amend a branch three PRs down, and Graphite rewrites the queue above it automatically.

### How it differs from raw git, in one example

You amend the bottom branch of a three-branch stack:

| With git | With Graphite |
|----------|---------------|
| `git add . && git commit --amend --no-edit` | `gt modify -a` |
| `git rebase --onto part_1 <old-part_1-sha> part_2` | *(done automatically)* |
| `git rebase --onto part_2 <old-part_2-sha> part_3` | *(done automatically)* |
| `git push -f origin part_1 part_2 part_3` (each) | `gt submit --stack` |
| Update each PR's base branch on GitHub if needed | *(done automatically)* |

And crucially: with git, *you* had to remember the old SHAs and the dependency order. Graphite's metadata remembers for you.

### Other things worth knowing up front

- **`gt` passes unknown commands through to git.** `gt status`, `gt add`, `gt diff`, `gt stash` all work. You keep your repository and your git muscle memory; there is no lock-in — every Graphite branch is an ordinary git branch.
- **Submitting force-pushes.** Stacking is a history-rewriting workflow. `gt submit` uses `--force-with-lease` semantics and refuses to overwrite remote changes it hasn't seen, but you should understand you are not in an append-only world.
- **Merging is stack-aware.** Merging a stack on GitHub manually means merge → retarget the next PR → wait for CI → repeat. Graphite's web UI ("Merge all") or `gt merge` queues the whole thing: PRs merge bottom-up, waiting for checks at each step, rebasing upstack PRs only when needed.
- **Configuration lives in `.git/.graphite_repo_config`**, created by `gt init`. (The Claude Code plugin in this repo uses that file to detect Graphite repos.)

---

## Workflow overviews

Each workflow below follows the same shape: *what you're trying to achieve* → *the gt commands* → *the result* → *the raw git you'd need for the same outcome*.

A starting point for all of them: a repo where `gt init` has been run, with trunk `main`.

### 1. Start a new stack from trunk

**You want to:** begin a feature as the first branch (and PR) of a new stack.

```bash
gt checkout main            # or: gt trunk
# ... edit files ...
gt create -am "feat: add user-fetch endpoint"
gt submit
```

**Result:** a new branch (name auto-generated from the message unless you pass one), containing one commit with all your changes, tracked with parent `main`, checked out — and a PR open for it. Note you don't create the branch first and then work: you work, then `gt create` wraps the changes into a branch + commit in one step.

**Raw git equivalent:**

```bash
git checkout main
git checkout -b feat-user-fetch        # invent a name yourself
git add --all
git commit -m "feat: add user-fetch endpoint"
git push -u origin feat-user-fetch
gh pr create --base main               # or click around on GitHub
```

…and nothing records that `feat-user-fetch`'s parent is `main`; that lives in your head.

### 2. Stack another branch (and another) on top

**You want to:** keep building on top of work that is still in review.

```bash
# on the first branch
# ... edit files ...
gt create -am "feat: show users list"
# ... edit files ...
gt create -am "docs: document the users page"
gt submit --stack           # push everything, one PR per branch
gt log                      # visualize the stack
```

**Result:** `main ← feat-user-fetch ← feat-users-list ← docs-users-page`, three PRs, each PR's base set to its parent branch (so each review shows only that branch's diff). You were never blocked on a merge.

**Raw git equivalent:** repeat the branch/commit/push/`gh pr create --base <parent>` dance per branch — and now you are responsible for retargeting PR bases when parents merge, and for rebasing children whenever a parent changes.

### 3. Respond to review feedback mid-stack

**You want to:** fix something in the *bottom* PR without breaking the two branches stacked above it.

```bash
gt checkout feat-user-fetch     # or: gt down 2 from the top
# ... make the requested edits ...
gt modify -a                    # amend the branch's commit, auto-restack everything upstack
gt submit --stack               # update all the PRs
```

**Result:** the bottom PR is updated; both upstack branches were silently rebased onto the new commit; all three PRs on GitHub show correct diffs. (Use `gt submit --stack` rather than plain `gt submit` after editing low in the stack — otherwise upstack PR diffs go stale on the web.)

If review feedback is scattered across several branches, there's an even better tool: stage all the fixes anywhere in the stack and run `gt absorb -a`. Graphite works out which hunk belongs to which branch's commit and amends each one in place.

**Raw git equivalent:**

```bash
git checkout feat-user-fetch
git add . && git commit --amend --no-edit
git rebase --onto feat-user-fetch <old-sha-1> feat-users-list
git rebase --onto feat-users-list <old-sha-2> docs-users-page
git push -f origin feat-user-fetch feat-users-list docs-users-page
```

The `gt absorb` equivalent in git is the `git commit --fixup=<sha>` + `git rebase -i --autosquash` flow, per target commit, plus the cascade above — one of git's sharpest edges.

### 4. Sync with trunk after other work merges

**You want to:** pull the latest `main`, clean up branches whose PRs merged, and rebase your open stacks onto the new trunk.

```bash
gt sync
```

**Result:** trunk fast-forwarded (or reset to remote if it can't fast-forward); for each local branch whose PR was merged or closed, a prompt to delete it; every remaining branch restacked onto the new state — with a report of any branch that hit conflicts (fix those with `gt restack`, see workflow 5). Run it daily, and right after merging anything.

**Raw git equivalent:**

```bash
git checkout main && git pull
git branch -d <each-merged-branch>     # first working out *which* merged —
                                       # nontrivial with squash-merges
git rebase main feat-users-list        # then the --onto cascade for every
git rebase --onto ... docs-users-page  # branch of every open stack
```

The merged-branch detection alone is painful with squash-merges (the commits on `main` are new SHAs, so `git branch --merged` won't find them). Graphite checks PR state instead.

### 5. Resolve conflicts during a restack

**You want to:** finish a `gt sync` / `gt restack` / `gt modify` that stopped on a merge conflict.

Graphite halts mid-cascade and tells you exactly where you are:

```text
Hit conflict restacking feat-users-list on main.
You are here (resolving feat-users-list):
  ◯ docs-users-page
  ◉ feat-users-list
  ◯ main
```

```bash
# ... resolve the conflicted files in your editor ...
gt add .          # mark resolved (git passthrough)
gt continue       # resume the whole multi-branch operation
# or, to bail out safely:
gt abort
```

**Result:** the rebase resumes and Graphite carries on restacking the *rest* of the stack from where it stopped. `gt abort` rolls the entire operation back to the pre-restack state.

**Raw git equivalent:** `git rebase --continue` / `git rebase --abort` — but those only finish *one* branch's rebase. The remaining branches of the cascade are still yours to do by hand, remembering where you were.

### 6. Reorder or re-parent branches in a stack

**You want to:** change the stack's shape — move a branch onto a different parent, or change the order of branches.

```bash
gt move --onto <new-parent>   # rebase current branch (and its descendants) onto another branch
gt reorder                    # opens an editor: reorder the lines, Graphite restacks to match
gt create -aim "feat: ..."    # --insert: slot a NEW branch in mid-stack
```

**Result:** the branch (plus everything upstack of it, unless you pass `gt move --only`) now sits on the new parent; all affected descendants are restacked. Conflicts use the same `gt continue`/`gt abort` flow as workflow 5.

**Raw git equivalent:** a chain of `git rebase --onto <new-parent> <old-parent> <branch>` invocations, executed very carefully in dependency order, with no record of the intended topology to check your work against.

### 7. Split a branch that grew too big

**You want to:** turn one oversized branch into several small, reviewable PRs.

```bash
gt split --by-commit            # choose split points between existing commits
gt split --by-hunk              # interactively stage hunks into new single-commit branches
gt split --by-file "*.sql"      # files matching a pathspec become a new parent branch
```

**Result:** the branch becomes a mini-stack of smaller branches, and anything that was stacked above it is restacked on the new top. (If the branch already has an open PR, give the *original branch name* to the piece that should keep the PR — GitHub PR branch names are immutable.)

The inverse operations:

```bash
gt fold       # merge the current branch's changes into its parent (e.g. collapse checkpoints)
gt squash     # collapse a multi-commit branch into one commit
```

**Raw git equivalent:** create N branches by hand, distribute the changes with `git cherry-pick` / `git reset` + `git add -p`, recommit, then rebase every descendant. Few people attempt it.

### 8. Land the whole stack

**You want to:** merge every PR in the stack, bottom-up, once approved.

```bash
gt top        # go to the tip of the stack
gt merge      # merge all PRs from trunk to here, via Graphite
# (or open the stack in Graphite's web UI — gt pr — and click "Merge all (N)")
gt sync       # afterwards: delete the merged locals, restack anything left
```

**Result:** Graphite merges the PRs one at a time from the bottom, waiting for GitHub checks at each step and rebasing upstack PRs only when a conflict requires it. Partial landing works too — merge just the bottom k PRs and keep stacking on what's left.

**Raw git / GitHub equivalent:** merge PR 1 on GitHub → retarget PR 2's base to `main` → wait for CI to re-run → merge PR 2 → repeat. With squash-merges, GitHub frequently reports phantom conflicts on the upper PRs (the squashed trunk commit means the upstack PRs appear to "contain" already-merged commits), which Graphite's machinery avoids.

---

## Command reference

Everything below reflects `gt --help --all` from the installed CLI, grouped the way Graphite groups it. Flags listed are the ones that matter day-to-day, not the exhaustive set — run `gt <command> --help` for everything. All commands also accept the global flags `--cwd`, `--debug`, `--no-interactive`, `--no-verify`, and `-q/--quiet`.

### At a glance

| Command | Alias | One-liner |
|---------|-------|-----------|
| **Setup** | | |
| `gt auth` | | Store an auth token so gt can create and update PRs on GitHub. |
| `gt init` | | Pick the trunk branch and initialize Graphite in this repo. |
| **Core workflow** | | |
| `gt create [name]` | `gt c` | Create a new branch stacked on the current one and commit staged changes. |
| `gt modify` | `gt m` | Amend (or add a commit to) the current branch; auto-restack descendants. |
| `gt submit` | `gt s` | Force-push branches and create/update one PR per branch. |
| `gt sync` | | Pull trunk, prompt-delete merged branches, restack everything. |
| **Stack navigation** | | |
| `gt checkout [branch]` | `gt co` | Switch branches (interactive picker if no argument). |
| `gt up [n]` / `gt down [n]` | `gt u` / `gt d` | Move up/down the stack by n branches. |
| `gt top` / `gt bottom` | `gt t` / `gt b` | Jump to the tip / the branch just above trunk. |
| `gt trunk` | | Show (or add) the trunk of the current branch. |
| **Branch info** | | |
| `gt log [short\|long]` | `gt l` / `gt ls` / `gt ll` | Visualize stacks and PR status. |
| `gt info [branch]` | | Show a branch's commits, diff, or PR body. |
| `gt parent` / `gt children` | | Print the branch's parent / children. |
| **Stack management** | | |
| `gt restack` | `gt r` | Rebase branches so each sits on the current tip of its parent. |
| `gt continue` / `gt abort` | `gt cont` | Resume / cancel a gt operation halted by a rebase conflict. |
| `gt absorb` | `gt ab` | Distribute staged hunks into the right commits downstack. |
| `gt move` | | Re-parent the current branch (and descendants) onto another branch. |
| `gt reorder` | | Reorder the branches between trunk and here, in an editor. |
| `gt fold` | | Merge the current branch's changes into its parent. |
| **Branch management** | | |
| `gt split` | `gt sp` | Split the current branch into several (by commit, hunk, or file). |
| `gt squash` | `gt sq` | Squash the branch's commits into one; restack upstack. |
| `gt rename [name]` | `gt rn` | Rename a branch and update metadata (breaks PR association). |
| `gt delete [name]` | `gt dl` | Delete a branch locally; children restack onto its parent. |
| `gt pop` | | Delete the current branch but keep its changes in the working tree. |
| `gt get [branch]` | | Pull a branch *and its downstack* from remote (teammates' stacks). |
| `gt track [branch]` / `gt untrack` | `gt tr` / `gt utr` | Adopt a plain git branch into Graphite / remove it from tracking. |
| `gt freeze [branch]` / `gt unfreeze` | | Block / unblock local modifications to a branch. |
| `gt unlink [branch]` | | Detach the PR associated with a branch. |
| `gt revert [sha]` | | Create a branch that reverts a trunk commit (experimental). |
| `gt undo` | | Undo the most recent Graphite mutation. |
| **Graphite web** | | |
| `gt merge` | | Merge the PRs from trunk to the current branch, via Graphite. |
| `gt pr [branch]` | | Open the branch's PR page in the browser. |
| `gt dash` | | Open your Graphite dashboard. |
| **Configuration** | | |
| `gt config` | | Interactive CLI settings (submit behavior, cleanup, etc.). |
| `gt aliases` | | Edit your command aliases. |
| `gt completion` / `gt fish` | | Shell tab-completion setup (bash/zsh, fish). |
| **Learning & help** | | |
| `gt guide [title]` | `gt g` | Extended built-in guides (`gt guide workflow`). |
| `gt demo [name]` | | Interactive tutorials (`pull-request`, `stack`). |
| `gt docs` / `gt changelog` / `gt feedback` | | Open the docs / show the changelog / message the maintainers. |

### Setup

#### `gt auth`

Stores a Graphite auth token so the CLI can create and update PRs on your behalf. Get the token from <https://app.graphite.com/settings/cli> and run `gt auth --token <token>`. Required before `gt submit`/`gt merge`/`gt get` can talk to GitHub.

| Flag | Effect |
|------|--------|
| `-t, --token` | The auth token. |

#### `gt init`

Initializes Graphite in the current repo by selecting a trunk branch (creates `.git/.graphite_repo_config`). Also used to *change* trunk later.

| Flag | Effect |
|------|--------|
| `--trunk <name>` | Set trunk non-interactively. |
| `--reset` | Untrack all branches. |

### Core workflow

#### `gt create [name]` (alias: `gt c`)

Creates a new branch on top of the current branch and commits staged changes to it. No name → one is generated from the commit message. No changes → an empty branch. Unstaged changes → you're asked whether to stage them. This is the "instead of `git commit`" command: work first, then `gt create` wraps the work in a branch.

| Flag | Effect |
|------|--------|
| `-m, --message` | Commit message (also feeds branch-name generation). |
| `-a, --all` | Stage everything first, including untracked files. |
| `-u, --update` | Stage updates to tracked files only. |
| `-p, --patch` | Pick hunks to stage interactively. |
| `-i, --insert` | Insert the new branch *between* the current branch and its child(ren) — mid-stack insertion. |
| `-o, --onto <branch>` | Create on top of a different branch than the current one. |
| `--ai` / `--no-ai` | AI-generate (or never generate) the branch name and message. |

The everyday form is `gt create -am "feat: ..."`.

#### `gt modify` (alias: `gt m`)

Amends the current branch's commit (or adds a new commit with `-c`) and **automatically restacks all descendants**. This is the "instead of `git commit --amend`" command, and the engine of workflow 3.

| Flag | Effect |
|------|--------|
| `-a, --all` | Stage all changes first. |
| `-c, --commit` | New commit instead of amending. |
| `-m, --message` | Commit message; `-e, --edit` opens the editor instead. |
| `-u, --update` / `-p, --patch` | Stage tracked-file updates only / pick hunks. |
| `--into <branch>` | Amend the staged changes into a *downstack* branch instead of the current one. |
| `--interactive-rebase` | Drop into a git interactive rebase over the branch's commits. |
| `--reset-author` | Reset commit author to you when amending. |

#### `gt submit` (alias: `gt s`; `gt ss` = `gt submit --stack`)

Idempotently force-pushes (with lease) every branch from trunk to the current branch and creates or updates a distinct PR for each, bases pointed at parents. Validates that branches are properly restacked first and fails on conflicts; blocks force-pushes that would overwrite remote changes you haven't seen.

| Flag | Effect |
|------|--------|
| `-s, --stack` | Also submit descendants (the whole stack). `gt ss` is the standard alias. |
| `-d, --draft` / `-p, --publish` | Create new PRs as drafts / publish them. |
| `-u, --update-only` | Only push branches that already have PRs. |
| `-e, --edit` / `-n, --no-edit` | Prompt (or never prompt) for PR title/description. |
| `--ai` | AI-generate titles and descriptions for new PRs. |
| `-r, --reviewers [list]` / `-t, --team-reviewers` | Request reviewers. |
| `--dry-run` / `-c, --confirm` | Report what would be submitted / ask before pushing. |
| `-m, --merge-when-ready` | Mark PRs to auto-merge once requirements are met. |
| `--restack` | Restack before submitting. |
| `-f, --force` | Raw force-push instead of force-with-lease. |
| `-v, --view` | Open the PR in the browser afterwards. |

In scripts and agent sessions, `gt submit --no-interactive` avoids all prompts.

#### `gt sync`

Pulls trunk from remote (fast-forward, or overwrite if it can't), prompts to delete local branches whose PRs merged or closed, and restacks every branch that restacks cleanly — reporting any that hit conflicts. This is the "instead of `git pull`" command and the daily-hygiene habit (workflow 4).

| Flag | Effect |
|------|--------|
| `--no-restack` | Skip the restacking phase. |
| `-f, --force` | No confirmation prompts before overwriting/deleting. |
| `-d, --delete-all` | Delete all merged/closed branches without prompting. |
| `-a, --all` | Sync across all configured trunks. |

### Stack navigation

#### `gt checkout [branch]` (alias: `gt co`)

Switch to a branch; with no argument, opens an interactive selector of your tracked branches.

| Flag | Effect |
|------|--------|
| `-t, --trunk` | Check out trunk. |
| `-s, --stack` | Limit the selector to the current stack. |
| `-u, --show-untracked` | Include untracked branches in the selector. |

#### `gt up [steps]` / `gt down [steps]` (aliases: `gt u` / `gt d`)

Move to the child / parent of the current branch — `up` is away from trunk, `down` is toward it. Takes a step count (`gt down 2`); `gt up` prompts when a branch has multiple children (`--to <branch>` disambiguates).

#### `gt top` / `gt bottom` (aliases: `gt t` / `gt b`)

Jump to the tip of the current stack / the branch closest to trunk. `gt top` prompts when the stack forks.

#### `gt trunk`

Show the trunk of the current branch. `--all` lists all configured trunks; `--add <branch>` registers an additional trunk (for repos that release from more than one).

### Branch info

#### `gt log [short|long]` (aliases: `gt l`, `gt ls`, `gt ll`)

Visualize your stacks. Three forms:

- `gt log` — all tracked branches, their relationships, and PR info.
- `gt log short` (`gt ls`) — the compact one-glance view.
- `gt log long` (`gt ll`) — the raw git commit-ancestry graph.

| Flag | Effect |
|------|--------|
| `-s, --stack` | Only the current stack. |
| `-n, --steps <n>` | Limit to n levels up/downstack (implies `--stack`). |
| `-r, --reverse` | Print upside down. |
| `-u, --show-untracked` | Include untracked branches. |

#### `gt info [branch]`

Details for one branch: its commits, and optionally the diff against its parent (`-d, --diff`), per-commit patches (`-p, --patch`), a diffstat (`-s, --stat`), or the PR body (`-b, --body`).

#### `gt parent` / `gt children`

Print the parent / children of the current branch, per Graphite's metadata. Handy in scripts.

### Stack management

#### `gt restack` (alias: `gt r`)

Ensures every branch in the current stack has its parent in its commit history, rebasing where necessary. Mostly runs implicitly (via `gt modify`, `gt sync`, `gt move`, …); run it directly after hand-editing with raw git, or to fix a branch `gt sync` reported as conflicted.

| Flag | Effect |
|------|--------|
| `-u, --upstack` / `-d, --downstack` | Restack only this branch plus descendants / ancestors. |
| `-o, --only` | Only this branch. |
| `--branch <name>` | Operate as if run from another branch. |

#### `gt continue` / `gt abort` (alias: `gt cont`)

When any gt operation halts on a rebase conflict: resolve the files, stage them, and `gt continue` (`-a` stages everything for you) — the *whole multi-branch cascade* resumes, not just the current rebase. `gt abort` cancels the entire halted operation and restores the previous state (`-f` skips the confirmation).

#### `gt absorb` (alias: `gt ab`)

Takes your staged changes and amends each hunk into the downstack commit it belongs to — the commit where the hunk applies deterministically. Hunks with no unambiguous home are left staged. Prompts with a preview, then restacks. The power tool for "review feedback across five branches" (workflow 3).

| Flag | Effect |
|------|--------|
| `-d, --dry-run` | Show where hunks would land without applying. |
| `-a, --all` | Stage tracked-file changes first (never untracked files). |
| `-p, --patch` | Pick hunks to stage first. |
| `-f, --force` | Apply without confirmation. |

#### `gt move`

Rebase the current branch onto a different parent and restack all of its descendants (workflow 6). No argument → interactive parent picker.

| Flag | Effect |
|------|--------|
| `-o, --onto <branch>` | The new parent. |
| `-s, --source <branch>` | Move a branch other than the current one. |
| `--only` | Move just this branch; descendants stay behind on the old parent. |

#### `gt reorder`

Opens an editor listing the branches between trunk and the current branch, one per line; reorder the lines and Graphite restacks to match. `--stack` includes upstack branches too.

#### `gt fold`

Merge the current branch's changes into its parent, re-parent its children onto the combined branch, and restack. Local-only. Useful for collapsing checkpoint branches before submitting (so they don't each become a PR).

| Flag | Effect |
|------|--------|
| `-k, --keep` | Keep the current branch's name instead of the parent's. |
| `--stack` | Fold the entire stack into a single branch. |
| `-c, --close` | Close the folded branch's PR on GitHub. |

### Branch management

#### `gt split` (alias: `gt sp`)

Split the current branch into multiple branches (workflow 7). Three strategies; run bare to be prompted for one:

- `gt split --by-commit` (`-c`) — choose split points between the branch's existing commits.
- `gt split --by-hunk` (`-h`) — interactively stage hunks into new single-commit branches (a guided `git add -p`).
- `gt split --by-file <pathspec>` (`-f`) — files matching the pathspec move to a new *parent* branch; repeat the flag for multiple patterns. The only form that works non-interactively.

#### `gt squash` (alias: `gt sq`)

Squash all commits on the current branch into one and restack upstack branches. `-m` sets the new message; `-n, --no-edit` keeps the existing one.

#### `gt rename [name]` (alias: `gt rn`)

Rename a branch and update all metadata referencing it. Because GitHub PR branch names are immutable, this severs any open-PR association — `-f, --force` is required when a PR exists.

#### `gt delete [name]` (alias: `gt dl`)

Delete a branch and its metadata locally; children restack onto its parent. Touches nothing on GitHub (an open PR must be closed separately, or pass `-c, --close`). Prompts unless the branch is merged/closed or you pass `-f`. `--upstack` / `--downstack` extend the deletion to children / ancestors.

#### `gt pop`

Delete the current branch but keep its changes in the working tree — the inverse of `gt create`, for "that shouldn't have been its own branch yet".

#### `gt get [branch]`

Fetch a branch or PR number from remote *along with everything it depends on* (trunk to that branch), prompting to resolve divergence from your local copies. The collaboration command: it reconstructs a teammate's stack locally, dependency order intact. Fetched branches arrive **frozen** (see `gt freeze`); pass `-U, --unfrozen` to make them editable. With no argument, syncs the current stack.

| Flag | Effect |
|------|--------|
| `-d, --downstack` | Don't also sync local branches upstack of the target. |
| `-u, --remote-upstack` | Also fetch remote-only branches *above* the target. |
| `-f, --force` | Overwrite local branches with the remote version. |
| `--no-restack` / `--no-checkout` | Skip restacking / stay on your current branch. |

#### `gt track [branch]` / `gt untrack [branch]` (aliases: `gt tr` / `gt utr`)

`gt track` adopts a plain-git branch into Graphite by recording its parent (`-p, --parent <branch>`; `-f` auto-picks the nearest tracked ancestor). Run from a stack tip it can walk down interactively, tracking a whole hand-built stack. Also the repair tool for corrupted metadata. `gt untrack` removes a branch (and its children) from Graphite's management without deleting it.

#### `gt freeze [branch]` / `gt unfreeze [branch]`

Freezing blocks local modifications to a branch (including restacks) while still allowing `gt sync`/`gt get` to update it from remote — the safe way to stack your work on top of someone else's PR without touching it. `gt unfreeze` reverses it.

#### `gt unlink [branch]`

Detach the PR currently associated with a branch (the metadata link only; the PR itself is untouched).

#### `gt revert [sha]`

Create a new branch off trunk that reverts the given trunk commit (`-e` to edit the message). Experimental.

#### `gt undo`

Undo the most recent Graphite mutation — the escape hatch after a sync/restack/delete you regret. `-f` skips confirmation. (Under the hood Graphite snapshots state before mutations, so this beats reflog spelunking.)

### Graphite web

#### `gt merge`

Merge the PRs for every branch from trunk to the current branch, via Graphite's merge machinery: bottom-up, waiting for checks at each step, lazily rebasing upstack PRs only when conflicts demand it (workflow 8). `--dry-run` previews; `-c, --confirm` asks first.

#### `gt pr [branch]`

Open the PR page for a branch or PR number in the browser (current branch's PR by default; `--stack` opens the stack page).

#### `gt dash`

Open your Graphite dashboard (the review inbox) in the browser.

### Configuration

#### `gt config`

Interactive settings menu: submit behavior (edit PR metadata in CLI vs web), sync cleanup defaults, and so on.

#### `gt aliases`

Edit your command aliases in an editor (`--reset` restores defaults; `--legacy` appends the pre-1.0 alias set).

#### `gt completion` / `gt fish`

Emit shell tab-completion setup for bash/zsh (`gt completion >> ~/.zshrc`) or fish.

### Learning & help

#### `gt guide [title]` (alias: `gt g`)

Extended built-in guides. Currently: `gt guide workflow` (`gt g w`) — the core CLI workflow end to end.

#### `gt demo [demoName]`

Interactive tutorials runnable in any repo: `gt demo pull-request` (create a PR) and `gt demo stack` (create a stack).

#### `gt docs` / `gt changelog` / `gt feedback [message]`

Open the online docs; show the CLI changelog; post a message straight to the maintainers' Slack (`-d, --with-debug-context` attaches recent logs).

---

## Gotchas for newcomers

Things that bite people in their first week:

1. **Plain `git commit` / `git commit --amend` on a tracked branch is fine** — but Graphite won't know descendants need restacking until you run `gt restack` yourself. `gt modify` does both in one step, which is why it's the recommended habit.
2. **Raw `git rebase` can untrack your stack.** Graphite identifies a branch's parent by a specific *base commit* in its history; a rebase that removes that commit leaves the branch (and its children) suddenly untracked. Repair with `gt track`. Avoid `git merge` and `git pull` on tracked branches entirely.
3. **`gt submit` vs `gt submit --stack`.** After editing low in a stack, plain `gt submit` only pushes downstack — the upstack PR diffs on GitHub go stale. Make `gt ss` the habit.
4. **`gt sync` deletes branches and can rewrite trunk.** It prompts before deleting merged branches (unless `-d`), and if trunk can't fast-forward it overwrites local trunk with remote. `gt undo` is the escape hatch.
5. **Every `gt create` becomes a PR on submit.** If you stack checkpoint branches as you work, `gt fold` them before `gt submit --stack`, or reviewers get PR spam.
6. **Restacks need a clean working tree.** `gt stash` (git passthrough) is your friend.
7. **GitHub branch names on PRs are immutable.** When splitting or renaming a branch with an open PR, keep the original name on the piece that should retain the PR and its review history.
8. **Branch protection: "dismiss stale approvals on push" fights stacking.** Every cascade rebase is a push, so it dismisses approvals up the stack. See Graphite's [GitHub configuration guidelines](https://graphite.com/docs/github-configuration-guidelines).
9. **CI noise from `graphite-base/*`.** Stack merges create temporary `graphite-base/*` branches for atomic retargeting; tell CI to ignore them (`branches-ignore: "**/graphite-base/**"`).
10. **Teammates' branches arrive frozen.** `gt get` blocks edits to fetched branches by default — deliberate, so you can stack on a coworker's PR without mutating it. `gt unfreeze` when you genuinely co-own it.

---

## Graphite and git worktrees: a forensic look

[Git worktrees](https://git-scm.com/docs/git-worktree) let one repository
have several working directories, each with its own checked-out branch.
Combined with stacking they are how *concurrent* work happens — two humans,
or one human and N agents, on the same repo at the same time. This section
examines exactly what is shared, what Graphite documents, and where the sharp
edges are. (Operating instructions — starting sessions, prep, delegation —
live in [MANUAL.md → Git worktrees in depth](MANUAL.md#git-worktrees-in-depth);
this is the evidence.)

### What is shared and what is private

```
repo/                      ← primary checkout ("main worktree")
├── .git/                  ← THE shared database
│   ├── refs/, objects/, config            shared: all branches, all history
│   ├── refs/branch-metadata/*             shared: Graphite's per-branch parent
│   │                                      metadata (atomic per ref)
│   ├── .graphite_repo_config              shared: trunk choice (the plugin's
│   │                                      Graphite-repo detection file)
│   ├── .graphite_cache_persist            shared: Graphite's cache —
│   │                                      LAST-WRITE-WINS, not transactional
│   └── worktrees/<name>/                  per-worktree: HEAD, index, MERGE_HEAD
└── …working files…        ← private to this worktree

../wt-feature/             ← linked worktree
├── .git                   ← a FILE pointing into repo/.git/worktrees/wt-feature
└── …working files…        ← private: own branch, own index, own file state
```

Forensically, the failure surface follows directly from this layout:

| Shared thing | Consequence |
|---|---|
| All refs | A restack *anywhere* rewrites branches that other worktrees may have checked out. Git itself refuses to rebase a branch checked out elsewhere — so a cascade either fails or must skip. |
| Graphite cache (last-write-wins) | Two concurrent metadata-mutating `gt` commands from different worktrees can clobber each other's cache writes. Serializing branch creation through one actor avoids it. |
| Nothing about the *index* | `git add -A` / `gt create -am` in a checkout stages **that checkout's** tree — fine per worktree, catastrophic if two actors share one checkout. Worktrees are the fix for this, not the cause. |
| Untracked files are per-worktree | A fresh worktree contains only committed files. Uncommitted inputs (specs, env files) must be seeded by commit or copied. |

### What Graphite officially documents (gt ≥ 1.8.4)

From the [command reference](https://graphite.com/docs/command-reference), verbatim:

> "Graphite fully supports multiple Git worktrees. Starting in `gt` version
> `1.8.4`, Graphite does not modify branches checked out in another worktree
> in most cases."

The specific behaviours, each introduced in 1.8.4 unless noted:

| Command | Documented behaviour with worktrees |
|---|---|
| `gt sync` | "will **skip** non-trunk branches that are checked out in another worktree. Run it from a branch's own worktree if you want that branch updated." |
| `gt restack` | same skip rule |
| `gt get` | same skip rule |
| `gt modify --into` | "will not modify a branch that is checked out in another worktree" |
| `gt undo` | "exits with an informative error" rather than touching another worktree's branch |
| `gt log` | "shows the worktree path for each checked-out branch" — your visibility tool |

### The skip-semantics hazard

Read the `gt sync` line again: **skip, not fail.** For a human with two
worktrees this is the right call — your in-progress feature isn't rebased
underneath you; you restack it from its own worktree when ready. For an
orchestrator reconciling many agent branches it is a silent trap: a sync
"succeeds" while any branch checked out in a live worktree quietly stays on
a stale parent. The stack is now *half-restacked with exit code 0*.

This is the evidence behind the plugin's **prune-before-restack rule** being
stricter than gt's own behaviour: remove every agent worktree first, so every
restack is total. The plugin's guard hook enforces it deterministically
rather than leaving it to anyone's memory. (Pre-1.8.4, the community
documented worse: ["there can be potential issues with work getting erased
in other worktrees when using Graphite"](https://blog.matte.fyi/posts/git-worktrees-with-graphite/)
— the skip semantics were Graphite's fix for *humans*; the prune rule is the
remaining fix for *fleets*.)

### Three documented ways to combine gt and worktrees

**1. Worktree-per-feature as a lifestyle (bare-repo layout).** The approach
in [Git worktrees with Graphite](https://blog.matte.fyi/posts/git-worktrees-with-graphite/):
clone bare into `.bare/`, point a `.git` file at it, and `git worktree add`
a folder per branch — `main/`, `featA/`, … Each stack lives in its own
folder; `gt track` adopts each new worktree's branch; `gt up`/`gt down`/
`gt modify`/`gt submit` work normally *within* a worktree. Caution carried
over from that write-up: be careful running `gt sync` with unstaged changes
sitting in other worktrees. Good fit for humans who context-switch a lot;
the per-worktree dependency installs are the tax.

**2. Ephemeral worktree-per-task (Claude Code native).** `claude --worktree
<name>` creates `.claude/worktrees/<name>/` on branch `worktree-<name>`
based on `origin/HEAD`, with `.worktreeinclude` copying selected gitignored
files in, and automatic cleanup of unchanged worktrees on exit
([docs](https://code.claude.com/docs/en/worktrees)). Graphite-specific
caveat: the created branch is **untracked** by gt until someone runs
`gt track`. Community practice with this pattern converges on 2–4 parallel
sessions as the practical ceiling before coordination overhead wins
([best practices](https://www.anthropic.com/engineering/claude-code-best-practices)).

**3. Orchestrated worktree-per-worker (this plugin).** The orchestrator
pre-creates branch + worktree (`git worktree add ../wt-x -b feat/x main;
gt track feat/x --parent main`), seeds inputs by commit, dispatches one
constrained worker per worktree, and prunes before any restack. Topology is
recorded in a manifest; roles are hook-enforced. This is layout 2's
ephemerality with layout 1's explicit naming, plus the discipline neither
needs for a single human.

| | Bare-repo lifestyle | Claude-native `--worktree` | Plugin protocol |
|---|---|---|---|
| Who creates branch | you (`gt create` in worktree) | harness (`worktree-<name>`, untracked) | orchestrator (`gt track`ed) |
| Lifetime | long-lived | session-scoped, auto-cleanup | task-scoped, pruned at reconvene |
| gt tracking | per-worktree `gt track` | manual afterthought | provisioning step |
| Restack safety | gt's skip semantics | gt's skip semantics | prune-before-restack (total restacks) |
| Best for | one human, many contexts | ad-hoc parallel sessions | agent fan-outs |

### Worktree rules of thumb, evidence-based

1. **Branch for serialized work, worktree for concurrent work.** A branch
   isolates *review*; a worktree isolates *files and index*. The second
   simultaneous actor is the trigger to reach for worktrees.
2. **Seed by commit.** Fresh worktrees see only committed state — both git's
   design and Anthropic's docs say so. Untracked inputs do not travel.
3. **`gt log` before repo-wide operations.** It shows which branch is
   checked out in which worktree — the skip-semantics victims, in advance.
4. **Never trust a sync while worktrees are attached** (fleet context).
   Prune first; then the restack means what it says.
5. **One actor per checkout, ever.** Most "worktree problems" in the wild
   are actually two-actors-one-index problems that worktrees would have
   prevented.

---

## Using Graphite with the Claude Code plugin

Everything above is what *you* would type. The plugins in this repository teach a **Claude Code agent** to do it instead — and to do it safely when more than one agent is working at once. There are three plugins in this marketplace:

| Plugin | What it adds |
|--------|--------------|
| `graphite` | The core skill, hooks, the `gt-stack-worker` agent, and the `gt-delegate` skill |
| `graphite-mcp` | Graphite operations as MCP tools (`gt mcp`) |
| `graphite-openspec` | `/gt-apply` — an OpenSpec workflow binding over `gt-delegate` (only for OpenSpec repos) |

Installation is in the [README](README.md#installation); full operating modes are in the [MANUAL](MANUAL.md). What follows is how the plugin maps onto the concepts in this document.

### The agent speaks gt natively

The `graphite` skill activates only in repos with `.git/.graphite_repo_config` (a SessionStart hook detects it and injects context automatically). Once active, the agent uses the command mappings from this document without being asked:

| Where the agent would use git | It uses instead | See |
|---|---|---|
| `git commit` | `gt create -am "msg"` | [`gt create`](#gt-create-name-alias-gt-c), workflow 1–2 |
| `git commit --amend` | `gt modify -a` | [`gt modify`](#gt-modify-alias-gt-m), workflow 3 |
| `git push` | `gt submit --no-interactive` | [`gt submit`](#gt-submit-alias-gt-s-gt-ss--gt-submit---stack) |
| `git pull` | `gt sync` | [`gt sync`](#gt-sync), workflow 4 |
| `git rebase` | `gt restack` | [`gt restack`](#gt-restack-alias-gt-r), workflow 5 |

So the workflow overviews above double as a phrasebook for prompting the agent: anything you can express as a workflow ("split this PR", "move this branch onto main", "land the stack"), the agent translates into the gt commands in the corresponding section.

### Stacks are planned before they're built

The skill enforces the stack philosophy from the [overview](#the-mental-model-shift): before writing code for a feature, the agent breaks the work into atomic PRs (each passing CI independently, ideally small and focused), presents the planned stack, and asks for confirmation — only then does it start the `gt create` cadence of workflow 2. Review feedback follows workflow 3 (`gt checkout` → fix → `gt modify -a` → resubmit); daily hygiene follows workflow 4.

### Conflicts are triaged, not bulldozed

When `gt sync`/`gt restack` halts (workflow 5), the skill's conflict-resolution rules have the agent auto-resolve only the obviously-safe cases (import order, whitespace, non-overlapping additions) and *ask you* about anything ambiguous (same code modified differently, deleted-vs-modified, semantic conflicts) before running `gt continue -a`.

### Multi-agent stacking (this fork's addition)

The workflows in this document assume one actor in one checkout. Three things break when several agents work concurrently: restacks rewrite refs repo-wide (and fail on branches checked out in other worktrees), `gt create -am`/`gt modify -a` stage *everything* in a shared checkout, and Graphite's metadata cache is shared, last-write-wins. The plugin's answer is a two-role contract:

- The **orchestrator** (your main session, primary checkout) owns the stack-shaped commands from [Stack management](#stack-management) — `gt sync`, `gt restack`, `gt move`, `gt fold`, `gt reorder`, `gt absorb`, `gt delete` — plus branch provisioning (`gt track`), worktree lifecycle, and `gt submit --stack`.
- Each **worker** (one per linked git worktree) owns exactly one branch: `git commit` on it, `gt submit --no-interactive` for it, nothing repo-wide.

Roles are detected automatically (a session in a linked worktree is a worker) and *enforced*, not just suggested: a PreToolUse guard hook deterministically blocks repo-wide gt verbs in worker worktrees, and blocks orchestrator restacks while agent worktrees are still attached. Parallel slices always go on **sibling branches off trunk** (siblings share no refs, so workers can't invalidate each other); after the workers finish, the orchestrator prunes the worktrees, runs `gt sync`, and can stitch the siblings into a dependent stack with `gt move --onto` — workflow 6, applied after the fact.

### Skills you can invoke directly

| Invocation | What happens |
|------------|--------------|
| *(automatic)* `graphite` skill | gt-instead-of-git behavior, stack planning, conflict triage — in any Graphite repo |
| `/gt-delegate <workload> [branch]` | One workload → one pre-provisioned stacked branch → one worker in its own worktree → reconvene. Workflow-agnostic: the workload can be a plain slice spec or a skill invocation the worker runs |
| `/gt-apply <openspec-change>` | The OpenSpec binding over gt-delegate: applies a change proposal on its own stacked branch (worker runs `/opsx:apply`, orchestrator verifies with `/opsx:verify` at reconvene). From the `graphite-openspec` plugin |

With `graphite-mcp` installed, the orchestrator can also route gt operations through MCP tools (`mcp__graphite__run_gt_cmd`) instead of raw shell — MCP calls serialize through the main session, a free mutual-exclusion point for metadata-mutating commands.

### Prompts that exercise this document

```text
"Build avatar upload as a stack: API endpoint, display component, profile integration."
        → stack plan (workflows 1–2), then gt create per PR, gt submit --no-interactive

"Address the review feedback on the API PR."
        → workflow 3: gt checkout, fix, gt modify -a, gt submit --stack

"Sync with main and fix anything that conflicts."
        → workflows 4–5: gt sync, triaged resolution, gt continue -a

"This PR is too big — split out the schema changes."
        → workflow 7: gt split --by-file / --by-hunk

"Land the stack."
        → workflow 8: gt merge (or merge-when-ready via gt submit -m), then gt sync

"Fan out: the API and the settings page are independent. One agent each, in parallel."
        → multi-agent mode: sibling branches, worktrees, gt-stack-worker dispatch, reconvene

"/gt-apply add-user-avatars"
        → OpenSpec change applied on its own stacked branch by a worker agent
```

---

## Further reading

**Official:**

- [Graphite docs](https://graphite.com/docs) — start with the [CLI quick start](https://graphite.com/docs/cli-quick-start)
- [Cheatsheet](https://graphite.com/docs/cheatsheet) and [full command reference](https://graphite.com/docs/command-reference)
- [Comparing git and gt](https://graphite.com/docs/comparing-git-and-gt) — the side-by-side this document's git equivalents draw on
- [stacking.dev](https://stacking.dev) — the concept site
- `gt demo stack` and `gt guide workflow` — learn in your terminal

**Community:**

- [Stacked Diffs (and why you should know about them)](https://newsletter.pragmaticengineer.com/p/stacked-diffs) — The Pragmatic Engineer; the industry context (Meta/Google stacked-diff culture)
- [A guide to using Graphite's stacked PRs for GitHub users](https://dev.to/semgrep/a-guide-to-using-graphites-stacked-prs-for-github-users-5c47) — Semgrep; best conceptual reframing ("a queue of editable changes") plus a clear do-not-use list
- [Stay in the flow by stacking your PRs with Graphite](https://www.alanvardy.com/post/graphite-stacked-prs) — Alan Vardy; practitioner write-up on the focus benefits
- [Managing stacked pull requests with Graphite](https://unknwon.io/posts/231124-stack-pull-requests-graphite/) — Joe Chen; a minimal four-command workflow
- [Branchless or Stacked git workflows](https://v4.jasik.xyz/branchless-or-stacked-git-workflows) — comparison with jj, git-branchless, spr, git-spice
- [How to use stacked PRs to unblock your entire team](https://graphite.com/blog/stacked-prs) — Graphite's canonical motivation piece

**Worktrees:**

- [git-worktree documentation](https://git-scm.com/docs/git-worktree) — the underlying mechanism
- [Git worktrees with Graphite](https://blog.matte.fyi/posts/git-worktrees-with-graphite/) — the bare-repo worktree-per-branch lifestyle, with gt
- [Claude Code: worktrees](https://code.claude.com/docs/en/worktrees) — native `--worktree` sessions, `.worktreeinclude`, cleanup
- [Claude Code best practices](https://www.anthropic.com/engineering/claude-code-best-practices) — parallel-session guidance (2–4 sessions, commit before launching worktrees)


