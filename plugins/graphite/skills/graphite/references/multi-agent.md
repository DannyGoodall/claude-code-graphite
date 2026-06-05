# Multi-Agent Graphite Protocol

Detailed protocol for fanning work out to multiple agents working
asynchronously (at the same time) on different parts of a project, coordinated
by an orchestrator. Read this when actually running a fan-out; the summary
lives in the "Multi-Agent Orchestration" section of SKILL.md.

## Why a protocol is needed

All git worktrees share one `.git`, including Graphite's state:

1. **Restacks are repo-wide.** `gt sync` / `gt restack` rewrite refs across
   the whole stack and *fail (or half-complete) on any branch checked out in
   another worktree*. Git refuses to rebase a branch that is checked out
   elsewhere.
2. **`gt create -am` / `gt modify -a` stage everything.** In a shared
   checkout, agent A's `-am` sweeps up agent B's in-flight edits.
3. **Graphite metadata is shared.** Per-branch metadata lives in
   `refs/branch-metadata/*` (atomic per ref), but the persisted cache
   (`.git/.graphite_cache_persist`) is last-write-wins. Concurrent
   metadata-mutating `gt` commands from multiple worktrees can race.

The protocol's answers, respectively: centralize restacks in the
orchestrator; one worktree per worker; the orchestrator pre-creates all
branches so workers never need a metadata-mutating `gt` command.

## Fan-Out Lifecycle

### Phase 0 — Plan (orchestrator)

```bash
gt sync                      # start from latest trunk, clean state
```

- Decompose the feature into **independent slices** — sibling branches off
  trunk. Each slice = one branch = one PR = one worker.
- Present the slice plan to the user and get confirmation (same rule as
  single-agent stack planning).
- If two slices depend on each other, they are NOT parallel work — use the
  relay pattern (below) or give both to one worker.

### Phase 1 — Provision (orchestrator)

Pre-create branch + worktree per slice. This serializes all Graphite metadata
writes through the orchestrator (hazard 3):

```bash
git worktree add ../wt-<slice> -b feat/<slice> main
gt track feat/<slice> --parent main
```

Then write the agent plan manifest (format below).

### Phase 2 — Dispatch (orchestrator)

Spawn one worker per worktree. Each worker is told:

- its worktree path (work there exclusively),
- its slice spec (what to build, acceptance criteria),
- the worker contract (injected automatically by the SessionStart hook when
  the worker starts inside a linked worktree; enforced by `gt-guard.sh`).

Prefer pointing workers at orchestrator-provisioned worktrees over letting an
agent harness create its own isolated worktree — naming and lifecycle stay
under orchestrator control, which the prune-before-restack rule depends on.

### Phase 3 — Work (workers, concurrently)

Each worker, inside its own worktree:

```bash
# edit files ...
git add -A && git commit -m "feat: <slice change>"   # or gt modify -a after first commit
gt submit --no-interactive                            # own sibling branch only
```

- Commits stay atomic; conventional commit style.
- No branch switching, no restacks, no stack-wide submits (guard-enforced).
- On a conflict or cross-slice dependency: **stop and report**, never resolve
  across branches.
- Final report is raw data: branch, commits, submitted?, blocked_on,
  conflicts_seen.

### Phase 4 — Reconvene (orchestrator)

Strictly in this order:

```bash
# 1. collect worker reports, update manifest statuses
# 2. remove ALL agent worktrees BEFORE any restack
git worktree remove -f -f ../wt-<slice>    # per worktree
git worktree prune

# 3. now safe to restack
gt sync                                    # resolve conflicts per conflict-resolution.md

# 4. optional: stitch siblings into a dependent stack
gt checkout feat/slice-b
gt move --onto feat/slice-a

# 5. submit everything
gt submit --stack --no-interactive
```

If a worker created plain git branches without Graphite tracking, adopt them
first: `gt track <branch> --parent main`, then restack.

## Agent Plan Manifest

One file, owned by the orchestrator, kept inside `.git/` so it can never land
in a commit: `.git/gt-agent-plan.json`

```json
{
  "trunk": "main",
  "created": "2026-06-05",
  "slices": [
    { "branch": "feat/avatar-api", "worktree": "../wt-avatar-api", "status": "in-progress", "agent": "worker-1" },
    { "branch": "feat/avatar-ui",  "worktree": "../wt-avatar-ui",  "status": "done",        "agent": "worker-2" }
  ],
  "stitch_plan": ["feat/avatar-api", "feat/avatar-ui"]
}
```

Rules:

- Orchestrator creates it and is the **only writer of topology** (slices,
  branches, worktrees, stitch_plan).
- Each worker may update **only its own `status` field** (own-row rule —
  concurrent writers never touch the same field).
- `stitch_plan` records the intended bottom-to-top order if siblings are to be
  converted into a stack at reconvene; omit it if they merge independently.
- Delete the manifest after reconvening.

## Concurrency Hazards Table

| Hazard | Failure mode | Mitigation |
|--------|--------------|------------|
| Restack while worktrees live | rebase refuses / half-completed stack rewrite | Prune-before-restack rule; `gt-guard.sh` blocks it |
| `-am` in shared checkout | one agent commits another's edits | One worktree per worker, never share a checkout |
| Concurrent `gt create`/metadata writes | cache corruption, last-write-wins | Orchestrator pre-creates all branches |
| Concurrent `gt submit` mid-stack | submit pushes downstack branches too — racing rewrites | Workers submit **sibling** branches only; mid-stack submits are orchestrator-only |
| Two orchestrators | competing restacks | Exactly one primary checkout runs sync/restack; everything else is a worker |

Concurrent `gt submit --no-interactive` on **siblings** is safe — disjoint
refs, disjoint PRs.

## Worker Conflict Policy

Workers never resolve cross-branch conflicts. Merge/rebase conflicts only
exist at reconvene time and belong to the orchestrator, who applies the
standard rules from `conflict-resolution.md`:

- Auto-resolve: import order, whitespace, non-overlapping additions, lock
  files (regenerate).
- Ask the user: same code modified differently, delete-vs-modify, semantic
  conflicts, test expectation changes.

If two slices conflict heavily at reconvene, that is a planning signal: those
slices were not independent and should have been one slice or a relay.

## Relay Pattern (dependent slices)

For genuinely dependent work (PR2 needs PR1's code), do NOT run workers
concurrently. Relay instead:

1. Worker A builds `feat/part-1` off main, submits, reports done.
2. Orchestrator verifies, *then* provisions `feat/part-2` **parented on
   `feat/part-1`**, and a fresh worktree:
   ```bash
   git worktree add ../wt-part-2 -b feat/part-2 feat/part-1
   gt track feat/part-2 --parent feat/part-1
   ```
3. Worker B builds part 2 in that worktree.
4. If part 1 needs amending while B is live: B's worktree must be removed
   before the restack that propagates the amendment. Sequence it — amendments
   to downstack branches and live upstack worktrees cannot coexist.

A useful hybrid: parallel sibling workers for the independent slices, plus one
relay chain for the dependent ones.
