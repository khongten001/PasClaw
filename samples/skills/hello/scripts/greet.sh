#!/usr/bin/env sh
# Sample script demonstrating the Phase 4 scripts/ runtime support.
#
# The model invokes this via shell_exec with an absolute path. With
# sandbox.restrict_to_workspace=true (recommended) the shell runs
# rooted at the workspace, so the model needs to pass the absolute
# path printed in the system prompt's SKILLS section.
#
# Real skills put their non-trivial automations here — small wrappers
# around CLI tools, multi-step shell pipelines that would clutter the
# SKILL.md body, etc. Keep the SKILL.md body for "when and why";
# scripts/ for "how", in code.
echo "hello from the sample skill"
echo "argv:"
for arg in "$@"; do
  printf '  %s\n' "$arg"
done
