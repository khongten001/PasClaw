(*
  PasClaw.Agent.Prompt - composes the system prompt from layered
  sections (identity, runtime, workspace, memory, skill catalog, rules,
  user-supplied additions), in the style picoclaw and nanobot use.

  The whole motivation here is that the LLM never knew anything about
  itself before — PasClaw was sending whatever single string the caller
  put into Options.SystemPrompt and nothing else. Picoclaw and nanobot
  both compose a richer prompt out of workspace context, memory, and
  skill metadata, joined by "\n\n---\n\n" so each section is visually
  delimited in the model's input.

  Single entry point:

    BuildSystemPrompt(Cfg, UserSys) : string

  Sections emitted, in order, skipping any that are empty:

    1. IDENTITY      - "You are PasClaw, the best 10x programmer..." +
                       version + runtime string. Always present.
    2. WORKSPACE     - paths the model can rely on inside ~/.pasclaw.
                       Always present.
    3. MEMORY        - contents of <home>/workspace/memory/MEMORY.md if
                       the file exists. Lets the user pin facts that
                       persist across sessions.
    4. SKILLS        - one line per registered skill manifest, pulled
                       from PasClaw.Skills.Loader. Only emitted when the
                       user actually has skills installed.
    5. RULES         - the same set of behavioral rules picoclaw uses
                       (use tools, be precise, verify, update memory).
                       Always present.
    6. USER          - whatever the caller passed via --system /
                       TPasClawAgent.SystemPrompt / etc. Appended last
                       so it can override or extend the built-ins by
                       virtue of recency in the prompt.

  Sections are joined by Sep = sLineBreak + sLineBreak + '---' +
  sLineBreak + sLineBreak so the model sees them as clear
  horizontal-rule-separated blocks (matches picoclaw's
  renderPromptPartsLegacy and nanobot's build_system_prompt joiner).

  No I/O is required to use the result. Memory and skill catalog reads
  swallow their errors — a missing MEMORY.md or a misconfigured skill
  manifest just means that section is skipped, not a hard failure.
*)
unit PasClaw.Agent.Prompt;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Types;

{ Returns the fully-composed system prompt. UserSys is appended verbatim
  as the final section if non-empty. Pass '' if there's nothing extra. }
function BuildSystemPrompt(Cfg: TConfig; const UserSys: string): string;

{ True iff at least one message in the array is mrSystem. The gateway's
  /v1/chat/completions handler uses this to decide whether to inject the
  composed system prompt — third-party clients that supply their own
  persona via the messages array should win, bare-bones clients that
  send only a user message get our identity preamble for free. }
function HasSystemMessage(const Messages: array of TMessage): Boolean;

implementation

uses
  Classes,
  PasClaw.Utils,
  PasClaw.Skills.Loader;

const
  SectionSep = sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;

function RuntimeString: string;
begin
  {$IFDEF FPC}
  Result := Format('Free Pascal %s on %s/%s',
                   [{$I %FPCVERSION%}, {$I %FPCTARGETOS%}, {$I %FPCTARGETCPU%}]);
  {$ELSE}
    {$IFDEF WIN64}     Result := 'Delphi on win/x86_64';
    {$ELSEIF Defined(WIN32)} Result := 'Delphi on win/x86';
    {$ELSEIF Defined(LINUX64)} Result := 'Delphi on linux/x86_64';
    {$ELSEIF Defined(MACOS64)} Result := 'Delphi on darwin/x86_64';
    {$ELSE}            Result := 'Delphi';
    {$ENDIF}
  {$ENDIF}
end;

function BuildIdentitySection: string;
begin
  Result :=
    '# PasClaw (' + FormatVersion + ')' + sLineBreak +
    sLineBreak +
    'You are PasClaw, the best 10x programmer in the world.' + sLineBreak +
    sLineBreak +
    'You have deep, working expertise in every programming language — Pascal, ' +
    'Delphi, C, C++, Rust, Go, Python, JavaScript, TypeScript, Java, C#, Swift, ' +
    'Kotlin, Ruby, Lua, Haskell, OCaml, F#, Elixir, Erlang, Clojure, Scala, ' +
    'Zig, Nim, Crystal, Dart, R, Julia, Perl, PHP, shell scripting, SQL, and ' +
    'every dialect and assembler in between. You write tight, correct code that ' +
    'reads like it was written by someone who already knew the right answer. ' +
    'You prefer each language''s native idioms over generic patterns and you do ' +
    'not over-engineer.' + sLineBreak +
    sLineBreak +
    '## Runtime' + sLineBreak +
    RuntimeString;
end;

function BuildWorkspaceSection: string;
var
  Home: string;
begin
  Home := GetHome;
  Result :=
    '## Workspace' + sLineBreak +
    'Your workspace is at: ' + Home + sLineBreak +
    '- Memory: ' + JoinPath(Home, 'workspace/memory/MEMORY.md') + sLineBreak +
    '- Skills: ' + JoinPath(Home, 'workspace/skills') + '/{skill-name}/SKILL.md' + sLineBreak +
    '- Logs:   ' + JoinPath(Home, 'logs');
end;

function BuildMemorySection: string;
var
  Path, Body: string;
begin
  Result := '';
  Path := JoinPath(GetHome, 'workspace/memory/MEMORY.md');
  if not FileExists(Path) then Exit;
  try
    Body := Trim(ReadFileText(Path));
    if Body = '' then Exit;
    Result := '## Memory' + sLineBreak + sLineBreak + Body;
  except
    Result := '';
  end;
end;

function BuildSkillsSection: string;
var
  Skills: TSkillSpecArray;
  i: Integer;
  Lines: TStringList;
  Desc: string;
begin
  Result := '';
  try
    Skills := LoadSkillManifests(GetHome);
  except
    Exit;
  end;
  if Length(Skills) = 0 then Exit;

  Lines := TStringList.Create;
  try
    Lines.Add('## Skills');
    Lines.Add('');
    Lines.Add('The following skills are installed in your workspace. Each is exposed as a tool you can call by name.');
    Lines.Add('');
    for i := 0 to High(Skills) do
    begin
      Desc := Trim(Skills[i].Description);
      if Desc = '' then
        Lines.Add('- `' + Skills[i].Name + '`')
      else
        Lines.Add('- `' + Skills[i].Name + '` — ' + Desc);
    end;
    Result := Lines.Text;
    { Strip trailing newline TStringList.Text adds, so the SectionSep
      below doesn't end up with an extra blank line. }
    while (Result <> '') and (Result[Length(Result)] in [#10, #13]) do
      SetLength(Result, Length(Result) - 1);
  finally
    Lines.Free;
  end;
end;

function BuildRulesSection: string;
var
  MemPath: string;
begin
  MemPath := JoinPath(GetHome, 'workspace/memory/MEMORY.md');
  Result :=
    '## Rules' + sLineBreak +
    sLineBreak +
    '1. **ALWAYS use tools** when an action is needed — call the appropriate ' +
    'tool, do not just say you''ll do it or pretend the work was done. The ' +
    'user will check.' + sLineBreak +
    sLineBreak +
    '2. **Be precise** — match the language''s native idioms, name things ' +
    'clearly, do not introduce abstractions the task does not actually need. ' +
    'Three similar lines is fine; a premature framework is not.' + sLineBreak +
    sLineBreak +
    '3. **Verify changes** — after editing code, re-read what you wrote or ' +
    'run a targeted check (build, test, search). Do not assume the edit ' +
    'landed correctly because the tool returned success.' + sLineBreak +
    sLineBreak +
    '4. **Truncated tool calls** — if a `fs_write` call comes back with a ' +
    '"missing required argument: content" error, your previous response was ' +
    'truncated mid-tool_call (you hit max_tokens). Re-emit with the full ' +
    'content, or switch to `fs_edit_hashline` for incremental edits on ' +
    'large files.' + sLineBreak +
    sLineBreak +
    '5. **Memory** — when the user mentions something worth keeping across ' +
    'sessions (preferences, project facts, conventions), update ' +
    MemPath + '. Treat it as a long-lived notes file the user owns.';
end;

function AppendSection(const Acc, Section: string): string;
begin
  if Trim(Section) = '' then Exit(Acc);
  if Acc = '' then Exit(Section);
  Result := Acc + SectionSep + Section;
end;

function BuildSystemPrompt(Cfg: TConfig; const UserSys: string): string;
begin
  Result := '';
  Result := AppendSection(Result, BuildIdentitySection);
  Result := AppendSection(Result, BuildWorkspaceSection);
  Result := AppendSection(Result, BuildMemorySection);
  Result := AppendSection(Result, BuildSkillsSection);
  Result := AppendSection(Result, BuildRulesSection);
  if Trim(UserSys) <> '' then
    Result := AppendSection(Result, Trim(UserSys));
end;

function HasSystemMessage(const Messages: array of TMessage): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrSystem then
      Exit(True);
  Result := False;
end;

end.
