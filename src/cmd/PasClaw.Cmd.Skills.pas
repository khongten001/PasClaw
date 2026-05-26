{ Skills — list/install skill extensions (manifest-only for Phase 1). }
unit PasClaw.Cmd.Skills;
{$MODE DELPHI}
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
begin
  Specs := LoadSkillManifests(GetHome);
  if Length(Specs) = 0 then
  begin
    WriteLn('(no skills found at ', JoinPath(GetHome, 'workspace/skills'), ')');
    Exit(0);
  end;
  WriteLn(Ansi.Bold, 'name', Ansi.Reset, '              kind   description');
  for i := 0 to High(Specs) do
    WriteLn(Specs[i].Name:18, '  ', Specs[i].Kind:6, '  ', Specs[i].Description);
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
