{ Skills — list / install / remove / search skill extensions.

  install accepts three target shapes (in this dispatch order):

    pasclaw skills install owner/repo[/sub/path][@ref]
        Fetch a SKILL.md tree from GitHub (zip via codeload, extract
        with PasClaw.Skills.Zip). Default ref tries main then master.

    pasclaw skills install clawhub:<slug>[@<version>]
        Resolve <slug> on ClawHub (https://clawhub.ai). Picoclaw and
        nanobot's default registry — slug syntax is lowercase
        alphanumerics, '-', and '_'. `@<version>` pins; omitting it
        uses the slug's latestVersion if metadata is available,
        otherwise 'latest'. The explicit `clawhub:` prefix is
        required so a slug-shaped bare name like `my-skill` does
        not silently swap places with a same-named registry entry
        — see the docstring on IsClawHubTarget for the backwards
        compat rationale.

    pasclaw skills search <query>
        Hit ClawHub's /api/v1/search and print result rows. No
        install side effects.

  Legacy `pasclaw skills install <name>` (anything not matching the
  two forms above) still records the name in config.json without
  downloading anything. Kept for backwards compat with older
  workflows that drove Cfg.Skills directly. }
unit PasClaw.Cmd.Skills;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Skills_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI, PasClaw.Utils, PasClaw.Logger,
  PasClaw.Skills.Loader,
  PasClaw.Skills.GitHub,
  PasClaw.Skills.ClawHub;

procedure Help;
begin
  WriteLn('Usage: pasclaw skills <list|install|remove|search> [args]');
  WriteLn;
  WriteLn('  list                                List installed skills.');
  WriteLn('  install owner/repo[/path][@ref]     Install a SKILL.md from GitHub.');
  WriteLn('  install clawhub:<slug>[@<version>]  Install from ClawHub (https://clawhub.ai).');
  WriteLn('  install <name>                      Legacy: record a name in config.json.');
  WriteLn('  remove <name>                       Remove from config.json + workspace.');
  WriteLn('  search <query>                      Search ClawHub for skills.');
end;

function IsGitHubTarget(const Target: string): Boolean;
{ Cheapest sniff: a slash that is not at position 1 (so not a local
  absolute path starting with /), no leading dot (so not ./relative
  or ../relative), and not starting with a Windows drive letter.
  Anything else falls through to the ClawHub / legacy paths. }
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

const
  ClawHubPrefix = 'clawhub:';

function IsClawHubTarget(const Target: string; out Slug: string): Boolean;
{ ClawHub installs require an explicit `clawhub:<slug>[@version]`
  prefix. Bare slug-shaped names ('my-skill', 'code-review' etc.)
  stay on the legacy config-only path so pre-existing scripts that
  used `pasclaw skills install <name>` to record an entry in
  config.json keep working — they'd otherwise either 404 on
  ClawHub or, worse, silently install an unrelated registry skill
  that happened to share the slug.

  Validates the slug after stripping the prefix so e.g.
  `clawhub:Foo` (mixed case) fails fast here rather than 404'ing
  on the server. Optional `@<version>` suffix permitted. }
var
  i, AtPos: Integer;
  Rest: string;
  C: Char;
begin
  Result := False;
  Slug := '';
  if Length(Target) <= Length(ClawHubPrefix) then Exit;
  if Copy(Target, 1, Length(ClawHubPrefix)) <> ClawHubPrefix then Exit;
  Rest := Copy(Target, Length(ClawHubPrefix) + 1, MaxInt);
  if (Rest = '') or (Length(Rest) > 128) then Exit;
  AtPos := Pos('@', Rest);
  if AtPos > 0 then Slug := Copy(Rest, 1, AtPos - 1)
              else Slug := Rest;
  if Slug = '' then Exit;
  for i := 1 to Length(Slug) do
  begin
    C := Slug[i];
    if not ( ((C >= 'a') and (C <= 'z')) or
             ((C >= '0') and (C <= '9')) or
             (C = '-') or (C = '_') ) then Exit;
  end;
  Slug := Rest;   { hand the full "<slug>[@version]" back to caller }
  Result := True;
end;

procedure SplitSlugAtVersion(const Target: string; out Slug, Version: string);
var
  AtPos: Integer;
begin
  AtPos := Pos('@', Target);
  if AtPos > 0 then
  begin
    Slug    := Copy(Target, 1, AtPos - 1);
    Version := Copy(Target, AtPos + 1, MaxInt);
  end
  else
  begin
    Slug    := Target;
    Version := '';
  end;
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

function DoInstallClawHub(const Target: string): Integer;
var
  Slug, Version, DestRoot, Installed, ErrMsg: string;
begin
  SplitSlugAtVersion(Target, Slug, Version);
  DestRoot := JoinPath(GetHome, 'workspace/skills');
  if Version <> '' then
    WriteLn('Fetching clawhub:', Slug, ' @', Version, ' …')
  else
    WriteLn('Fetching clawhub:', Slug, ' …');
  if not InstallFromClawHub(Slug, Version, DestRoot, Installed, ErrMsg) then
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

function DoInstall(const Argv: array of string): Integer;
var
  ClawHubSlug: string;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  { Check the explicit `clawhub:` prefix before the GitHub
    owner/repo sniff so a (theoretical) target like
    `clawhub:owner/repo` routes to the ClawHub validator, which
    rejects the slash and falls through to legacy. With the old
    order GitHub's IsGitHubTarget would have eaten the slash and
    tried to fetch `clawhub:owner/repo`. }
  if IsClawHubTarget(Argv[1], ClawHubSlug) then
    Result := DoInstallClawHub(ClawHubSlug)
  else if IsGitHubTarget(Argv[1]) then
    Result := DoInstallGitHub(Argv[1])
  else
    Result := DoInstallLegacy(Argv);
end;

function DoSearch(const Argv: array of string): Integer;
var
  Query, ErrMsg: string;
  Results: TClawHubResultArray;
  i: Integer;
  Summary: string;
begin
  if Length(Argv) < 2 then
  begin
    WriteLn('Usage: pasclaw skills search <query>');
    Exit(1);
  end;
  Query := Argv[1];
  WriteLn('Searching clawhub: ', Query, ' …');
  if not SearchClawHub(Query, 20, Results, ErrMsg) then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'search failed: ', ErrMsg);
    Exit(1);
  end;
  if Length(Results) = 0 then
  begin
    WriteLn('(no matches)');
    Exit(0);
  end;
  WriteLn(Ansi.Bold, 'slug', Ansi.Reset, '                       version    name');
  for i := 0 to High(Results) do
  begin
    WriteLn(Results[i].Slug:26, '  ', Results[i].Version:9, '  ', Results[i].DisplayName);
    Summary := Trim(Results[i].Summary);
    if Summary <> '' then
      WriteLn('                            ', Ansi.Dim, Summary, Ansi.Reset);
  end;
  WriteLn;
  WriteLn(Ansi.Dim, 'Install with: ', Ansi.Reset,
          Ansi.Bold, 'pasclaw skills install <slug>', Ansi.Reset);
  Result := 0;
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

function IsSafeSkillName(const Name: string): Boolean;
{ Skill names go into JoinPath without canonicalisation, so a path
  with separators or '..' would escape workspace/skills/ and let
  `pasclaw skills remove ../memory` recursively delete an unrelated
  workspace subtree. Only single-segment ASCII-ish names are
  accepted on the remove path. Names that came from
  InstallFromGitHub are derived from URL path segments — none of
  the rejected characters can appear there — so legitimate
  installs always pass. }
var
  i: Integer;
begin
  Result := False;
  if (Name = '') or (Name = '.') or (Name = '..') then Exit;
  for i := 1 to Length(Name) do
    case Name[i] of
      '/', '\', ':', #0..#31: Exit;
    end;
  if Pos('..', Name) > 0 then Exit;
  Result := True;
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
  WorkspaceDir, LegacyJSON: string;
  RemovedFiles: Boolean;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  if not IsSafeSkillName(Argv[1]) then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset,
            'unsafe skill name "', Argv[1], '" — skill names must be a single ',
            'path segment with no /, \, :, or ".." sequence');
    Exit(1);
  end;
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
  else if Sub = 'search'  then Result := DoSearch(Argv)
  else begin Help; Result := 1; end;
end;

end.
