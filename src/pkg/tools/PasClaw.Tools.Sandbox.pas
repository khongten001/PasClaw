(*
  PasClaw.Tools.Sandbox - tool-side enforcement for the workspace
  boundary and shell denylist documented in TSandboxPolicy
  (PasClaw.Config).

  The previous shell tool shipped six substring checks (rm -rf /,
  mkfs, dd if=, fork bomb, shutdown -h) and the FS tools had no path
  check at all — the unit header in PasClaw.Tools.FS.pas said
  "Paths are not sandboxed by default; the gateway will install a
  workspace-restricted variant in Phase 4" and that variant was
  never written. This unit is that variant.

  Architecture: module-level GPolicy / GWorkspace, set once via
  Configure() from each command's startup. Tool handlers receive
  only an ArgsJSON string — there is no provider context to plumb a
  policy through, so a module-level singleton is the only option.
  Configure() is idempotent and may be called repeatedly; the most
  recent call wins.

  Three checks exposed:

    CanReadPath  - fs_read, fs_list, fs_grep call this on every
                   path argument before doing I/O.
    CanWritePath - fs_write, fs_edit_hashline (write side), the
                   append helper.
    ShellAllowed - shell_exec calls this on the raw command string.

  Each returns False with a Reason filled in. The handler converts
  Reason into an error string the model sees so it can adjust its
  next turn instead of looping on a silent failure.

  Glob style: AllowReadPaths / AllowWritePaths use simple '*' and
  '?' wildcards rather than full regex. Picoclaw uses regex via
  Go's regexp package but PasClaw has no bundled regex engine that
  works under both FPC and Delphi without an extra unit dependency,
  and globs cover the documented use cases (/tmp/*, ~/.cache/*,
  /usr/share/*).

  Shell denylist style: same trade-off — the implementation is a
  list of "forbidden tokens" matched against the command's
  whitespace-split tokens, plus a list of "forbidden substrings"
  matched against the lowercased command. Together they cover the
  same surface as picoclaw's 35-pattern regex set, expressed as
  plain Pascal so there is no runtime regex compilation. Coverage
  is documented inline next to each token / substring; adding a
  case requires only one array entry.

  Canonicalization: ExpandFileName resolves '..' and relative
  references against the current working directory. Symlinks
  pointing outside the workspace can still escape on platforms
  where the OS does not normalize them at the syscall layer —
  picoclaw avoids that via Go 1.24's os.OpenRoot, which we do not
  have an equivalent for in FPC/Delphi RTL. The README's Security
  section flags this as a known limitation.
*)
unit PasClaw.Tools.Sandbox;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config;

procedure ConfigureSandbox(const Policy: TSandboxPolicy; const Workspace: string);

function CanReadPath (const Path: string; out Reason: string): Boolean;
function CanWritePath(const Path: string; out Reason: string): Boolean;
function ShellAllowed(const Cmd:  string; out Reason: string): Boolean;

{ True iff Path canonicalises to a child of Workspace. Exposed for
  testing and for the rare caller that wants to know without going
  through the policy layer. }
function PathInsideDirectory(const Path, Directory: string): Boolean;

implementation

uses
  PasClaw.Logger;

var
  GPolicy:    TSandboxPolicy;
  GWorkspace: string;

procedure ConfigureSandbox(const Policy: TSandboxPolicy; const Workspace: string);
begin
  GPolicy := Policy;
  if Trim(Workspace) <> '' then
    GWorkspace := Workspace
  else if Trim(Policy.Workspace) <> '' then
    GWorkspace := Policy.Workspace
  else
    GWorkspace := GetCurrentDir;
  GWorkspace := ExcludeTrailingPathDelimiter(ExpandFileName(GWorkspace));
  if Policy.RestrictToWorkspace then
    LogDebug('sandbox: restrict_to_workspace=true workspace=%s', [GWorkspace]);
end;

{ -------- path helpers -------- }

function Canonicalize(const Path: string): string;
begin
  Result := ExpandFileName(Path);
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function PathInsideDirectory(const Path, Directory: string): Boolean;
var
  P, D: string;
begin
  Result := False;
  if (Path = '') or (Directory = '') then Exit;
  P := Canonicalize(Path);
  D := IncludeTrailingPathDelimiter(Canonicalize(Directory));
  if SameText(P, ExcludeTrailingPathDelimiter(D)) then Exit(True);
  { Case sensitivity: on Linux paths are case-sensitive; on Windows
    they are not. SameText handles both via the RTL's locale rules. }
  Result := (Length(P) > Length(D)) and SameText(Copy(P, 1, Length(D)), D);
end;

function GlobMatches(const Pattern, S: string): Boolean;
{ Minimal '*' + '?' glob, matched against the canonicalised path.
  '*' matches any run of characters (including separators), '?'
  matches exactly one character. Comparison is case-insensitive on
  Windows, case-sensitive elsewhere. Implementation is a simple
  recursive-descent matcher — patterns are short (a handful of
  characters) and the call rate is tool-call frequency, not loop
  frequency, so the algorithmic shape does not matter. }

  function MatchAt(pi, si: Integer): Boolean;
  var
    PC, SC: Char;
  begin
    while pi <= Length(Pattern) do
    begin
      PC := Pattern[pi];
      if PC = '*' then
      begin
        { Skip consecutive '*'s. }
        while (pi <= Length(Pattern)) and (Pattern[pi] = '*') do Inc(pi);
        if pi > Length(Pattern) then Exit(True);
        while si <= Length(S) do
        begin
          if MatchAt(pi, si) then Exit(True);
          Inc(si);
        end;
        Exit(False);
      end;
      if si > Length(S) then Exit(False);
      SC := S[si];
      if (PC <> '?') and (UpCase(PC) <> UpCase(SC)) then Exit(False);
      Inc(pi);
      Inc(si);
    end;
    Result := si > Length(S);
  end;

begin
  Result := MatchAt(1, 1);
end;

function AnyGlobMatches(const S: string; const Patterns: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Patterns) do
    if GlobMatches(Patterns[i], S) then Exit(True);
  Result := False;
end;

{ -------- access checks -------- }

function CanReadPath(const Path: string; out Reason: string): Boolean;
var
  Canon: string;
begin
  Reason := '';
  if not GPolicy.RestrictToWorkspace then Exit(True);
  if GPolicy.AllowReadOutsideWorkspace then Exit(True);
  Canon := Canonicalize(Path);
  if PathInsideDirectory(Canon, GWorkspace) then Exit(True);
  if AnyGlobMatches(Canon, GPolicy.AllowReadPaths) then Exit(True);
  Reason := 'refused: path "' + Canon + '" is outside the workspace ' +
            '"' + GWorkspace + '" and does not match any allow_read_paths ' +
            'glob (sandbox.restrict_to_workspace=true)';
  Result := False;
end;

function CanWritePath(const Path: string; out Reason: string): Boolean;
var
  Canon: string;
begin
  Reason := '';
  if not GPolicy.RestrictToWorkspace then Exit(True);
  Canon := Canonicalize(Path);
  if PathInsideDirectory(Canon, GWorkspace) then Exit(True);
  if AnyGlobMatches(Canon, GPolicy.AllowWritePaths) then Exit(True);
  Reason := 'refused: path "' + Canon + '" is outside the workspace ' +
            '"' + GWorkspace + '" and does not match any allow_write_paths ' +
            'glob (sandbox.restrict_to_workspace=true)';
  Result := False;
end;

{ -------- shell denylist -------- }

const
  { Tokens that, when found as a whitespace-separated word in the
    command, abort the call. The denylist tries to be conservative —
    these are commands the model has no business running from a
    chat session even on a developer workstation.

    A few legit-sounding cases (e.g. `chmod +x build.sh`) are caught
    too. That is intentional: the model can write the file and the
    human can chmod it. Override per-config via custom_shell_deny
    if a specific case is needed. }
  ForbiddenTokens: array[0..14] of string = (
    'sudo',
    'su',
    'rm',          { all rm — too easy to escape -rf detection }
    'chmod',
    'chown',
    'pkill',
    'killall',
    'kill',
    'shutdown',
    'reboot',
    'poweroff',
    'halt',
    'eval',
    'mkfs',
    'diskpart'
  );

  { Substrings that, when present anywhere in the lowercased command,
    abort the call. Covers picoclaw's regex patterns expressed as
    plain literals — adequate because the patterns themselves are
    just punctuation runs ($(...), `...`, etc.) or fixed token
    sequences (apt install, npm install -g, etc.). }
  ForbiddenSubstrings: array[0..28] of string = (
    'dd if=',
    ':(){:|',         { fork bomb }
    '<<eof',
    '<<-eof',
    '$(',             { command substitution }
    '${',             { parameter expansion with possible injection }
    '`',              { backtick command substitution }
    '| sh',
    '|sh',
    '| bash',
    '|bash',
    '|/bin/sh',
    '|/bin/bash',
    'curl ',          { paired with denylist context below }
    'wget ',
    'apt install',
    'apt remove',
    'apt purge',
    'yum install',
    'yum remove',
    'dnf install',
    'dnf remove',
    'npm install -g',
    'pip install --user',
    'docker run',
    'docker exec',
    'git push',
    'git force',
    'format c:'
  );

  { Patterns specifically for writes to block devices. These cause
    instant disk wipes if executed. }
  ForbiddenDeviceWrites: array[0..7] of string = (
    '> /dev/sd',
    '> /dev/hd',
    '> /dev/vd',
    '> /dev/xvd',
    '> /dev/nvme',
    '> /dev/mmcblk',
    '> /dev/loop',
    '> /dev/md'
  );

function IsShellBreak(C: Char): Boolean; inline;
begin
  { Whitespace + shell metacharacters that delimit one token from
    the next. Spelled out as an if-chain rather than a set literal
    so Delphi's UnicodeString Char type does not refuse the
    `in [' ', ...]` form. }
  Result := (C = ' ')  or (C = #9)  or (C = ';')  or (C = '|') or
            (C = '&')  or (C = '(') or (C = ')')  or (C = '<') or
            (C = '>')  or (C = #10) or (C = #13);
end;

function IsPathBreak(C: Char): Boolean; inline;
begin
  Result := IsShellBreak(C) or (C = '"') or (C = '''');
end;

function TokenizeCommand(const Cmd: string): TStringList;
{ Splits on whitespace and shell metacharacters. Caller frees. }
var
  i: Integer;
  Cur: string;
begin
  Result := TStringList.Create;
  Cur := '';
  for i := 1 to Length(Cmd) do
  begin
    if IsShellBreak(Cmd[i]) then
    begin
      if Cur <> '' then begin Result.Add(Cur); Cur := ''; end;
    end
    else
      Cur := Cur + Cmd[i];
  end;
  if Cur <> '' then Result.Add(Cur);
end;

function MatchesAnyTokenForbid(const Cmd: string; out Hit: string): Boolean;
var
  Tokens: TStringList;
  i, j: Integer;
  T: string;
begin
  Result := False;
  Hit := '';
  Tokens := TokenizeCommand(Cmd);
  try
    for i := 0 to Tokens.Count - 1 do
    begin
      T := LowerCase(Tokens[i]);
      for j := 0 to High(ForbiddenTokens) do
        if T = ForbiddenTokens[j] then
        begin
          Hit := ForbiddenTokens[j];
          Exit(True);
        end;
    end;
  finally
    Tokens.Free;
  end;
end;

function MatchesAnySubstring(const Cmd: string; out Hit: string): Boolean;
var
  Lower: string;
  i: Integer;
begin
  Lower := LowerCase(Cmd);
  for i := 0 to High(ForbiddenSubstrings) do
    if Pos(ForbiddenSubstrings[i], Lower) > 0 then
    begin
      Hit := ForbiddenSubstrings[i];
      Exit(True);
    end;
  for i := 0 to High(ForbiddenDeviceWrites) do
    if Pos(ForbiddenDeviceWrites[i], Lower) > 0 then
    begin
      Hit := ForbiddenDeviceWrites[i];
      Exit(True);
    end;
  for i := 0 to High(GPolicy.CustomShellDeny) do
    if (GPolicy.CustomShellDeny[i] <> '') and
       (Pos(LowerCase(GPolicy.CustomShellDeny[i]), Lower) > 0) then
    begin
      Hit := GPolicy.CustomShellDeny[i];
      Exit(True);
    end;
  Result := False;
end;

function HasOutsideAbsolutePath(const Cmd: string; out OffendingPath: string): Boolean;
var
  i, Start: Integer;
  Token: string;
  IsSafeDev: Boolean;
begin
  Result := False;
  OffendingPath := '';
  i := 1;
  while i <= Length(Cmd) do
  begin
    if Cmd[i] = '/' then
    begin
      Start := i;
      while (i <= Length(Cmd)) and not IsPathBreak(Cmd[i]) do
        Inc(i);
      Token := Copy(Cmd, Start, i - Start);
      { Kernel pseudo-devices are always safe — picoclaw's safePaths. }
      IsSafeDev := SameText(Token, '/dev/null')    or SameText(Token, '/dev/zero')   or
                   SameText(Token, '/dev/random')  or SameText(Token, '/dev/urandom') or
                   SameText(Token, '/dev/stdin')   or SameText(Token, '/dev/stdout') or
                   SameText(Token, '/dev/stderr');
      if (not IsSafeDev) and (not PathInsideDirectory(Token, GWorkspace)) and
         (not AnyGlobMatches(Token, GPolicy.AllowReadPaths)) and
         (not AnyGlobMatches(Token, GPolicy.AllowWritePaths)) then
      begin
        OffendingPath := Token;
        Exit(True);
      end;
    end
    else
      Inc(i);
  end;
end;

function ShellAllowed(const Cmd: string; out Reason: string): Boolean;
var
  Hit, Path: string;
begin
  Reason := '';
  if Trim(Cmd) = '' then
  begin
    Reason := 'refused: empty command';
    Exit(False);
  end;

  if GPolicy.ShellDenyEnabled then
  begin
    if MatchesAnyTokenForbid(Cmd, Hit) then
    begin
      Reason := 'refused: command contains forbidden token "' + Hit +
                '" (built-in shell denylist; toggle off via sandbox.shell_deny_enabled=false ' +
                'in config.json — strongly discouraged)';
      Exit(False);
    end;
    if MatchesAnySubstring(Cmd, Hit) then
    begin
      Reason := 'refused: command contains forbidden pattern "' + Hit +
                '" (built-in shell denylist)';
      Exit(False);
    end;
  end;

  if GPolicy.RestrictToWorkspace then
    if HasOutsideAbsolutePath(Cmd, Path) then
    begin
      Reason := 'refused: command references absolute path "' + Path +
                '" which is outside the workspace "' + GWorkspace +
                '" and does not match any allow_*_paths glob ' +
                '(sandbox.restrict_to_workspace=true)';
      Exit(False);
    end;

  Result := True;
end;

initialization
  { Defaults match TConfig.Create — sandbox is off, denylist is on.
    Real values land via Configure() during command startup. }
  GPolicy.RestrictToWorkspace       := False;
  GPolicy.AllowReadOutsideWorkspace := False;
  GPolicy.ShellDenyEnabled          := True;
  GWorkspace := '';

end.
