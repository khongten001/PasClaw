(*
  Gateway - starts the HTTP gateway, and optionally the Telegram channel
  alongside it. Blocks until SIGINT / Ctrl-C, then shuts down cleanly.

    pasclaw gateway                                 # just the HTTP API
    pasclaw gateway --telegram --token <BOT_TOKEN>  # API + Telegram bot
    pasclaw gateway --addr 0.0.0.0 --port 8088      # listen on all ifaces

  The HTTP API is documented in src/pkg/gateway/PasClaw.Gateway.Server.pas.
*)
unit PasClaw.Cmd.Gateway;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
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
  PasClaw.Tools.Memory,
  PasClaw.Tools.Sandbox,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Cron.Scheduler,
  PasClaw.Gateway.Server,
  PasClaw.Channels.Telegram,
  PasClaw.Channels.LINE,
  PasClaw.Channels.WhatsApp;

type
  TGwArgs = record
    Addr:        string;
    Port:        Integer;
    Telegram:    Boolean;
    Token:       string;
    Line:        Boolean;
    LineToken:   string;
    LineSecret:  string;
    WhatsApp:    Boolean;
    WAToken:     string;
    WAPhoneId:   string;
    WAVerify:    string;
    WASecret:    string;
    NoMCP:       Boolean;
    NoTools:     Boolean;
    NoHashline:  Boolean;
  end;

function ParseGw(const Argv: array of string; const Cfg: TConfig): TGwArgs;
var
  i: Integer;
begin
  Result.Addr       := Cfg.Gateway.BindAddr;
  Result.Port       := Cfg.Gateway.Port;
  Result.Telegram   := False;
  Result.Token      := GetEnvironmentVariable('PASCLAW_TELEGRAM_TOKEN');
  Result.Line       := False;
  Result.LineToken  := GetEnvironmentVariable('PASCLAW_LINE_TOKEN');
  Result.LineSecret := GetEnvironmentVariable('PASCLAW_LINE_SECRET');
  Result.WhatsApp   := False;
  Result.WAToken    := GetEnvironmentVariable('PASCLAW_WHATSAPP_TOKEN');
  Result.WAPhoneId  := GetEnvironmentVariable('PASCLAW_WHATSAPP_PHONE_ID');
  Result.WAVerify   := GetEnvironmentVariable('PASCLAW_WHATSAPP_VERIFY_TOKEN');
  Result.WASecret   := GetEnvironmentVariable('PASCLAW_WHATSAPP_APP_SECRET');
  Result.NoMCP      := False;
  Result.NoTools    := False;
  Result.NoHashline := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--addr'         then begin if i < High(Argv) then Result.Addr     := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--port'         then begin if i < High(Argv) then Result.Port     := StrToIntDef(Argv[i + 1], Result.Port); Inc(i, 2); Continue; end;
    if Argv[i] = '--telegram'     then begin Result.Telegram   := True; Inc(i); Continue; end;
    if Argv[i] = '--token'        then begin if i < High(Argv) then Result.Token    := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--line'         then begin Result.Line       := True; Inc(i); Continue; end;
    if Argv[i] = '--line-token'   then begin if i < High(Argv) then Result.LineToken  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--line-secret'  then begin if i < High(Argv) then Result.LineSecret := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp'         then begin Result.WhatsApp  := True; Inc(i); Continue; end;
    if Argv[i] = '--whatsapp-token'   then begin if i < High(Argv) then Result.WAToken   := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp-phone'   then begin if i < High(Argv) then Result.WAPhoneId := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp-verify'  then begin if i < High(Argv) then Result.WAVerify  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp-secret'  then begin if i < High(Argv) then Result.WASecret  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--no-mcp'       then begin Result.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-tools'     then begin Result.NoTools    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-hashline'  then begin Result.NoHashline := True; Inc(i); Continue; end;
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
  Line: TLineBot;
  WhatsApp: TWhatsAppBot;
  Scheduler: TCronScheduler;
  Skills: TSkillSpecArray;
begin
  Cfg := LoadConfig;
  ConfigureSandbox(Cfg.Sandbox, '');
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
      RegisterFSTools(Reg, not Args.NoHashline);
      RegisterShellTool(Reg);
      RegisterMemoryTools(Reg);
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
    Line     := nil;
    WhatsApp := nil;
    try
      if Args.Line then
      begin
        if (Args.LineToken = '') or (Args.LineSecret = '') then
        begin
          LogError('line: need both --line-token / $PASCLAW_LINE_TOKEN and ' +
                   '--line-secret / $PASCLAW_LINE_SECRET');
          Exit(1);
        end;
        Line := TLineBot.Create(Args.LineToken, Args.LineSecret,
                                Cfg, Provider, Reg);
        Server.MountWebhook('/webhooks/line', Line.HandleWebhook);
      end;

      if Args.WhatsApp then
      begin
        if (Args.WAToken = '') or (Args.WAPhoneId = '') or
           (Args.WAVerify = '') or (Args.WASecret = '') then
        begin
          LogError('whatsapp: need all four — --whatsapp-token / ' +
                   '$PASCLAW_WHATSAPP_TOKEN, --whatsapp-phone / ' +
                   '$PASCLAW_WHATSAPP_PHONE_ID, --whatsapp-verify / ' +
                   '$PASCLAW_WHATSAPP_VERIFY_TOKEN, --whatsapp-secret / ' +
                   '$PASCLAW_WHATSAPP_APP_SECRET');
          Exit(1);
        end;
        WhatsApp := TWhatsAppBot.Create(Args.WAToken, Args.WAPhoneId,
                                         Args.WAVerify, Args.WASecret,
                                         Cfg, Provider, Reg);
        Server.MountWebhook('/webhooks/whatsapp', WhatsApp.HandleWebhook);
      end;

      Server.Start(Args.Addr, Args.Port);

      WriteLn(Ansi.Bold, 'Gateway up.', Ansi.Reset);
      WriteLn('  http://', Args.Addr, ':', Args.Port, '/v1/health');
      WriteLn('  http://', Args.Addr, ':', Args.Port, '/v1/tools');
      WriteLn('  POST http://', Args.Addr, ':', Args.Port, '/v1/chat   {"message":"..."}');
      if Args.Line then
        WriteLn('  POST http://', Args.Addr, ':', Args.Port, '/webhooks/line   (LINE platform)');
      if Args.WhatsApp then
        WriteLn('  ANY http://', Args.Addr, ':', Args.Port, '/webhooks/whatsapp   (WhatsApp Cloud)');
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
      if Line     <> nil then Line.Free;
      if WhatsApp <> nil then WhatsApp.Free;
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
