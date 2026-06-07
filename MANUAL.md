# Graphite Plugin Manual

How to use the `graphite` plugin skill with Claude Code in three modes:

1. **Single-agent** — one Claude session, one checkout, building stacks the classic way
2. **Multi-synchronous** — several agents taking turns (sequential / relay) in one checkout or handing off branches
3. **Multi-async (worktree)** — several agents working *at the same time* on different parts of the project, each in its own git worktree, coordinated by an orchestrator

Modes 2 and 3 are governed by a role contract (**orchestrator** vs **worker**) that the plugin's hooks detect and enforce automatically. The full protocol lives in [`plugins/graphite/skills/graphite/references/multi-agent.md`](plugins/graphite/skills/graphite/references/multi-agent.md). New to Graphite itself? Start with [GRAPHITE_OVERVIEW.md](GRAPHITE_OVERVIEW.md) — the stacked-PR primer, command reference, and the forensic worktrees section this manual builds on.

---

## Contents

- [How the plugin works](#how-the-plugin-works)
- [Installation & prerequisites](#installation--prerequisites)
- [Mode 1: Single-agent](#mode-1-single-agent)
- [Mode 2: Multi-synchronous](#mode-2-multi-synchronous)
- [Mode 3: Multi-async (worktrees)](#mode-3-multi-async-worktrees)
- [Git worktrees in depth](#git-worktrees-in-depth)
- [Orchestrating OpenSpec changes (gt-delegate / gt-apply)](#orchestrating-openspec-changes-gt-delegate--gt-apply)
- [Claude Code parameters reference](#claude-code-parameters-reference)
- [The guard hook (gt-guard.sh)](#the-guard-hook-gt-guardsh)
- [Troubleshooting](#troubleshooting)

---

## How the plugin works

| Component | File | What it does |
|-----------|------|--------------|
| Skill | `plugins/graphite/skills/graphite/SKILL.md` | gt-instead-of-git workflow, stack planning, conflict resolution, multi-agent role contract |
| Reference: cheatsheet | `.../references/cheatsheet.md` | Complete gt command reference |
| Reference: conflicts | `.../references/conflict-resolution.md` | Auto-resolve vs ask-the-user rules |
| Reference: multi-agent | `.../references/multi-agent.md` | Fan-out lifecycle, hazards, manifest, relay pattern |
| SessionStart hook | `.../hooks/scripts/graphite-context.sh` | Injects role-aware context: **orchestrator** rules in the primary checkout, **worker** contract in a linked worktree |
| PreToolUse guard | `.../hooks/scripts/gt-guard.sh` | Deterministically blocks role-violating `gt` commands (see [guard hook](#the-guard-hook-gt-guardsh)) |
| Worker agent | `plugins/graphite/agents/gt-stack-worker.md` | A constrained subagent type for fan-outs, with a structured JSON report format. Carries the Skill tool so a slice spec can name a workflow skill for the worker to run |
| Skill: gt-delegate | `plugins/graphite/skills/gt-delegate/SKILL.md` | Single-worker specialization of the fan-out protocol: one workload → one branch → one worker → reconvene. Workflow-agnostic |
| MCP server | `plugins/graphite-mcp` (`gt mcp`) | Graphite operations as MCP tools |
| Skill: gt-apply | `plugins/graphite-openspec/skills/gt-apply/SKILL.md` | OpenSpec binding over gt-delegate: applies an OpenSpec change on its own stacked branch. Separate plugin — enable only in OpenSpec repos |

**Detection:** everything activates only in repos with `.git/.graphite_repo_config` (checked via `git rev-parse --git-common-dir`, so it works from linked worktrees and subdirectories too). In non-Graphite repos the plugin stays silent and standard git applies.

**Role detection:** a session whose `--git-dir` differs from `--git-common-dir` is running in a *linked worktree* → worker role. Otherwise → orchestrator role. No configuration needed.

---

## Installation & prerequisites

```bash
# Graphite CLI
brew install withgraphite/tap/graphite        # macOS
# or: npm install -g @withgraphite/graphite-cli@stable

# Authenticate and initialize the repo
gt auth --token <token>
cd your-repo && gt init

# Plugin (from this marketplace clone)
claude plugin marketplace add <path-or-org/repo>
claude plugin install graphite@claude-code-graphite
claude plugin install graphite-mcp@claude-code-graphite        # optional, needs gt >= 1.6.7
claude plugin install graphite-openspec@claude-code-graphite   # optional, only for OpenSpec repos
```

Verify: start `claude` inside the repo — the SessionStart hook should print the Graphite context block. Run `/plugin` to confirm both plugins are enabled.

---

## Mode 1: Single-agent

One Claude Code session in the primary checkout. This is the upstream plugin's original behavior, unchanged.

### Workflow

1. Describe the feature. Claude plans the stack first (one todo = one PR), presents it, and asks for confirmation before writing code.
2. Claude implements bottom-up with `gt create -am` per PR, keeping each branch atomic (passes CI alone, ideally < 250 lines).
3. Review feedback → `gt checkout <branch>`, fix, `gt modify -a`, `gt submit --no-interactive` (dependents restack automatically).
4. Daily: `gt sync`, resolve any conflicts (`gt continue -a`).

### Example session

```text
you:    Build avatar upload: API endpoint, display component, profile integration.
claude: PR Stack for Avatar Upload:
        1. feat: add avatar upload API
        2. feat: add avatar display component
        3. feat: add avatar to user profile
        Does this structure look good to proceed?
you:    yes
claude: [gt sync; gt create -am ...; gt create -am ...; gt create -am ...;
         gt submit --no-interactive]  →  returns Graphite PR URLs
```

### Useful claude parameters

```bash
claude                                   # interactive, default
claude -p "gt sync and report conflicts" # headless one-shot
claude --permission-mode acceptEdits     # auto-accept file edits, still confirm bash
```

---

## Mode 2: Multi-synchronous

Several agents, but **never two mutating the repo at the same moment**. Two sub-shapes:

### 2a. Sequential subagents in one checkout

The main session (orchestrator) delegates slices to subagents **one at a time**, in the primary checkout. Safe because `gt create -am` stages everything — which is only correct when nobody else has in-flight edits.

- Orchestrator: plans the stack, runs `gt sync` before and after, owns `gt submit --stack`.
- Each subagent: implements one branch (`gt create -am` or commit + `gt modify -a`), reports, exits.
- Suits: dependent stacks (PR2 needs PR1), where ordering is mandatory anyway.

```text
you: Build the avatar feature as a stack. Use one subagent per PR, sequentially.
```

The orchestrator spawns Agent #1 for the API PR, waits, verifies CI, spawns Agent #2 for the component PR (which stacks on top via `gt create`), and so on. Because everything is serialized in one checkout, no special isolation is needed.

### 2b. Relay across sessions (handoff)

Different sessions (or a human + agent) take over a stack one after another:

```bash
# Session B picks up where session A stopped
gt sync                  # get A's submitted branches
gt get feat/part-1       # or: gt checkout feat/part-1 if already local
gt create -am "feat: part 2"
```

Rules that keep this safe:

- Exactly **one session at a time** runs `gt sync` / `gt restack` / `gt submit --stack`.
- Hand off at **branch boundaries** — finish and submit a PR before passing the baton.
- The receiver always starts with `gt sync`.

### Claude parameters for mode 2

```bash
# Orchestrator session, interactive:
claude

# A delegated slice as a one-shot headless run (sequential — wait for it):
claude -p "Implement PR 2 of the avatar stack: display component.
Branch with gt create -am off feat/avatar-api. Run tests. Submit with
gt submit --no-interactive. Report the PR URL." \
  --permission-mode acceptEdits
```

In-session, ask the orchestrator to use the Agent tool sequentially: *"spawn one subagent per PR, one after another, verifying CI between each."*

---

## Mode 3: Multi-async (worktrees)

Several agents working **concurrently** on different parts of the project. This is what the multi-agent additions to this plugin exist for.

### The shape

- **Topology: sibling branches off trunk**, one per slice. Siblings share no refs, so concurrent workers cannot invalidate each other. (Dependent slices are *not* parallel work — relay them, see `references/multi-agent.md`.)
- **One linked git worktree per worker.** Private working directory + index; shared `.git`.
- **The orchestrator** (your main session, in the primary checkout) owns: planning, branch pre-creation, worktree lifecycle, all restacks, conflict resolution, final submit.
- **Workers** own exactly one branch each and report structured results.

### Step by step

**Phase 0 — Plan** (orchestrator, primary checkout)

```text
you: Fan out the avatar feature: API, display component, and settings page are
     independent. One agent each, worktrees, in parallel.
```

Claude runs `gt sync`, proposes the slice plan, and waits for your confirmation.

**Phase 1 — Provision** (orchestrator)

```bash
git worktree add ../wt-avatar-api -b feat/avatar-api main
gt track feat/avatar-api --parent main
git worktree add ../wt-avatar-ui -b feat/avatar-ui main
gt track feat/avatar-ui --parent main
# ... and writes .git/gt-agent-plan.json (the manifest)
```

Pre-creating branches in the orchestrator serializes all Graphite metadata writes — workers then never need a metadata-mutating `gt` command.

**Phase 2 — Dispatch** (orchestrator)

Spawn workers concurrently, one per worktree, using the bundled `gt-stack-worker` agent type. In-session, the orchestrator issues parallel Agent tool calls:

```text
Agent(subagent_type: "gt-stack-worker",
      run_in_background: true,
      prompt: "Worktree: ../wt-avatar-api. Branch: feat/avatar-api.
               Slice: implement the avatar upload API endpoint (POST /api/avatar),
               with validation + tests. Submit when green.")
```

> **Important:** do NOT use the Agent tool's `isolation: "worktree"` option for Graphite fan-outs. That creates a harness-managed worktree on an auto-generated branch, outside the manifest and the pre-provisioned topology. Point plain agents at the worktrees the orchestrator created — naming and lifecycle stay under orchestrator control, which the prune-before-restack rule depends on.

Alternatively, dispatch workers as separate headless processes:

```bash
cd ../wt-avatar-api && claude -p "You are a Graphite worker. Implement <slice spec>.
Commit with git commit, submit with gt submit --no-interactive. Report JSON:
{branch, commits, submitted, blocked_on}." \
  --permission-mode acceptEdits &

cd ../wt-avatar-ui && claude -p "..." --permission-mode acceptEdits &
wait
```

Each worker session starts inside a linked worktree, so the SessionStart hook injects the **worker contract** and `gt-guard.sh` enforces it — even if your prompt forgets to mention the rules.

**Phase 3 — Work** (workers, concurrently)

Each worker: edit → `git add -A && git commit -m "feat: ..."` → tests → `gt submit --no-interactive` → JSON report. Forbidden commands are blocked by the guard. A blocked/conflicted worker stops and reports rather than improvising.

**Phase 4 — Reconvene** (orchestrator) — strictly in this order:

```bash
# 1. collect reports, update manifest
# 2. PRUNE BEFORE RESTACK (restack cannot rewrite branches checked out elsewhere)
git worktree remove -f -f ../wt-avatar-api
git worktree remove -f -f ../wt-avatar-ui
git worktree prune
# 3. restack & resolve
gt sync
# 4. optional: stitch siblings into a dependent stack
gt checkout feat/avatar-ui && gt move --onto feat/avatar-api
# 5. ship
gt submit --stack --no-interactive
```

If you try `gt sync` while worktrees are still attached, the guard blocks it and tells you exactly which cleanup commands to run first.

### What makes this safe (the three hazards)

| Hazard | Mitigation in this mode |
|--------|------------------------|
| Restacks rewrite refs repo-wide and fail on branches checked out elsewhere | Orchestrator-only restacks + prune-before-restack, both guard-enforced |
| `gt create -am` / `gt modify -a` stage *everything* | One worktree per worker — no shared working directory |
| Graphite's cache (`.git/.graphite_cache_persist`) is shared, last-write-wins | Orchestrator pre-creates all branches; workers stick to `git commit` + single-branch submit |

---

## Git worktrees in depth

Everything in Mode 3 stands on git worktrees. This section is the operating detail: what they are, how Graphite and Claude Code each treat them, how to start sessions in them, the prep they need, and — for every workflow — what the *branch-only* equivalent looks like and when a plain branch is enough.

### What a worktree is, and why this plugin is built on them

A [git worktree](https://git-scm.com/docs/git-worktree) is a second working directory attached to the same repository: its own checked-out branch, its own index and file state, but one shared `.git` database (refs, objects, config — and Graphite's metadata). That sharing is both the power and the hazard:

- **Power:** a branch created or committed in one worktree is instantly visible to all of them; nothing needs pushing/pulling between worktrees.
- **Hazard:** anything that *rewrites refs* (restacks) or *reads shared caches* (Graphite's `.git/.graphite_cache_persist`) affects every worktree at once.

The plugin's two-role contract is a direct consequence: the **primary checkout** is the orchestrator (owns everything repo-wide), each **linked worktree** hosts exactly one worker (owns exactly its branch). Role detection is mechanical — a session whose `--git-dir` differs from `--git-common-dir` is in a linked worktree → worker — so simply *starting Claude in a worktree* is what makes it a worker; no configuration.

### How Graphite itself treats worktrees (and where the plugin is stricter)

Graphite's official position ([command reference](https://graphite.com/docs/command-reference)):

> "Graphite fully supports multiple Git worktrees. Starting in `gt` version `1.8.4`, Graphite does not modify branches checked out in another worktree in most cases."

Concretely, since 1.8.4: `gt sync`, `gt restack`, and `gt get` **skip** non-trunk branches checked out in another worktree; `gt modify --into` refuses to modify a branch checked out elsewhere; `gt undo` exits with an error rather than touching another worktree's branch; and `gt log` shows the worktree path next to each checked-out branch (useful orchestrator visibility).

**The forensic detail that matters for agent fleets:** "skip" means a restack *silently half-completes*. For a human juggling two worktrees that's a convenience — your other feature doesn't get yanked around underneath you; run `gt restack` from that worktree later. For an orchestrator reconciling five workers' branches it's a trap: `gt sync` reports success while some branches silently remain on stale parents. That is why the plugin's **prune-before-restack rule is stricter than gt's own behaviour** — the guard hook refuses orchestrator restacks while *any* agent worktree is attached, so every restack is total, never partial.

### Starting Claude in a worktree

Three ways, in order of how orchestrated the work is:

**1. Plugin protocol (orchestrated work — fan-outs, gt-delegate, gt-apply).** The orchestrator provisions, then the session (or subagent) starts inside:

```bash
# orchestrator, primary checkout:
git worktree add ../wt-avatar-api -b feat/avatar-api main
gt track feat/avatar-api --parent main

# worker, second terminal:
cd ../wt-avatar-api && claude
```

The SessionStart hook detects the linked worktree and injects the worker contract automatically. For subagent workers, `gt-delegate` does the provisioning and dispatching for you.

**2. Claude Code's native flag (ad-hoc parallel sessions).**

```bash
claude --worktree feature-auth       # or -w
```

This creates `.claude/worktrees/feature-auth/` on a new branch named `worktree-feature-auth`, based on **`origin/HEAD`** (a clean tree matching the remote — set `worktree.baseRef: "head"` in settings to base on your local HEAD instead). Three Graphite-repo caveats:

- The branch is **not gt-tracked**. Before any `gt submit` from that session, run `gt track worktree-feature-auth --parent main` (fine from the worker side — `gt track` on your own branch mutates only that branch's metadata ref).
- Branch and directory names won't match an orchestrator's manifest — use this for independent ad-hoc sessions, not as a substitute for protocol provisioning in a fan-out.
- Run `claude` once normally in the repo first (workspace trust must be accepted before `--worktree` works), and add `.claude/worktrees/` to `.gitignore`.

**3. Mid-session / harness-managed.** Asking Claude to "work in a worktree" (the `EnterWorktree` tool) or giving a subagent `isolation: worktree` creates harness-managed worktrees on auto-generated branches. As noted in Mode 3: do NOT use these for Graphite fan-outs — they live outside the manifest and the pre-provisioned topology. They're fine for non-Graphite isolation jobs.

**The branch-only equivalent, and the difference.** Without a worktree, "new line of work" is just `gt create -am "..."` in the primary checkout (Mode 1). A branch gives you *review* isolation (its own PR, its own diff) but not *working-tree* isolation: one checkout can have only one branch checked out, one index, one set of files. Two actors in one checkout collide on staging (`-a` sweeps the other's edits) and on file state. Rule of thumb: **a branch is enough while work is serialized; the moment two sessions/agents must run concurrently, each needs its own worktree.**

### Prep work before a worktree session starts

A fresh worktree is a *clean checkout of the branch* — nothing more. The five things that bite, in the order they bite:

1. **Branch provisioning + tracking** — protocol worktrees get this from the orchestrator (`git worktree add -b` + `gt track`); native `--worktree` branches need `gt track` before they can submit.
2. **Seed commit** — untracked/uncommitted files in the primary checkout do NOT exist in the new worktree. Anthropic's own docs flag this: *"If your main branch has uncommitted changes when you launch a worktree session, those changes won't be visible in the new worktree; commit or stash your changes before launching."* For delegated workloads, commit the inputs onto the branch before dispatch (gt-delegate's seeding rule).
3. **Gitignored files** (`.env`, `.env.local`, secrets) — never checked out anywhere. Two mechanisms:
   - A **`.worktreeinclude`** file at the repo root (gitignore syntax) makes Claude Code copy matching gitignored files into every worktree it creates (`--worktree`, subagent isolation, desktop sessions):
     ```text
     .env
     .env.local
     ```
   - For **manually-added** worktrees (the protocol path), copy by hand or in the dispatch brief: `cp <primary>/.env.local <worktree>/` — it stays gitignored there too.
4. **Dependencies** — `node_modules`, virtualenvs etc. are per-directory. Budget a `bun install` / `npm ci` / `uv sync` as the worker's first act.
5. **Permissions** — the repo's `.claude/settings.json` allowlist is tracked, so it's present in the worktree automatically; keep the worker-relevant allowlist there (see [parameters reference](#claude-code-parameters-reference)) so headless workers don't stall on prompts.

**Branch-only difference:** none of this exists. The primary checkout already has your env files, dependencies, and uncommitted context — that convenience is exactly what you trade away for concurrency.

### Delegating tasks in a worktree

**Packaged:** `/gt-delegate <workload> [branch]` does the whole single-worker lifecycle — provision, seed, manifest, dispatch a `gt-stack-worker` (background by default), reconvene with prune-before-restack. The workload is a skill invocation (`/opsx:apply my-change`) or a plain slice spec.

**Manual (interactive worker):** provision per the protocol, then open a second terminal, `cd ../wt-<slice> && claude`, and paste the slice spec. The hooks do the rest — you are now two humans-worth of sessions on one repo, safely.

**Manual (headless worker):**

```bash
cd ../wt-avatar-api && claude -p "Implement <slice spec>. Commit with git
commit, submit with gt submit --no-interactive. Report JSON." \
  --permission-mode acceptEdits
```

**Branch-only equivalent:** Mode 2a — sequential subagents in the primary checkout, one at a time, each doing `gt create -am` for its PR. Differences: strictly serialized (safe in one checkout only because nobody else has in-flight edits); no provisioning or prune ceremony; and `-a` staging is acceptable again. Use it when the slices are dependent anyway (a stack is an ordering — Mode 3's parallelism only ever applies to *independent* siblings).

### Using gt-apply with worktrees

`/gt-apply <change>` is invoked **from the orchestrator** — the primary checkout. It does the worktree work itself; you never pre-create anything:

1. Validates the change, derives `feat/<slug>`, confirms the plan.
2. Provisions branch + worktree, **seed-commits the change artifacts** (`openspec/changes/<change>/` is typically still untracked right after proposing — without the seed commit the worker's worktree wouldn't contain the spec it's applying).
3. Dispatches one `gt-stack-worker` into the worktree; the worker invokes `/opsx:apply` there, ticks `tasks.md` via that skill, commits with explicit paths, submits its own branch.
4. Reconvenes: prune → `gt sync` → `/opsx:verify` in the primary checkout → tracker update → PR link.

If you are *inside a worktree session* (worker role) and invoke `/gt-apply`, provisioning will be refused — branch pre-creation and manifest writes are orchestrator-owned, and the guard enforces the split. By design: run it from the primary session.

**Branch-only equivalent:** apply the change on a stacked branch in the primary checkout, no worktree at all — `gt create` the branch, run `/opsx:apply` directly in your own session, `gt submit` when green (single-agent Mode 1). Differences: your session is occupied for the whole apply (you can't propose or review anything else meanwhile); no second change can apply concurrently; but there is zero ceremony — no seed commit (your working tree already has the artifacts), no env copying, no prune. For one small change with you watching, branch-only is often the better deal; `/gt-apply` earns its ceremony when the apply is long, when you want the session back, or when two changes should apply side by side.

### Case study: propose in the primary checkout, apply in a worktree

A condensed real workflow (an OpenSpec change on a SvelteKit/Supabase repo), exactly as the skills run it:

```text
# ── 1. Propose (primary checkout, on main) ─────────────────────────────
you:    /opsx:propose group pupil strands by the location the adult covers…
claude: [creates openspec/changes/strand-grouping/{proposal,design,specs,tasks}.md]
        → artifacts exist but are UNTRACKED in the primary checkout

# ── 2. Apply on its own stacked branch, in a worktree ──────────────────
you:    /gt-apply strand-grouping
claude: change validated (4/4 artifacts) → plan:
          branch   feat/strand-grouping   (off main)
          worktree ../wt-strand-grouping
          seed     docs(openspec): add strand-grouping change artifacts
        Proceed?
you:    yes
claude: [gt sync · worktree add + gt track · seed commit · manifest ·
         creates tracker issue · dispatches gt-stack-worker (background)]
        → terminal returns to you; worker grinds in its worktree:
          bun install → /opsx:apply → per-task-group commits →
          gt submit --no-interactive → JSON report

# ── 3. Reconvene (notification arrives) ────────────────────────────────
claude: [git worktree remove -f -f ../wt-strand-grouping; git worktree prune]
        [gt sync]                 ← guard would BLOCK this before the prune
        [gt checkout feat/strand-grouping; /opsx:verify strand-grouping]
        → 19/20 tasks, PR #118, verify clean; manual visual check is yours

# ── 4. Amendment after your visual pass (no worktree needed any more) ──
you:    widen the separator ~50%
claude: [edits code + delta spec + tests IN LOCKSTEP on the branch,
         git add <explicit paths>; gt modify -c -m "fix: …";
         gt submit --no-interactive]          ← single-agent Mode 1 now

# ── 5. Archive ON the branch, then land ────────────────────────────────
you:    /opsx:archive strand-grouping
claude: [delta specs → canonical specs; change folder → archive/;
         commit rides in the SAME PR]         ← impl + specs + archive, atomic
you:    merge it
claude: [gt merge … gt checkout main; gt sync; gt delete feat/strand-grouping]
```

Field notes from running exactly this, twice:

- The **seed commit is not optional** — both real runs had the change folder untracked at apply time; a worktree without the seed commit hands the worker nothing to apply.
- The guard blocking `gt sync` *inside a compound command that also removes the worktree* is correct behaviour: it evaluates before anything executes. Prune and sync in separate commands.
- After the PR exists, amendments and archive are plain **single-agent branch work in the primary checkout** — the worktree's job ended at reconvene. Worktrees are for the *concurrent* phase only.
- If a background worker stalls, nothing is lost: per-task-group commits + the ticked checklist mean a fresh worker resumes in the same worktree from the last commit (see gt-delegate's failure handling).

**The same case study without a worktree** collapses steps 2–3 into: `gt create -am` an empty seed on a new branch (or just commit the artifacts), run `/opsx:apply` in your own session, `gt submit` — and your terminal is busy until it's done. Identical PR shape at the end; the difference is purely who waits.

### Sources

- [Graphite command reference](https://graphite.com/docs/command-reference) — official worktree semantics (gt ≥ 1.8.4 skip behaviour, `gt log` worktree paths, `gt undo` refusal)
- [Claude Code: worktrees](https://code.claude.com/docs/en/worktrees) — `--worktree`, base branch, `.worktreeinclude`, cleanup rules
- [Claude Code: common workflows](https://code.claude.com/docs/en/common-workflows) — parallel sessions guidance
- [Claude Code best practices](https://www.anthropic.com/engineering/claude-code-best-practices) — parallel-session counts, commit-before-worktree caveat
- [Git worktrees with Graphite](https://blog.matte.fyi/posts/git-worktrees-with-graphite/) — bare-repo + worktree-per-branch layout, `gt track` per worktree, pre-1.8.4 cautions
- [git-worktree documentation](https://git-scm.com/docs/git-worktree)

---

## Orchestrating OpenSpec changes (gt-delegate / gt-apply)

A common shape of Mode 3 is *one* worker carrying out a structured workflow — typically applying an [OpenSpec](https://github.com/Fission-AI/OpenSpec) change proposal — on its own stacked branch. Two skills package this, split deliberately into a **mechanism** and a **binding**:

| Layer | Where | Knows about |
|-------|-------|-------------|
| `gt-delegate` (mechanism) | `graphite` plugin | Worktrees, branches, the worker contract, reconvene order. Nothing about any workflow |
| `gt-apply` (binding) | `graphite-openspec` plugin | OpenSpec change resolution, `/opsx:apply` as the worker's workload, `/opsx:verify` at reconvene. Nothing about git/gt choreography |

The split keeps the workflows decoupled: if the OpenSpec workflow changes, only the binding changes; if the orchestration protocol changes, only the mechanism changes. Other workflow bindings (Linear, Jira, your own spec system) can layer on `gt-delegate` the same way.

### How the worker runs a workflow skill

`gt-stack-worker` carries the **Skill tool**, so a slice spec can say "invoke `/opsx:apply <change>`" instead of paraphrasing the workflow's steps. The worker then follows the workflow skill's own rules for the files it owns (task checklists, artifacts), while the worker contract + guard hook continue to police all git/gt behaviour. Apply progress (e.g. ticked `tasks.md` checkboxes) is committed on the worker's branch, so it travels with the PR. If the named skill isn't available in the worker's session, the worker stops and reports rather than hand-editing the workflow's files.

### Usage

```text
you:    /gt-apply timetabling-strand-location-grouping
claude: Plan: change timetabling-strand-location-grouping
        → branch feat/strand-location-grouping
        → worktree ../wt-strand-location-grouping (off main). Proceed?
you:    yes
claude: [gt sync; worktree add + gt track; manifest;
         dispatch gt-stack-worker → worker invokes /opsx:apply, implements,
         ticks tasks.md, commits, gt submit --no-interactive;
         reconvene: prune worktree → gt sync → /opsx:verify]
        → PR URL + verify outcome
```

Parameter inference (ask only when ambiguous): the change comes from the argument, else the conversation, else `openspec list --json`; the branch and worktree names are derived from the change name and surfaced in the confirmation step.

### Foreground vs background dispatch

Background is the **default**: the worker is dispatched with `run_in_background`, the orchestrator session returns control immediately, and reconvene happens when the worker's completion notification arrives. While a background worker runs you can keep using the session — including launching a second `/gt-apply` / `/gt-delegate` for an *independent* slice (sibling branch); the orchestrator serializes provisioning, the workers run concurrently, and the shared `gt sync` waits until every worktree is pruned.

Foreground ("wait for it") blocks the orchestrator until the worker reports: the terminal accepts no input, and — because a subagent's tool calls render inline in the parent session — it can *look* like the orchestrator is doing the implementation itself. It is not; all work happens in the worker's worktree under the worker contract. Reserve foreground for deliberate validation runs where fail-fast matters more than keeping the session free.

Variants:

- `/gt-apply <change> and wait` — explicit foreground dispatch (see above).
- `/gt-apply <change> --relay "<slice 1> / <slice 2>"` — split the change's task groups into a dependent stack; workers run sequentially via gt-delegate's relay variant.
- `/gt-delegate <skill-or-spec> [branch]` — the raw mechanism, for any other single-worker delegation (no OpenSpec required).

### Prerequisites

- `graphite` plugin enabled (provides `gt-delegate` + `gt-stack-worker`).
- `graphite-openspec` plugin enabled **in OpenSpec repos only** — it is a separate marketplace plugin precisely so non-OpenSpec repos never see `/gt-apply`.
- The repo's OpenSpec skills (`opsx:*`) available in the session, since the worker invokes them by name.

---

## Claude Code parameters reference

### CLI flags relevant to these workflows

| Flag | Use |
|------|-----|
| `claude` | Interactive session (orchestrator) |
| `claude -p "<prompt>"` | Headless one-shot (worker dispatch, CI) |
| `--permission-mode acceptEdits` | Auto-accept file edits; bash still gated by allowlist/guard |
| `--permission-mode plan` | Plan-only — useful for the Phase-0 slice plan |
| `--add-dir <path>` | Grant an interactive session access to worktree paths outside the cwd (e.g. `--add-dir ../wt-avatar-api`) so the orchestrator can inspect worker output |
| `--allowedTools "Bash(gt:*) Bash(git:*)"` | Pre-allow gt/git in headless workers so they don't stall on prompts (the guard hook still blocks forbidden verbs) |
| `--output-format json` | Headless workers emit machine-readable results for the orchestrator to parse |
| `--model <model>` | Pin worker model; orchestration benefits from a stronger model than mechanical slices |

### Agent tool parameters (in-session dispatch)

| Parameter | Recommendation |
|-----------|----------------|
| `subagent_type` | `"gt-stack-worker"` — the bundled, contract-constrained worker |
| `run_in_background` | `true` for concurrent workers; the orchestrator is notified as each completes |
| `isolation` | **Leave unset** for Graphite fan-outs (see Phase 2 note) — provision worktrees explicitly instead |
| `prompt` | Must include: worktree path, branch name, slice spec, acceptance criteria. The role contract itself is injected by the hooks |

### Permissions for unattended workers

Add to the repo's `.claude/settings.json` so headless workers don't stall:

```json
{
  "permissions": {
    "allow": [
      "Bash(git add:*)", "Bash(git commit:*)", "Bash(git status:*)", "Bash(git diff:*)",
      "Bash(gt modify:*)", "Bash(gt submit --no-interactive*)",
      "Bash(gt log*)", "Bash(gt ls*)", "Bash(gt info*)"
    ]
  }
}
```

Deliberately *not* allowlisted: `gt sync`, `gt restack`, `gt move`, `gt fold`, `gt delete`, `gt submit --stack` — and even if you allow them, `gt-guard.sh` blocks them in worker worktrees.

### MCP

With `graphite-mcp` installed, the orchestrator can route gt operations through `mcp__graphite__run_gt_cmd` instead of raw Bash. MCP calls serialize through the main session — a free mutual-exclusion point for metadata-mutating commands. Workers don't need the MCP server at all.

---

## The guard hook (gt-guard.sh)

Runs on every Bash tool call (PreToolUse), in Graphite repos only. Fails open outside them.

**In a linked worktree (worker role), blocks:**

- `gt sync`, `gt restack`
- `gt move`, `gt fold`, `gt reorder`, `gt split`, `gt absorb`, `gt delete`, `gt repo`
- `gt submit --stack`, `gt ss`

**In the primary checkout (orchestrator role), blocks:**

- `gt sync` / `gt restack` **while linked worktrees are attached**, with instructions to `git worktree remove` + `prune` first

Everything else passes through untouched, so single-agent use is completely unaffected. The block message is returned to the model, which course-corrects (workers report the blocker; orchestrators prune then retry).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Hook prints nothing on session start | Not a Graphite repo, or `gt init` not run | `gt init`; check `.git/.graphite_repo_config` exists |
| Worker got orchestrator context | Worker ran in the primary checkout, not a worktree | Provision a worktree (`git worktree add ...`) and start the worker inside it |
| `gt sync` blocked in main checkout | Agent worktrees still attached | `git worktree list`, then `remove -f -f` each + `prune`, retry |
| Restack conflicts after reconvene | Slices overlapped — they weren't independent | Resolve per `conflict-resolution.md`; next time merge those slices or relay them |
| Worker branch unknown to Graphite | Branch created with plain `git`, never tracked | `gt track <branch> --parent main`, then `gt restack` |
| Stale locked worktrees after harness-spawned agents | Harness leaves changed worktrees locked | `git worktree remove -f -f <path> && git worktree prune` |
| Two sessions both restacking | Two "orchestrators" | Exactly one primary checkout owns sync/restack; demote the other to a worker or close it |
