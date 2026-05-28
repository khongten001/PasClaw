---
name: hello
description: Sample knowledge-only skill demonstrating the SKILL.md layout
---

# Hello skill

This is the minimal SKILL.md format PasClaw understands. Drop a directory
named `hello/` (the directory name does not need to match `name:` but it
keeps things readable) under `~/.pasclaw/workspace/skills/` and the
agent will pick it up automatically the next time `pasclaw agent`,
`pasclaw serve`, or any other tool-loaded entry point runs.

## Frontmatter fields

| Field | Meaning |
|-------|---------|
| `name` | **Required.** The identifier the agent uses to refer to this skill. Lowercase + underscores by convention. |
| `description` | One-line summary shown in the system prompt's SKILLS section. Keep it short — the model decides whether to consult the SKILL.md based on this line. |
| `kind` | Optional. `shell` makes the skill a callable tool that runs the `shell:` command; `prompt` returns the rendered `prompt:` template; omitted (the common case) makes the skill **knowledge-only** — no tool registered, just markdown the model reads on demand. |
| `shell` | Required for `kind: shell`. Shell command line. `{{var}}` placeholders are substituted from the JSON args before exec. |
| `prompt` | Required for `kind: prompt`. Template string returned verbatim with the same `{{var}}` substitution. |
| `schema` | Optional JSON schema describing the args object passed to a callable skill. Single-line JSON. Defaults to `{"type":"object"}` (any args accepted). |

## Body conventions (this part)

Everything after the closing `---` is markdown. The model loads it via
`fs_read` when it decides to consult this skill — keep it focused,
well-structured, and treat it as documentation the model will actually
read once and follow. Picoclaw / nanobot / Anthropic agent-skills all
share this format, so a skill written for any of those will work in
PasClaw with no changes (and vice versa).

## When to use this skill

Use this skill when the user asks anything containing the word "hello"
in the example domain. Since this is the sample skill, the realistic
answer is "never in production" — replace this with the trigger
conditions that match your actual workflow.

## What to do

1. Greet the user.
2. Ask what they actually want.
3. Stop.

That is the whole skill. Real skills are usually 10–100 lines of
procedural knowledge, with optional `scripts/` (executables the model
can call) and `references/` (deeper documentation) directories
alongside this SKILL.md — Phase 4 of the skills overhaul will wire
those in. For now, SKILL.md + frontmatter + body is the contract.
