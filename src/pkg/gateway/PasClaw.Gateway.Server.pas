(*
  PasClaw.Gateway.Server - HTTP gateway built on TIdHTTPServer.
  Hosts a small JSON API:

    GET  /v1/health           -> health + version
    GET  /v1/status           -> provider, model, tools, mcp_servers, ...
    GET  /v1/tools            -> registered tool descriptors
    POST /v1/chat             -> body has "message", reply has "content"
    GET  /v1/version          -> build version

  Mirrors a stripped-down pkg/gateway from picoclaw. Channel webhooks (Slack,
  Discord, etc.) would be added as additional routes; the Telegram adapter
  uses long-polling instead so it doesn't need a public endpoint.
*)
unit PasClaw.Gateway.Server;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  IdHTTPServer, IdContext, IdCustomHTTPServer, IdGlobal, IdSocketHandle,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  { Wraps TIdHTTPServer and dispatches requests to handler methods. Pass a
    provider + tool registry in at construction; ownership stays with the
    caller. Stop() blocks until the listener has fully torn down. }
  TGatewayServer = class
  private
    FHTTP:     TIdHTTPServer;
    FCfg:      TConfig;
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FStarted:  Boolean;
    FStopFlag: TEvent;
    procedure OnCommandGet(AContext: TIdContext;
                           ARequest: TIdHTTPRequestInfo;
                           AResponse: TIdHTTPResponseInfo);
    procedure HandleHealth(AResp: TIdHTTPResponseInfo);
    procedure HandleVersion(AResp: TIdHTTPResponseInfo);
    procedure HandleStatus(AResp: TIdHTTPResponseInfo);
    procedure HandleTools(AResp: TIdHTTPResponseInfo);
    procedure HandleChat(ARequest: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
    procedure WriteJSON(AResp: TIdHTTPResponseInfo; Code: Integer; const Body: string);
  public
    constructor Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
    destructor  Destroy; override;
    procedure Start(const BindAddr: string; Port: Integer);
    procedure Stop;
    procedure WaitForStop;
  end;

implementation

uses
  fpjson, jsonparser,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop;

constructor TGatewayServer.Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FStopFlag := TEvent.Create(nil, True, False, '');
  FHTTP := TIdHTTPServer.Create(nil);
  FHTTP.OnCommandGet := OnCommandGet;
  FHTTP.KeepAlive    := True;
  FHTTP.ServerSoftware := 'PasClaw/' + FormatVersion;
end;

destructor TGatewayServer.Destroy;
begin
  Stop;
  FHTTP.Free;
  FStopFlag.Free;
  inherited Destroy;
end;

procedure TGatewayServer.Start(const BindAddr: string; Port: Integer);
var
  Binding: TIdSocketHandle;
begin
  if FStarted then Exit;
  FHTTP.Bindings.Clear;
  Binding := FHTTP.Bindings.Add;
  Binding.IP   := BindAddr;
  Binding.Port := Port;
  FHTTP.Active := True;
  FStarted := True;
  LogInfo('gateway: listening on http://%s:%d', [BindAddr, Port]);
end;

procedure TGatewayServer.Stop;
begin
  if not FStarted then Exit;
  try
    FHTTP.Active := False;
  except
    on E: Exception do LogWarn('gateway: stop error: %s', [E.Message]);
  end;
  FStarted := False;
  FStopFlag.SetEvent;
  LogInfo('gateway: stopped');
end;

procedure TGatewayServer.WaitForStop;
begin
  FStopFlag.WaitFor(INFINITE);
end;

procedure TGatewayServer.WriteJSON(AResp: TIdHTTPResponseInfo; Code: Integer; const Body: string);
begin
  AResp.ResponseNo  := Code;
  AResp.ContentType := 'application/json; charset=utf-8';
  AResp.CharSet     := 'utf-8';
  AResp.ContentText := Body;
end;

procedure TGatewayServer.OnCommandGet(AContext: TIdContext;
                                     ARequest: TIdHTTPRequestInfo;
                                     AResponse: TIdHTTPResponseInfo);
var
  Doc: string;
begin
  Doc := ARequest.Document;
  LogDebug('gateway: %s %s', [ARequest.Command, Doc]);

  try
    if      (ARequest.Command = 'GET')  and (Doc = '/v1/health')  then HandleHealth(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/version') then HandleVersion(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/status')  then HandleStatus(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/tools')   then HandleTools(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/chat')    then HandleChat(ARequest, AResponse)
    else if Doc = '/' then
      WriteJSON(AResponse, 200,
        '{"name":"pasclaw","routes":["/v1/health","/v1/version","/v1/status","/v1/tools","/v1/chat"]}')
    else
      WriteJSON(AResponse, 404, '{"error":"not found","path":"' + Doc + '"}');
  except
    on E: Exception do
    begin
      LogError('gateway: handler crashed: %s', [E.Message]);
      WriteJSON(AResponse, 500, '{"error":"internal","message":"' + E.Message + '"}');
    end;
  end;
end;

procedure TGatewayServer.HandleHealth(AResp: TIdHTTPResponseInfo);
begin
  WriteJSON(AResp, 200, '{"status":"ok","version":"' + FormatVersion + '"}');
end;

procedure TGatewayServer.HandleVersion(AResp: TIdHTTPResponseInfo);
begin
  WriteJSON(AResp, 200, '{"version":"' + FormatVersion + '","build":"' + FormatBuildInfo + '"}');
end;

procedure TGatewayServer.HandleStatus(AResp: TIdHTTPResponseInfo);
var
  J: TJSONObject;
begin
  J := TJSONObject.Create;
  try
    J.Add('default_provider', FCfg.DefaultProvider);
    J.Add('default_model',    FCfg.DefaultModel);
    J.Add('providers',        Length(FCfg.Providers));
    J.Add('mcp_servers',      Length(FCfg.MCPServers));
    J.Add('crons',            Length(FCfg.Crons));
    J.Add('skills',           Length(FCfg.Skills));
    if FRegistry <> nil then
      J.Add('tools',          FRegistry.Count)
    else
      J.Add('tools', 0);
    WriteJSON(AResp, 200, J.AsJSON);
  finally
    J.Free;
  end;
end;

procedure TGatewayServer.HandleTools(AResp: TIdHTTPResponseInfo);
var
  Root: TJSONObject;
  Arr: TJSONArray;
  Defs: TToolDefinitionArray;
  i: Integer;
  ToolObj: TJSONObject;
begin
  Root := TJSONObject.Create;
  Arr  := TJSONArray.Create;
  try
    if FRegistry <> nil then
    begin
      Defs := FRegistry.ToProviderDefs;
      for i := 0 to High(Defs) do
      begin
        ToolObj := TJSONObject.Create;
        ToolObj.Add('name',        Defs[i].Name);
        ToolObj.Add('description', Defs[i].Description);
        ToolObj.Add('schema',      Defs[i].Schema);
        Arr.Add(ToolObj);
      end;
    end;
    Root.Add('tools', Arr);
    WriteJSON(AResp, 200, Root.AsJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleChat(ARequest: TIdHTTPRequestInfo;
                                    AResp: TIdHTTPResponseInfo);
var
  Body, Prompt: string;
  Req, RespJ: TJSONObject;
  Data: TJSONData;
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
begin
  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Body, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
      ARequest.PostStream.ReadBuffer(Body[1], ARequest.PostStream.Size);
  end;

  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"empty body"}');
    Exit;
  end;

  Prompt := '';
  try
    Data := GetJSON(Body);
    try
      if Data is TJSONObject then
      begin
        Req := TJSONObject(Data);
        Prompt := Req.Get('message', '');
      end;
    finally
      Data.Free;
    end;
  except
    WriteJSON(AResp, 400, '{"error":"invalid json"}');
    Exit;
  end;

  if Prompt = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing field: message"}');
    Exit;
  end;

  if FProvider = nil then
  begin
    WriteJSON(AResp, 503, '{"error":"no provider configured"}');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Prompt);

  LoopCfg.Provider      := FProvider;
  LoopCfg.Registry      := FRegistry;
  LoopCfg.Model         := FCfg.DefaultModel;
  LoopCfg.MaxIterations := 8;
  LoopCfg.Options       := DefaultChatOptions;
  LoopCfg.OnText        := nil;
  LoopCfg.OnToolCall    := nil;
  LoopCfg.OnToolResult  := nil;

  if not RunToolLoop(LoopCfg, Msgs, Loop) then
  begin
    WriteJSON(AResp, 502, '{"error":"loop failed"}');
    Exit;
  end;

  RespJ := TJSONObject.Create;
  try
    RespJ.Add('content',     Loop.Content);
    RespJ.Add('iterations',  Loop.Iterations);
    RespJ.Add('input_tokens', Loop.LastResp.Usage.InputTokens);
    RespJ.Add('output_tokens', Loop.LastResp.Usage.OutputTokens);
    WriteJSON(AResp, 200, RespJ.AsJSON);
  finally
    RespJ.Free;
  end;
end;

end.
