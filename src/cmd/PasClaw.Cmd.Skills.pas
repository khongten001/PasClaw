{ Skills — list / install / remove skill extensions.

  install accepts three target shapes:

    pasclaw skills install owner/repo[/sub/path][@ref]
        Fetch a SKILL.md tree from GitHub (zip via codeload, extract
        with PasClaw.Skills.Zip). Default ref tries main then master.

    pasclaw skills install ./local/path
        Copy a local directory (containing SKILL.md at the root) into
        the workspace. Phase 2 target — defers to a follow-up. Right
        now the install command refuses local paths with a clear
        error message; "drop the directory under workspace/skills/
        yourself" is the manual fallback.

    pasclaw skills install <name>
        Legacy form. Records the name in config.json without
        downloading anything. Kept for backwards compat with the
        existing Cfg.Skills array used by older workflows. }
unit PasClaw.Cmd.Skills;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Skills_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI, PasClaw.Utils, PasClaw.Logger,
  PasClaw.Skills.Loader,
  PasClaw.Skills.GitHub;

procedure Help;
begin
  WriteLn('Usage: pasclaw skills <list|install|remove> [target]');
  WriteLn;
  WriteLn('  list                                List installed skills.');
  WriteLn('  install owner/repo[/path][@ref]     Install a SKILL.md from GitHub.');
  WriteLn('  install <name>                      Record a name in config.json.');
  WriteLn('  remove <name>                       Remove from config.json + workspace.');
end;

function IsGitHubTarget(const Target: string): Boolean;
{ Cheapest sniff: a slash that is not at position 1 (so not a local
  absolute path starting with /), no leading dot (so not ./relative
  or ../relative), and not starting with a Windows drive letter.
  Anything else falls through to the legacy config-only install. }
var
  i: Integer;
begin
  Result := False;
  if Target = '' then Exit;
  if (Target[1] = '/') or (Target[1] = '\') or (Target[1] = '.') then Exit;
  if (Length(Target) >= 2) and (Target[2] = ':') then Exit; { drive letter }
  for i := 1 to Length(Target) do
    if Target[i] = '/' then Exit(True);
end;

function DoList: Integer;
var
  Specs: TSkillSpecArray;
  i: Integer;
  K, Src: string;
begin
  Specs := LoadSkillManifests(GetHome);
  if Length(Specs) = 0 then
  begin
    WriteLn('(no skills found at ', JoinPath(GetHome, 'workspace/skills'), ')');
    WriteLn('Add one: mkdir -p ~/.pasclaw/workspace/skills/<name>; place a SKILL.md inside.');
    Exit(0);
  end;
  WriteLn(Ansi.Bold, 'name', Ansi.Reset, '              kind        source');
  for i := 0 to High(Specs) do
  begin
    K := Specs[i].Kind;
    if K = '' then K := 'knowledge';
    { Show relative path under ~/.pasclaw so the line stays readable. }
    Src := Specs[i].Source;
    if Pos(GetHome, Src) = 1 then
      Src := '~' + Copy(Src, Length(GetHome) + 1, MaxInt);
    WriteLn(Specs[i].Name:18, '  ', K:9, '  ', Src);
    if Specs[i].Description <> '' then
      WriteLn('                    ', Ansi.Dim, Specs[i].Description, Ansi.Reset);
  end;
  Result := 0;
end;

function DoInstallGitHub(const Target: string): Integer;
var
  DestRoot, Installed, ErrMsg: string;
begin
  DestRoot := JoinPath(GetHome, 'workspace/skills');
  WriteLn('Fetching ', Target, ' …');
  if not InstallFromGitHub(Target, DestRoot, Installed, ErrMsg) then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'install failed: ', ErrMsg);
    Exit(1);
  end;
  WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'installed as ',
          JoinPath(DestRoot, Installed));
  WriteLn('  Run ', Ansi.Bold, 'pasclaw skills list', Ansi.Reset,
          ' to confirm; next ', Ansi.Bold, 'pasclaw agent', Ansi.Reset,
          ' invocation will pick it up.');
  Result := 0;
end;

function DoInstallLegacy(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  n: Integer;
begin
  Cfg := LoadConfig;
  try
    n := Length(Cfg.Skills);
    SetLength(Cfg.Skills, n + 1);
    Cfg.Skills[n].Name    := Argv[1];
    Cfg.Skills[n].Source  := Argv[1];
    Cfg.Skills[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'recorded ', Argv[1], ' in config.json');
    WriteLn(Ansi.Dim, '  (no files downloaded — for a GitHub install use ',
            'owner/repo syntax)', Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoInstall(const Argv: array of string): Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  if IsGitHubTarget(Argv[1]) then
    Result := DoInstallGitHub(Argv[1])
  else
    Result := DoInstallLegacy(Argv);
end;

procedure RemoveSkillDir(const Dir: string);
{ Recursive delete used by `skills remove`. Best-effort: failures get
  logged but do not block the config-side removal. }

  procedure Walk(const D: string);
  var
    SR: TSearchRec;
    Path: string;
  begin
    if FindFirst(JoinPath(D, '*'), faAnyFile, SR) <> 0 then Exit;
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Path := JoinPath(D, SR.Name);
        if (SR.Attr and faDirectory) <> 0 then Walk(Path)
        else try DeleteFile(Path); except end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    try RemoveDir(D); except end;
  end;

begin
  if DirectoryExists(Dir) then Walk(Dir);
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
  WorkspaceDir, LegacyJSON: string;
  RemovedFiles: Boolean;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  RemovedFiles := False;

  WorkspaceDir := JoinPath(GetHome, 'workspace/skills');
  LegacyJSON   := JoinPath(WorkspaceDir, Argv[1] + '.json');
  if FileExists(LegacyJSON) then
  begin
    if DeleteFile(LegacyJSON) then RemovedFiles := True
    else LogWarn('skills: could not delete %s', [LegacyJSON]);
  end;
  if DirectoryExists(JoinPath(WorkspaceDir, Argv[1])) then
  begin
    RemoveSkillDir(JoinPath(WorkspaceDir, Argv[1]));
    RemovedFiles := True;
  end;

  Cfg := LoadConfig;
  try
    dst := 0;
    for i := 0 to High(Cfg.Skills) do
      if not SameText(Cfg.Skills[i].Name, Argv[1]) then
      begin
        Cfg.Skills[dst] := Cfg.Skills[i];
        Inc(dst);
      end;
    SetLength(Cfg.Skills, dst);
    SaveConfig(Cfg);
  finally
    Cfg.Free;
  end;
  if RemovedFiles then
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'removed ', Argv[1])
  else
    WriteLn(Ansi.Yellow, '(', Argv[1],
            ' was not found on disk; config entry cleared if present)',
            Ansi.Reset);
  Result := 0;
end;

function Cmd_Skills_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'install' then Result := DoInstall(Argv)
  else if Sub = 'remove'  then Result := DoRemove(Argv)
  else begin Help; Result := 1; end;
end;

end.
