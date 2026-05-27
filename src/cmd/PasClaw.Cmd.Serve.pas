(*
  serve - Start the OpenAI-compatible API server.

    pasclaw serve                         # default bind/port from config
    pasclaw serve --addr 0.0.0.0 --port 8088
    pasclaw serve --no-tools              # disable built-in tool registry
    pasclaw serve --no-mcp                # skip MCP server discovery
    pasclaw serve --debug                 # log every request + response body

  Exposes POST /v1/chat/completions on the configured port. Any client
  that speaks the OpenAI Chat Completions API (openai-python, openai-node,
  LangChain, autogen, LlamaIndex, the OpenAI Cookbook examples, etc.) can
  point at this server by setting:

    base_url = http://<addr>:<port>/v1
    api_key  = anything-nonempty       (the server doesn't enforce auth yet)

  Internally this is the same TGatewayServer the `gateway` subcommand
  uses — `serve` just trims the surface to the OpenAI endpoints and
  prints copy-pasteable client config.
*)
unit PasClaw.Cmd.Serve;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Serve_Run(const Argv: array of string): Integer;

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
  PasClaw.Gateway.Server;

type
  TServeArgs = record
    Addr:    string;
    Port:    Integer;
    NoMCP:   Boolean;
    NoTools: Boolean;
    Debug:   Boolean;
  end;

function ParseServe(const Argv: array of string; const Cfg: TConfig): TServeArgs;
var
  i: Integer;
begin
  Result.Addr    := Cfg.Gateway.BindAddr;
  Result.Port    := Cfg.Gateway.Port;
  Result.NoMCP   := False;
  Result.NoTools := False;
  Result.Debug   := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--addr'     then begin if i < High(Argv) then Result.Addr := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--port'     then begin if i < High(Argv) then Result.Port := StrToIntDef(Argv[i + 1], Result.Port); Inc(i, 2); Continue; end;
    if Argv[i] = '--no-mcp'   then begin Result.NoMCP   := True; Inc(i); Continue; end;
    if Argv[i] = '--no-tools' then begin Result.NoTools := True; Inc(i); Continue; end;
    if (Argv[i] = '--debug') or (Argv[i] = '-d') then
                                  begin Result.Debug   := True; Inc(i); Continue; end;
    Inc(i);
  end;
end;

function Cmd_Serve_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: TServeArgs;
  Provider: ILLMProvider;
  Err: string;
  Reg: TToolRegistry;
  MCPClients: TMCPClientList;
  Server: TGatewayServer;
  Skills: TSkillSpecArray;
  BaseURL: string;
begin
  Cfg := LoadConfig;
  try
    Args := ParseServe(Argv, Cfg);

    if Args.Debug then
    begin
      SetLogLevel(llDebug);
      LogDebug('serve: --debug enabled (logging every request + body)');
    end;

    Provider := nil;
    if Cfg.DefaultProvider <> '' then
      if not NewDefaultProvider(Cfg, Provider, Err) then
        LogWarn('serve: no provider — /v1/chat/completions will return 503 (%s)', [Err]);

    Reg := nil;
    if not Args.NoTools then
    begin
      Reg := TToolRegistry.Create;
      RegisterFSTools(Reg);
      RegisterShellTool(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
      if Length(Skills) > 0 then
        LogInfo('serve: loaded %d skill(s) from workspace/skills/', [Length(Skills)]);
    end;

    SetLength(MCPClients, 0);
    if (not Args.NoMCP) and (Reg <> nil) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    Server := TGatewayServer.Create(Cfg, Provider, Reg);
    Server.DebugIO := Args.Debug;
    try
      Server.Start(Args.Addr, Args.Port);

      BaseURL := Format('http://%s:%d/v1', [Args.Addr, Args.Port]);
      WriteLn(Ansi.Bold, 'OpenAI-compatible server up.', Ansi.Reset);
      WriteLn('  base_url: ', BaseURL);
      WriteLn('  model:    ', Cfg.DefaultModel);
      WriteLn;
      WriteLn(Ansi.Dim, '  Example (openai-python):', Ansi.Reset);
      WriteLn('    client = OpenAI(base_url="', BaseURL, '", api_key="sk-pasclaw")');
      WriteLn('    client.chat.completions.create(model="', Cfg.DefaultModel,
              '", messages=[{"role":"user","content":"hi"}])');
      WriteLn;
      WriteLn(Ansi.Dim, '  Example (curl):', Ansi.Reset);
      WriteLn('    curl ', BaseURL, '/chat/completions -H "Content-Type: application/json" \');
      WriteLn('         -d ''{"model":"', Cfg.DefaultModel,
              '","messages":[{"role":"user","content":"hi"}]}''');
      WriteLn;
      WriteLn(Ansi.Dim, 'Press Ctrl-C to stop.', Ansi.Reset);

      Server.WaitForStop;
    finally
      Server.Stop;
      Server.Free;
      FreeMCPClients(MCPClients);
      if Reg <> nil then Reg.Free;
    end;

    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
