{ Gateway — Phase 4 hosts the HTTP/router stack; Phase 1 prints the planned bind addr. }
unit PasClaw.Cmd.Gateway;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Gateway_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI, PasClaw.Logger;

function Cmd_Gateway_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
begin
  Cfg := LoadConfig;
  try
    LogInfo('gateway: would bind %s:%d (Phase 4 will wire fphttpserver)',
      [Cfg.Gateway.BindAddr, Cfg.Gateway.Port]);
    WriteLn('Gateway scaffold — Phase 4 will start the listener and channel router.');
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
