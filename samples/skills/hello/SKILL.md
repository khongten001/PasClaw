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
procedural knowledge, with optional `scripts/`, `references/`, and
`assets/` directories alongside this SKILL.md:

- `scripts/` — executables the model invokes via `shell_exec`
  (sandbox-aware: workspace-pinned, denylist-checked). The model sees
  each script's absolute path in the system prompt's SKILLS section
  and decides when to run it. `scripts/greet.sh` next to this file
  demonstrates the layout.

- `references/` — markdown documentation the model loads on demand via
  `fs_read`. Use this for project-specific conventions, domain knowledge,
  or worked examples the model can pull in when SKILL.md's body points
  it here. `references/style-guide.md` next to this file is the sample.

- `assets/` — templates, fixtures, images, etc. that the skill bundles.
  PasClaw advertises their paths so the model knows they exist.

PasClaw walks these subdirectories during `LoadSkillManifests` and
emits each file's absolute path in the system prompt — the model
discovers what's available without having to `fs_list` the skill
directory.
