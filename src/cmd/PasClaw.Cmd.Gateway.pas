(*
  Gateway - starts the HTTP gateway, and optionally the Telegram channel
  alongside it. Blocks until SIGINT / Ctrl-C, then shuts down cleanly.

    pasclaw gateway                                 # just the HTTP API
    pasclaw gateway --telegram --token <BOT_TOKEN>  # API + Telegram bot
    pasclaw gateway --addr 0.0.0.0 --port 8088      # listen on all ifaces

  The HTTP API is documented in src/pkg/gateway/PasClaw.Gateway.Server.pas.
*)
unit PasClaw.Cmd.Gateway;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Gateway_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config, PasClaw.CliUI, PasClaw.Logger,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Cron.Scheduler,
  PasClaw.Gateway.Server,
  PasClaw.Channels.Telegram;

type
  TGwArgs = record
    Addr:      string;
    Port:      Integer;
    Telegram:  Boolean;
    Token:     string;
    NoMCP:     Boolean;
    NoTools:   Boolean;
  end;

function ParseGw(const Argv: array of string; const Cfg: TConfig): TGwArgs;
var
  i: Integer;
begin
  Result.Addr     := Cfg.Gateway.BindAddr;
  Result.Port     := Cfg.Gateway.Port;
  Result.Telegram := False;
  Result.Token    := GetEnvironmentVariable('PASCLAW_TELEGRAM_TOKEN');
  Result.NoMCP    := False;
  Result.NoTools  := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--addr'     then begin if i < High(Argv) then Result.Addr     := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--port'     then begin if i < High(Argv) then Result.Port     := StrToIntDef(Argv[i + 1], Result.Port); Inc(i, 2); Continue; end;
    if Argv[i] = '--telegram' then begin Result.Telegram := True; Inc(i); Continue; end;
    if Argv[i] = '--token'    then begin if i < High(Argv) then Result.Token    := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--no-mcp'   then begin Result.NoMCP    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-tools' then begin Result.NoTools  := True; Inc(i); Continue; end;
    Inc(i);
  end;
end;

function Cmd_Gateway_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: TGwArgs;
  Provider: ILLMProvider;
  Err: string;
  Reg: TToolRegistry;
  MCPClients: TMCPClientList;
  Server: TGatewayServer;
  Telegram: TTelegramChannel;
  Scheduler: TCronScheduler;
  Skills: TSkillSpecArray;
begin
  Cfg := LoadConfig;
  try
    Args := ParseGw(Argv, Cfg);

    Provider := nil;
    if Cfg.DefaultProvider <> '' then
      if not NewDefaultProvider(Cfg, Provider, Err) then
        LogWarn('gateway: no provider — /v1/chat will return 503 (%s)', [Err]);

    Reg := nil;
    if not Args.NoTools then
    begin
      Reg := TToolRegistry.Create;
      RegisterFSTools(Reg);
      RegisterShellTool(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
      if Length(Skills) > 0 then
        LogInfo('gateway: loaded %d skill(s) from workspace/skills/', [Length(Skills)]);
    end;

    SetLength(MCPClients, 0);
    if (not Args.NoMCP) and (Reg <> nil) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    Scheduler := nil;
    if (Reg <> nil) and (Length(Cfg.Crons) > 0) then
    begin
      Scheduler := TCronScheduler.Create(Cfg, Reg);
      Scheduler.Start;
    end;

    Server := TGatewayServer.Create(Cfg, Provider, Reg);
    Telegram := nil;
    try
      Server.Start(Args.Addr, Args.Port);

      WriteLn(Ansi.Bold, 'Gateway up.', Ansi.Reset);
      WriteLn('  http://', Args.Addr, ':', Args.Port, '/v1/health');
      WriteLn('  http://', Args.Addr, ':', Args.Port, '/v1/tools');
      WriteLn('  POST http://', Args.Addr, ':', Args.Port, '/v1/chat   {"message":"..."}');
      WriteLn(Ansi.Dim, 'Press Ctrl-C to stop.', Ansi.Reset);

      if Args.Telegram then
      begin
        if Args.Token = '' then
        begin
          LogError('telegram: no token; set PASCLAW_TELEGRAM_TOKEN or pass --token');
          Exit(1);
        end;
        Telegram := TTelegramChannel.Create(Args.Token, Cfg, Provider, Reg);
        { Long-poll runs on the current thread and blocks; for Phase 5 we
          accept that the HTTP listener and Telegram coexist (Indy listens on
          its own threads), so we just call Telegram.Run last. }
        Telegram.Run;
      end
      else
        Server.WaitForStop;
    finally
      if Telegram <> nil then Telegram.Free;
      Server.Stop;
      Server.Free;
      if Scheduler <> nil then Scheduler.Free;
      FreeMCPClients(MCPClients);
      if Reg <> nil then Reg.Free;
    end;

    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
