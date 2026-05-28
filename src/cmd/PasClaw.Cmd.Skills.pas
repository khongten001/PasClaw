{ Skills — list/install skill extensions (manifest-only for Phase 1). }
unit PasClaw.Cmd.Skills;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Skills_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI, PasClaw.Utils,
  PasClaw.Skills.Loader;

procedure Help;
begin
  WriteLn('Usage: pasclaw skills <list|install|remove> [name|path]');
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

function DoInstall(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  n: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    n := Length(Cfg.Skills);
    SetLength(Cfg.Skills, n + 1);
    Cfg.Skills[n].Name    := Argv[1];
    Cfg.Skills[n].Source  := Argv[1];
    Cfg.Skills[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'installed ', Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
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
    Result := 0;
  finally
    Cfg.Free;
  end;
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
