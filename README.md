# Claude Code Graphite

Claude Code plugins for [Graphite](https://graphite.dev) stacked PRs workflow.

> **Attribution:** This is a fork of [georgeguimaraes/claude-code-graphite](https://github.com/georgeguimaraes/claude-code-graphite)
> by **George Guimarães**, who authored the original plugin — the gt-instead-of-git
> skill, stack planning rules, conflict-resolution guidance, and SessionStart hook.
> All of that core work is his; this fork builds on top of it. Licensed under
> Apache 2.0 (see [LICENSE](LICENSE)).

📖 **[MANUAL.md](MANUAL.md)** — full usage guide for single-agent, multi-synchronous, and multi-async (worktree) modes, including Claude Code CLI parameters, Agent tool settings, and permission configuration.

## What this fork adds: multi-agent orchestration

The upstream plugin assumes one actor in one checkout. This fork extends it so
**multiple agents can work asynchronously (at the same time) on different parts
of a project, coordinated by an orchestrator agent** — without corrupting the
stack. Three things break in naive multi-agent Graphite use: restacks rewrite
refs repo-wide (and fail on branches checked out in other worktrees),
`gt create -am`/`gt modify -a` stage *everything* in a shared checkout, and
Graphite's metadata cache is shared and last-write-wins. The additions address
each with a two-role contract (**orchestrator** in the primary checkout,
**worker** in a linked git worktree), enforced in layers:

| Change | File | Purpose |
|--------|------|---------|
| Role-aware SessionStart hook | `plugins/graphite/hooks/scripts/graphite-context.sh` | Detects linked worktrees via `--git-common-dir` (also fixes detection from worktrees/subdirs) and injects the worker contract or orchestrator rules accordingly |
| PreToolUse guard | `plugins/graphite/hooks/scripts/gt-guard.sh` + `hooks.json` | Deterministically blocks repo-wide `gt` verbs in worker worktrees, and blocks orchestrator restacks while agent worktrees are still attached (prune-before-restack) |
| Multi-agent skill section | `plugins/graphite/skills/graphite/SKILL.md` | Roles, command-ownership matrix, topology rules (parallel ⇒ siblings off trunk), reconvene checklist |
| Multi-agent protocol reference | `plugins/graphite/skills/graphite/references/multi-agent.md` | Full fan-out lifecycle (plan → provision → dispatch → work → reconvene), concurrency hazards table, agent plan manifest (`.git/gt-agent-plan.json`), relay pattern for dependent slices |
| Worker subagent | `plugins/graphite/agents/gt-stack-worker.md` | A constrained `gt-stack-worker` agent type for fan-outs, with a structured JSON report the orchestrator consumes. Carries the Skill tool so a slice spec can name a workflow skill (e.g. an OpenSpec apply) for the worker to run |
| Single-worker delegation skill | `plugins/graphite/skills/gt-delegate/SKILL.md` | `gt-delegate`: the fan-out protocol specialized to one workload → one branch → one worker → reconvene. Workflow-agnostic |
| OpenSpec binding plugin | `plugins/graphite-openspec/` | `gt-apply`: applies an OpenSpec change on its own stacked branch via gt-delegate. Separate plugin so non-OpenSpec repos never see it |
| Manual | [MANUAL.md](MANUAL.md) | End-to-end usage in all three modes, with claude CLI/Agent-tool parameters |

The goal: advice in context (hooks), enforcement in tooling (guard), and a
repeatable protocol (reference + agent), so the orchestration recipe doesn't
depend on any agent remembering the rules. Single-agent behavior is unchanged —
the guard and worker context only activate in linked worktrees.

## Installation

There is no central plugin registry — `claude plugin marketplace add` accepts
**a URL, a local path, or a GitHub repo**, and simply reads the
`.claude-plugin/marketplace.json` manifest it finds there. So this fork installs
the same way the upstream does; just point at the fork instead.

### From this fork (local clone)

```bash
# Point the marketplace at the clone directory (absolute or relative path)
claude plugin marketplace add /path/to/claude-code-graphite

# Then install the plugins from it
claude plugin install graphite@claude-code-graphite
claude plugin install graphite-mcp@claude-code-graphite
claude plugin install graphite-openspec@claude-code-graphite   # only for OpenSpec repos
```

After pulling new changes into the clone, refresh with:

```bash
claude plugin marketplace update claude-code-graphite
claude plugin update graphite@claude-code-graphite
```

### From a GitHub fork

```bash
claude plugin marketplace add <your-username>/claude-code-graphite
claude plugin install graphite@claude-code-graphite
claude plugin install graphite-mcp@claude-code-graphite
```

> **Note:** the marketplace name comes from the `name` field in
> `.claude-plugin/marketplace.json` (`claude-code-graphite`), not from the repo
> location. If you previously added the upstream marketplace, remove it first or
> the names will collide:
> `claude plugin marketplace remove claude-code-graphite`

### Without a marketplace at all (session-only)

For trying it out or plugin development, load the plugin directory directly —
no marketplace registration needed:

```bash
claude --plugin-dir /path/to/claude-code-graphite/plugins/graphite
```

Validate the manifests after making changes:

```bash
claude plugin validate /path/to/claude-code-graphite
```

### Upstream (original plugin, without this fork's multi-agent additions)

```bash
claude plugin marketplace add georgeguimaraes/claude-code-graphite
claude plugin install graphite@claude-code-graphite && \
claude plugin install graphite-mcp@claude-code-graphite
```

## Prerequisites

| Platform | Command |
|----------|---------|
| macOS | `brew install withgraphite/tap/graphite` |
| npm | `npm install -g @withgraphite/graphite-cli@stable` |

> **Note:** MCP server requires Graphite CLI v1.6.7 or later.

---

## Plugins

### Overview

| Plugin | Type | Description |
|--------|------|-------------|
| [graphite](#graphite) | Skill + Hook | gt commands, stack planning, conflict resolution |
| [graphite-mcp](#graphite-mcp) | MCP | Graphite MCP server integration (gt mcp) |

---

### graphite

Skill and hooks for Graphite CLI (`gt`) stacked PR workflows.

| Feature | Description |
|---------|-------------|
| Detection | Auto-detects Graphite repos via `.git/.graphite_repo_config` |
| Commands | Uses `gt` commands instead of `git` for commits/branches |
| Stack planning | Break features into atomic, reviewable PRs |
| Conflict resolution | Guidance for handling restack conflicts |
| SessionStart hook | Role-aware context: orchestrator rules in the primary checkout, worker contract in linked worktrees |
| PreToolUse guard | Blocks role-violating `gt` commands in multi-agent mode (`gt-guard.sh`) |
| Multi-agent protocol | Orchestrator/worker fan-out across git worktrees (`references/multi-agent.md`) |
| Worker agent | `gt-stack-worker` subagent for parallel slice implementation |

**Commit style:** Conventional commits (feat:, fix:, etc.), casual and concise, no LLM fluff.

**PR bodies:** What changed, why, and the benefit.

---

### graphite-mcp

MCP server integration for Graphite CLI.

| Feature | Description |
|---------|-------------|
| MCP tools | Graphite tools via Model Context Protocol |
| Command | Uses `gt mcp` from Graphite CLI (v1.6.7+) |

> **Multi-agent note:** in fan-out mode, route orchestrator-side gt operations
> through `mcp__graphite__run_gt_cmd` rather than raw Bash — MCP calls serialize
> through the main session, giving metadata-mutating commands free mutual
> exclusion. Workers don't need the MCP server.

---

## License

Copyright (c) 2026 George Guimarães

Licensed under the Apache License, Version 2.0.
