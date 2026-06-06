{ Model — view or switch the default model. }
unit PasClaw.Cmd.Model;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Model_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI;

procedure Help;
begin
  PrintLn('Usage: pasclaw model [show|set <name>|add <provider> <name>]');
end;

function DoShow: Integer;
var
  Cfg: TConfig;
begin
  Cfg := LoadConfig;
  try
    PrintLn('default provider: ' + Cfg.DefaultProvider);
    PrintLn('default model:    ' + Cfg.DefaultModel);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoSet(const Argv: array of string): Integer;
var
  Cfg: TConfig;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Cfg.DefaultModel := Argv[1];
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'default model = ' + Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAdd(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i: Integer;
  Found: Boolean;
begin
  if Length(Argv) < 3 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Found := False;
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, Argv[1]) then
      begin
        Cfg.Providers[i].Model := Argv[2];
        Found := True;
        Break;
      end;
    if not Found then
    begin
      SetLength(Cfg.Providers, Length(Cfg.Providers) + 1);
      Cfg.Providers[High(Cfg.Providers)].Name  := Argv[1];
      Cfg.Providers[High(Cfg.Providers)].Kind  := Argv[1];
      Cfg.Providers[High(Cfg.Providers)].Model := Argv[2];
    end;
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'registered ' + Argv[1] + '/' + Argv[2]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_Model_Run(const Argv: array of string): Integer;
begin
  if (Length(Argv) = 0) or (Argv[0] = 'show') then Exit(DoShow);
  if Argv[0] = 'set' then Exit(DoSet(Argv));
  if Argv[0] = 'add' then Exit(DoAdd(Argv));
  Help;
  Result := 1;
end;

end.
