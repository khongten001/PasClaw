# Sample reference: style guide

This is a reference file. PasClaw advertises its absolute path in the
system prompt's SKILLS section so the model can `fs_read` it on demand
when a task calls for the bundled procedural knowledge — same convention
Anthropic agent-skills, picoclaw, and nanobot use.

Real references typically hold:

- Project-specific conventions ("we name commits like `<scope>: <verb>`")
- Domain knowledge the model can't reliably recall ("API X returns ISO-8601 in field Y")
- Worked examples of common task patterns

Keep references focused — the model only loads them when SKILL.md's body
points it here, so each reference should be self-contained enough to act
on after one read.
