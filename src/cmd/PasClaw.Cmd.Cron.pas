{ Cron — list/add/disable/enable/remove scheduled tasks. Real scheduler in Phase 5. }
unit PasClaw.Cmd.Cron;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Cron_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI;

procedure Help;
begin
  WriteLn('Usage: pasclaw cron <list|add|disable|enable|remove> [args]');
  WriteLn('  add <id> "<spec>" <skill> [args]   register a cron task');
  WriteLn('  disable|enable <id>                toggle a task');
  WriteLn('  remove <id>                        delete a task');
end;

function DoList: Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  Cfg := LoadConfig;
  try
    if Length(Cfg.Crons) = 0 then
    begin
      WriteLn('(no cron entries)');
      Exit(0);
    end;
    WriteLn(Ansi.Bold, 'id', Ansi.Reset, '              spec              skill         enabled');
    for i := 0 to High(Cfg.Crons) do
      WriteLn(Cfg.Crons[i].Id:14, '  ',
              Cfg.Crons[i].Spec:14, '  ',
              Cfg.Crons[i].Skill:12, '  ',
              BoolToStr(Cfg.Crons[i].Enabled, True));
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAdd(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  n, i: Integer;
  Args: string;
begin
  if Length(Argv) < 4 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Args := '';
    for i := 4 to High(Argv) do
    begin
      if Args <> '' then Args := Args + ' ';
      Args := Args + Argv[i];
    end;
    n := Length(Cfg.Crons);
    SetLength(Cfg.Crons, n + 1);
    Cfg.Crons[n].Id      := Argv[1];
    Cfg.Crons[n].Spec    := Argv[2];
    Cfg.Crons[n].Skill   := Argv[3];
    Cfg.Crons[n].Args    := Args;
    Cfg.Crons[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'added cron ', Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoToggle(const Argv: array of string; Enable: Boolean): Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.Crons) do
      if SameText(Cfg.Crons[i].Id, Argv[1]) then
        Cfg.Crons[i].Enabled := Enable;
    SaveConfig(Cfg);
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
    for i := 0 to High(Cfg.Crons) do
      if not SameText(Cfg.Crons[i].Id, Argv[1]) then
      begin
        Cfg.Crons[dst] := Cfg.Crons[i];
        Inc(dst);
      end;
    SetLength(Cfg.Crons, dst);
    SaveConfig(Cfg);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_Cron_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'add'     then Result := DoAdd(Argv)
  else if Sub = 'disable' then Result := DoToggle(Argv, False)
  else if Sub = 'enable'  then Result := DoToggle(Argv, True)
  else if Sub = 'remove'  then Result := DoRemove(Argv)
  else begin Help; Result := 1; end;
end;

end.
