{ Status — print effective config, home dir, key health checks. }
unit PasClaw.Cmd.Status;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Status_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI;

function YesNo(b: Boolean): string;
begin
  if b then Result := Ansi.Green + 'yes' + Ansi.Reset
       else Result := Ansi.Red   + 'no'  + Ansi.Reset;
end;

function Cmd_Status_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  HomeOk, CfgOk: Boolean;
begin
  HomeOk := DirectoryExists(GetHome);
  CfgOk  := FileExists(GetConfigPath);
  Cfg    := LoadConfig;
  try
    WriteLn(Ansi.Bold, 'PasClaw status', Ansi.Reset);
    WriteLn('  home directory : ', GetHome, '   present: ', YesNo(HomeOk));
    WriteLn('  config file    : ', GetConfigPath, '   present: ', YesNo(CfgOk));
    WriteLn('  default provider: ', Cfg.DefaultProvider);
    WriteLn('  default model   : ', Cfg.DefaultModel);
    WriteLn('  providers       : ', Length(Cfg.Providers));
    WriteLn('  mcp servers     : ', Length(Cfg.MCPServers));
    WriteLn('  cron entries    : ', Length(Cfg.Crons));
    WriteLn('  skills          : ', Length(Cfg.Skills));
    WriteLn('  gateway bind    : ', Cfg.Gateway.BindAddr, ':', Cfg.Gateway.Port);
    WriteLn('  log level       : ', Cfg.Gateway.LogLevel);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
