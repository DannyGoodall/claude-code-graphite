---
name: gt-delegate
description: |
  Orchestrate a single gt-stack-worker subagent to carry out one workload on
  its own pre-provisioned stacked branch, in a linked git worktree, per the
  multi-agent Graphite protocol. The workload is either a skill invocation the
  worker runs via its Skill tool (e.g. "/opsx:apply my-change") or a plain
  slice spec. Triggers: /gt-delegate, "delegate this to a worker on its own
  branch", "run <skill> in a stacked worker", "single-worker fan-out".
  Requires a Graphite repo (.git/.graphite_repo_config). Workflow-agnostic:
  this skill owns the git/gt choreography only — what the worker does on the
  branch is entirely the workload's business.
---

# gt-delegate — one worker, one branch, one workload

You are the **orchestrator** (primary checkout). This skill is the
single-worker specialization of the fan-out protocol in
`references/multi-agent.md` (under the `graphite` skill) — read that file for
the full lifecycle, hazards, and manifest rules; do not improvise around it.

## 1. Resolve parameters (infer first, ask only on ambiguity)

- **workload** — from the arguments. Two forms:
  - *Skill form*: a leading `/name` or `name:subname` token (e.g.
    `/opsx:apply my-change`). The worker will invoke it via its Skill tool.
  - *Spec form*: anything else is a plain slice spec (what to build,
    acceptance criteria).
  If no workload can be determined from arguments or conversation context,
  ask the user.
- **branch** — explicit argument if given; otherwise derive
  `feat/<short-slug>` from the workload, matching the repo's existing branch
  naming (sample `gt ls` / recent PRs). Do not ask separately — surface it in
  the confirmation step.
- **worktree** — `../wt-<short-slug>`, derived from the branch.
- **trunk** — `gt trunk` (or the repo default).

## 2. Confirm (Phase 0 gate)

Run `gt sync` (clean start), then present one compact plan — workload, branch,
worktree, trunk — and wait for confirmation, exactly as single-agent stack
planning requires.

## 3. Provision (orchestrator only)

```bash
git worktree add <worktree> -b <branch> <trunk>
gt track <branch> --parent <trunk>
```

Write the manifest `.git/gt-agent-plan.json` with this one slice (format in
`references/multi-agent.md`).

## 4. Dispatch one worker

Spawn ONE `gt-stack-worker` subagent (NOT `isolation: "worktree"` — the
orchestrator-provisioned worktree above is the isolation). The prompt MUST
include:

- the worktree path (work there exclusively) and branch name;
- the workload — for skill form: "Invoke the Skill tool with skill
  `<name>` and args `<args>`. Follow that skill's rules for every file it
  owns."; for spec form: the slice spec verbatim;
- commit + submit expectations (conventional commits; `gt submit
  --no-interactive` on its own branch only);
- the structured JSON report requirement (the agent definition carries the
  format).

`run_in_background: true` when the user wants to keep working; otherwise wait.

## 5. Reconvene (strict order)

1. Collect the worker's JSON report; update the manifest, then delete it.
2. `git worktree remove -f -f <worktree> && git worktree prune` — ALWAYS
   before any restack, even on failure/blocked outcomes.
3. `gt sync` (resolve conflicts per `references/conflict-resolution.md`).
4. Verify the branch content by the workload's own standard (for a skill
   workload, prefer that workflow's verification step in the primary
   checkout over ad-hoc review).
5. Report to the user: branch, commits, PR URL, test outcome, any blockers.

## Failure handling

- Worker reports `blocked_on` → prune its worktree, relay the blocker to the
  user with the branch left intact for inspection. Never resolve cross-branch
  conflicts in the worker's name.
- Worker died without a report → inspect the worktree before pruning; salvage
  commits exist on the branch either way.

## Variants

- **Relay** (dependent follow-up slice): after reconvening slice 1, provision
  slice 2 parented on slice 1's branch (`git worktree add ../wt-2 -b
  <branch2> <branch1>; gt track <branch2> --parent <branch1>`) and dispatch
  the next worker. Never run dependent slices concurrently.
- **Parallel siblings**: more than one independent workload → this is the full
  fan-out; follow `references/multi-agent.md` directly rather than looping
  this skill.
