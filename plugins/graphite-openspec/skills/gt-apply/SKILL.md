---
name: gt-apply
description: |
  Apply an OpenSpec change on its own stacked branch via a single Graphite
  worker subagent. Binds the graphite plugin's gt-delegate mechanism to the
  OpenSpec apply workflow (/opsx:apply). Triggers: /gt-apply [change] [branch],
  "apply <change> on a stacked branch", "orchestrate the apply for <change>",
  "worker-apply this change". Requires: a Graphite repo
  (.git/.graphite_repo_config), an openspec/ directory with the opsx skills
  available, and the graphite plugin (gt-delegate + gt-stack-worker).
---

# gt-apply — OpenSpec apply on a stacked branch

A thin binding: resolve the OpenSpec-specific parameters, then hand off to the
`gt-delegate` skill (graphite plugin) with `/opsx:apply <change>` as the
workload. This skill owns nothing about git/gt choreography and nothing about
OpenSpec artifact rules — those belong to gt-delegate and the opsx skills
respectively. If either workflow changes, this binding should not need to.

## 1. Resolve the change (infer → ask)

In order:

1. Explicit argument (`/gt-apply <change-name>`).
2. The change under discussion in the current conversation.
3. `openspec list --json` filtered to changes with unticked tasks; if exactly
   one, use it.
4. Still ambiguous → AskUserQuestion with the candidate changes.

Validate the change exists and has artifacts ready for apply
(`openspec status --change "<name>" --json`). If apply-required artifacts are
missing, stop and tell the user to finish proposing first.

## 2. Derive names

- **branch**: second argument if given, else `feat/<short-slug>` from the
  change name (drop redundant prefixes; follow the repo's branch naming as
  gt-delegate prescribes).
- Worktree naming is gt-delegate's business.

## 3. Hand off to gt-delegate

Invoke the `gt-delegate` skill (graphite plugin) with:

- **workload (skill form)**: invoke the OpenSpec apply skill —
  `opsx:apply` (fallback name `openspec-apply-change`) — with the change name.
  The dispatch prompt MUST tell the worker to work through the change's
  `tasks.md` via that skill (which owns task selection and checkbox
  discipline), never by hand-editing OpenSpec artifacts outside it, and to
  commit the ticked `tasks.md` alongside the implementation so apply progress
  travels with the PR.
- **branch**: from step 2.

gt-delegate runs the confirm → provision → dispatch → reconvene lifecycle
(background dispatch by default — the session stays free, and another
`/gt-apply` or `/gt-delegate` can run a second independent slice concurrently).

**Provisioning note (seed commit):** a freshly proposed change's
`openspec/changes/<name>/` folder is typically still UNTRACKED in the primary
checkout, so it will not exist in the worker's fresh worktree. Per
gt-delegate's seeding rule, commit the change folder onto the branch before
dispatch (e.g. `docs(openspec): add <change> change artifacts`) — the worker's
ticked tasks.md then evolves from that commit and travels with the PR.

## 4. OpenSpec reconvene tail (after gt-delegate's step 5)

In the primary checkout:

1. Run the OpenSpec verify workflow (`opsx:verify`, fallback
   `openspec-verify-change`) against the change. Note: until the worker's PR
   merges, the implementation lives on the worker's branch — check out the
   branch (orchestrator-side, after the worktree is pruned) or verify against
   the PR diff.
2. If the project's conventions link changes to an issue tracker (e.g. a
   Linear umbrella issue per change), update it with the PR link and status.
3. Report: change name, branch, PR URL, verify outcome, remaining unticked
   tasks (if the worker stopped early or was blocked).

## Variants

- **Relay stack** (`/gt-apply <change> --relay "<slice 1> / <slice 2>"`):
  split the change's task groups into dependent slices and use gt-delegate's
  relay variant — each slice's worker is still told to use the opsx apply
  skill, scoped to its slice's task groups.
- **Background**: append "in the background" — gt-delegate dispatches with
  `run_in_background` after provisioning.
