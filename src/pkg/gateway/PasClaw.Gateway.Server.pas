(*
  PasClaw.Gateway.Server - HTTP gateway built on TIdHTTPServer.
  Hosts a small JSON API:

    GET  /v1/health                -> health + version
    GET  /v1/status                -> provider, model, tools, mcp_servers, ...
    GET  /v1/tools                 -> registered tool descriptors
    POST /v1/chat                  -> body has "message", reply has "content"
    POST /v1/chat/completions      -> OpenAI Chat Completions-compatible
                                      (request: {model, messages, ...},
                                       response: {id, choices[{message}], usage}
                                       — SSE if stream:true is set)
    POST /v1/responses             -> OpenAI Responses-compatible
                                      (request: {model, input, ...},
                                       response: {id, output[{content}], usage})
    GET  /v1/models                -> OpenAI-compatible model list
    GET  /v1/version               -> build version

  Mirrors a stripped-down pkg/gateway from picoclaw. The `serve` subcommand
  is a focused wrapper for the OpenAI-compatible surface; `gateway` is the
  full feature set with channels.
*)
unit PasClaw.Gateway.Server;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
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
    FDebugIO:  Boolean;
    FMaxIter:  Integer;
    procedure OnCommandGet(AContext: TIdContext;
                           ARequest: TIdHTTPRequestInfo;
                           AResponse: TIdHTTPResponseInfo);
    procedure HandleHealth(AResp: TIdHTTPResponseInfo);
    procedure HandleVersion(AResp: TIdHTTPResponseInfo);
    procedure HandleStatus(AResp: TIdHTTPResponseInfo);
    procedure HandleTools(AResp: TIdHTTPResponseInfo);
    procedure HandleChat(ARequest: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
    procedure HandleChatCompletions(AContext: TIdContext;
                                    ARequest: TIdHTTPRequestInfo;
                                    AResp: TIdHTTPResponseInfo;
                                    out AWasStreamingRequest: Boolean;
                                    out AResponseStarted: Boolean);
    procedure HandleResponses(AContext: TIdContext;
                              ARequest: TIdHTTPRequestInfo;
                              AResp: TIdHTTPResponseInfo;
                              out AWasStreamingRequest: Boolean;
                              out AResponseStarted: Boolean);
    procedure HandleModels(AResp: TIdHTTPResponseInfo);
    procedure WriteJSON(AResp: TIdHTTPResponseInfo; Code: Integer; const Body: string);
    procedure WriteSSE(AResp: TIdHTTPResponseInfo; const Body: string);
  public
    constructor Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
    destructor  Destroy; override;
    { When True every request to /v1/chat/completions logs its full body
      and the response body via LogDebug. Off by default; the `serve`
      subcommand flips it on with --debug. }
    property DebugIO: Boolean read FDebugIO write FDebugIO;
    { Cap on tool-loop iterations for /v1/chat/completions. Defaults to 25
      to match what typical code agents need for read-debug-edit cycles;
      legacy /v1/chat keeps its 8-iteration cap unchanged. }
    property MaxIter: Integer read FMaxIter write FMaxIter;
    procedure Start(const BindAddr: string; Port: Integer);
    procedure Stop;
    procedure WaitForStop;
  end;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Prompt,
  PasClaw.Gateway.WebUI;

constructor TGatewayServer.Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FMaxIter  := 25;
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

procedure WriteBodyStream(AResp: TIdHTTPResponseInfo; const Body: string);
var
  Strm: TMemoryStream;
  Bytes: TBytes;
begin
  { Indy's ContentText writer on FPC + UTF-8 doesn't always flush a body
    correctly. ContentStream is the reliable path: encode the string to bytes
    ourselves, hand Indy a TMemoryStream sized in bytes, and let it stream. }
  Bytes := TEncoding.UTF8.GetBytes(Body);
  Strm := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    Strm.WriteBuffer(Bytes[0], Length(Bytes));
  Strm.Position := 0;
  AResp.ContentStream     := Strm;
  AResp.FreeContentStream := True;
  AResp.ContentLength     := Strm.Size;
end;

procedure TGatewayServer.WriteJSON(AResp: TIdHTTPResponseInfo; Code: Integer; const Body: string);
begin
  AResp.ResponseNo  := Code;
  AResp.ContentType := 'application/json; charset=utf-8';
  AResp.CharSet     := 'utf-8';
  WriteBodyStream(AResp, Body);
end;

procedure TGatewayServer.WriteSSE(AResp: TIdHTTPResponseInfo; const Body: string);
begin
  AResp.ResponseNo := 200;
  AResp.ContentType := 'text/event-stream; charset=utf-8';
  AResp.CharSet     := 'utf-8';
  AResp.CustomHeaders.AddValue('Cache-Control', 'no-cache');
  AResp.CustomHeaders.AddValue('X-Accel-Buffering', 'no');
  WriteBodyStream(AResp, Body);
end;

procedure TGatewayServer.OnCommandGet(AContext: TIdContext;
                                     ARequest: TIdHTTPRequestInfo;
                                     AResponse: TIdHTTPResponseInfo);
var
  Doc: string;
  IsChatCompletionsStream: Boolean;
  ResponseStarted: Boolean;
begin
  Doc := ARequest.Document;
  IsChatCompletionsStream := False;
  ResponseStarted := False;
  LogDebug('gateway: %s %s', [ARequest.Command, Doc]);

  try
    if      (ARequest.Command = 'GET')  and (Doc = '/v1/health')  then HandleHealth(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/version') then HandleVersion(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/status')  then HandleStatus(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/tools')   then HandleTools(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/chat')    then HandleChat(ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/chat/completions') then
      HandleChatCompletions(AContext, ARequest, AResponse, IsChatCompletionsStream, ResponseStarted)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/responses') then
      HandleResponses(AContext, ARequest, AResponse, IsChatCompletionsStream, ResponseStarted)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/models')  then HandleModels(AResponse)
    else if Doc = '/' then
    begin
      AResponse.ResponseNo  := 200;
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.CharSet     := 'utf-8';
      { Hand Indy a raw byte stream loaded from the embedded resource — no
        string encoding involved. }
      AResponse.ContentStream     := WebUIStream;
      AResponse.FreeContentStream := True;
      AResponse.ContentLength     := AResponse.ContentStream.Size;
    end
    else if Doc = '/v1' then
      WriteJSON(AResponse, 200,
        '{"name":"pasclaw","routes":["/v1/health","/v1/version","/v1/status","/v1/tools","/v1/chat","/v1/chat/completions","/v1/responses","/v1/models"]}')
    else
      WriteJSON(AResponse, 404, '{"error":"not found","path":"' + Doc + '"}');
  except
    on E: Exception do
    begin
      LogError('gateway: handler crashed: %s', [E.Message]);
      if IsChatCompletionsStream and (ResponseStarted or AResponse.HeaderHasBeenWritten) then
      begin
        LogWarn('gateway: streaming response already started; closing connection');
        if (AContext <> nil) and (AContext.Connection <> nil) then
        begin
          try
            AContext.Connection.Disconnect;
          except
            on EDisconnect: Exception do
              LogWarn('gateway: failed to close streaming connection: %s', [EDisconnect.Message]);
          end;
        end;
      end
      else if not AResponse.HeaderHasBeenWritten then
        WriteJSON(AResponse, 500, '{"error":"internal","message":"' + E.Message + '"}')
      else if (AContext <> nil) and (AContext.Connection <> nil) then
        AContext.Connection.Disconnect;
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
  J: TJsonObject;
begin
  J := TJsonObject.Create;
  try
    J.PutStr('default_provider', FCfg.DefaultProvider);
    J.PutStr('default_model',    FCfg.DefaultModel);
    J.PutInt('providers',        Length(FCfg.Providers));
    J.PutInt('mcp_servers',      Length(FCfg.MCPServers));
    J.PutInt('crons',            Length(FCfg.Crons));
    J.PutInt('skills',           Length(FCfg.Skills));
    if FRegistry <> nil then J.PutInt('tools', FRegistry.Count)
    else                     J.PutInt('tools', 0);
    WriteJSON(AResp, 200, J.ToJSON);
  finally
    J.Free;
  end;
end;

procedure TGatewayServer.HandleTools(AResp: TIdHTTPResponseInfo);
var
  Root, ToolObj: TJsonObject;
  Arr: TJsonArray;
  Defs: TToolDefinitionArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    if FRegistry <> nil then
    begin
      Defs := FRegistry.ToProviderDefs;
      for i := 0 to High(Defs) do
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('name',        Defs[i].Name);
        ToolObj.PutStr('description', Defs[i].Description);
        ToolObj.PutStr('schema',      Defs[i].Schema);
        Arr.AddObject(ToolObj);
      end;
    end;
    Root.PutArray('tools', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleChat(ARequest: TIdHTTPRequestInfo;
                                    AResp: TIdHTTPResponseInfo);
var
  Body, Prompt: string;
  Bytes: TBytes;
  Req, RespJ: TJsonObject;
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
begin
  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      { Bodies are JSON, by convention UTF-8. Decoding here means the
        Delphi build sees the same string the FPC build does. }
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"empty body"}');
    Exit;
  end;

  Prompt := '';
  Req := TJsonObject.Parse(Body);
  if Req <> nil then
  try
    Prompt := Req.GetStr('message', '');
  finally
    Req.Free;
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
  LoopCfg.Options.SystemPrompt := BuildSystemPrompt(FCfg, '', LoopCfg.Registry <> nil);
  LoopCfg.OnText        := nil;
  LoopCfg.OnToolCall    := nil;
  LoopCfg.OnToolResult  := nil;

  if not RunToolLoop(LoopCfg, Msgs, Loop) then
  begin
    WriteJSON(AResp, 502, '{"error":"loop failed"}');
    Exit;
  end;

  RespJ := TJsonObject.Create;
  try
    RespJ.PutStr('content',       Loop.Content);
    RespJ.PutInt('iterations',    Loop.Iterations);
    RespJ.PutInt('input_tokens',  Loop.LastResp.Usage.InputTokens);
    RespJ.PutInt('output_tokens', Loop.LastResp.Usage.OutputTokens);
    WriteJSON(AResp, 200, RespJ.ToJSON);
  finally
    RespJ.Free;
  end;
end;

function GenChatCompletionId: string;
{ Mirror OpenAI's "chatcmpl-<random>" id convention. The exact value is
  opaque to clients — what matters is that it's unique per call. We seed
  from Random + a millisecond timestamp; sufficient for log correlation. }
const
  Alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
var
  i: Integer;
begin
  Result := 'chatcmpl-';
  for i := 1 to 24 do
    Result := Result + Alphabet[1 + Random(Length(Alphabet))];
end;

function BuildOpenAICompletion(const Id, Model, Content: string;
                                Usage: TUsageInfo;
                                const FinishReason: string): TJsonObject;
{ Construct an OpenAI Chat Completions response object — the non-streaming
  shape that the OpenAI SDK / LangChain / autogen / etc. all parse. }
var
  Choice, Msg, UsageObj: TJsonObject;
  ChoicesArr: TJsonArray;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',      Id);
  Result.PutStr('object',  'chat.completion');
  Result.PutInt('created', DateTimeToUnix(Now, False));
  Result.PutStr('model',   Model);

  Msg := TJsonObject.Create;
  Msg.PutStr('role',    'assistant');
  Msg.PutStr('content', Content);

  Choice := TJsonObject.Create;
  Choice.PutInt('index', 0);
  Choice.PutObject('message', Msg);
  Choice.PutStr('finish_reason', FinishReason);

  ChoicesArr := TJsonArray.Create;
  ChoicesArr.AddObject(Choice);
  Result.PutArray('choices', ChoicesArr);

  UsageObj := TJsonObject.Create;
  UsageObj.PutInt('prompt_tokens',     Usage.InputTokens);
  UsageObj.PutInt('completion_tokens', Usage.OutputTokens);
  UsageObj.PutInt('total_tokens',      Usage.InputTokens + Usage.OutputTokens);
  Result.PutObject('usage', UsageObj);
end;

function BuildOpenAIChunk(const Id, Model, DeltaContent: string;
                           const FinishReason: string): string;
{ Construct one "data: ..." line for the SSE stream. Empty
  FinishReason omits the field; the terminating chunk passes 'stop'. }
var
  Root, Choice, Delta: TJsonObject;
  ChoicesArr: TJsonArray;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('id',      Id);
    Root.PutStr('object',  'chat.completion.chunk');
    Root.PutInt('created', DateTimeToUnix(Now, False));
    Root.PutStr('model',   Model);

    Delta := TJsonObject.Create;
    if DeltaContent <> '' then
      Delta.PutStr('content', DeltaContent);

    Choice := TJsonObject.Create;
    Choice.PutInt('index', 0);
    Choice.PutObject('delta', Delta);
    if FinishReason <> '' then Choice.PutStr('finish_reason', FinishReason);

    ChoicesArr := TJsonArray.Create;
    ChoicesArr.AddObject(Choice);
    Root.PutArray('choices', ChoicesArr);

    Result := 'data: ' + Root.ToJSON + #10#10;
  finally
    Root.Free;
  end;
end;

type
  (* Helper that streams SSE chunks directly to the TCP connection
     while the tool loop is still running. Indy's TIdHTTPResponseInfo
     normally buffers the entire body into a ContentStream and flushes
     at the end of the handler — that's fine for /v1/chat (one
     response per call) but with /v1/chat/completions stream:true and
     a long tool loop the client sees no bytes for many seconds. We
     issue WriteHeader once up front so the headers go on the wire,
     then write per-iteration chunks through the IOHandler so the
     client renders tool progress in real time. CloseConnection=True
     terminates the response when the handler returns; no
     Content-Length is needed. *)
  TSSEStreamer = class
  private
    FContext: TIdContext;
    FId, FModel: string;
    FDebugIO: Boolean;
    FClosed: Boolean;
    procedure WriteSocketBytes(const Data: TBytes);
  public
    constructor Create(AContext: TIdContext; const Id, Model: string;
                       DebugIO: Boolean);
    { Emits Data as a single HTTP/1.1 chunked-encoding chunk. Use this
      for SSE event payloads — every WriteChunk / WriteComment goes
      through here. }
    procedure WriteRaw(const Data: string);
    procedure WriteChunk(const DeltaContent, FinishReason: string);
    procedure WriteComment(const Note: string);
    procedure WriteError(const Msg: string);
    procedure NoteToolCall(const Name, ArgsJSON: string);
    procedure NoteToolResult(const Name, ResultText, Err: string);
    procedure Finalize(const Content, FinishReason: string);
    { Writes the zero-length terminator chunk that ends a chunked
      transfer-encoding response. Called by Finalize. }
    procedure CloseStream;
    property Closed: Boolean read FClosed;
  end;

constructor TSSEStreamer.Create(AContext: TIdContext; const Id, Model: string;
                                DebugIO: Boolean);
begin
  inherited Create;
  FContext := AContext;
  FId      := Id;
  FModel   := Model;
  FDebugIO := DebugIO;
  FClosed  := False;
end;

procedure TSSEStreamer.WriteSocketBytes(const Data: TBytes);
var
  Bytes: TIdBytes;
  i: Integer;
begin
  if Length(Data) = 0 then Exit;
  if (FContext = nil) or (FContext.Connection = nil) or
     (not FContext.Connection.Connected) then
  begin
    if FDebugIO then
      LogDebug('sse: connection already closed before write of %d bytes', [Length(Data)]);
    Exit;
  end;
  SetLength(Bytes, Length(Data));
  for i := 0 to High(Data) do Bytes[i] := Data[i];
  try
    FContext.Connection.IOHandler.Write(Bytes);
    (* TIdHTTPServer's request handler runs inside WriteBufferOpen so
       it can compute Content-Length. We don't want that — every byte
       has to land on the wire as soon as we emit it. Loop
       WriteBufferClose until WriteBufferingActive is False to drain
       the nested server + WriteHeader buffer stack. After the first
       chunk drains it the loop becomes a no-op. *)
    while FContext.Connection.IOHandler.WriteBufferingActive do
      FContext.Connection.IOHandler.WriteBufferClose;
  except
    on E: Exception do
      if FDebugIO then LogDebug('sse: write failed: %s', [E.Message]);
  end;
end;

procedure TSSEStreamer.WriteRaw(const Data: string);
const
  CRLF: array[0..1] of Byte = (13, 10);
var
  Payload, Header, Frame: TBytes;
  HeaderStr: string;
  i, Offset: Integer;
begin
  Payload := TEncoding.UTF8.GetBytes(Data);
  if Length(Payload) = 0 then Exit;
  (* HTTP/1.1 chunked-transfer chunk: `<hex-length>\r\n<bytes>\r\n`.
     The response header (set by HandleChatCompletions) carries
     `Transfer-Encoding: chunked`; the terminator chunk (`0\r\n\r\n`)
     is written by CloseStream when Finalize runs. Framing each SSE
     event as its own chunk is what lets the client parse partial
     responses as they arrive instead of treating the absent
     Content-Length as a zero-byte body and closing immediately. *)
  HeaderStr := IntToHex(Length(Payload), 1) + #13#10;
  Header := TEncoding.UTF8.GetBytes(HeaderStr);
  SetLength(Frame, Length(Header) + Length(Payload) + 2);
  Offset := 0;
  for i := 0 to High(Header)  do begin Frame[Offset] := Header[i];  Inc(Offset); end;
  for i := 0 to High(Payload) do begin Frame[Offset] := Payload[i]; Inc(Offset); end;
  Frame[Offset]     := CRLF[0];
  Frame[Offset + 1] := CRLF[1];
  WriteSocketBytes(Frame);
end;

procedure TSSEStreamer.CloseStream;
var
  Terminator: TBytes;
begin
  if FClosed then Exit;
  FClosed := True;
  Terminator := TEncoding.UTF8.GetBytes('0'#13#10#13#10);
  WriteSocketBytes(Terminator);
end;

procedure TSSEStreamer.WriteChunk(const DeltaContent, FinishReason: string);
begin
  WriteRaw(BuildOpenAIChunk(FId, FModel, DeltaContent, FinishReason));
end;

procedure TSSEStreamer.WriteComment(const Note: string);
var
  Clean: string;
begin
  (* Lines starting with `:` are SSE comments per the spec — every
     compliant client (openai-python, anthropic-sdk, langchain,
     autogen) skips them silently.

     IMPORTANT: callers pass arbitrary content here (tool argsJSON,
     tool result text). If the body contains a newline followed by
     `data: ...` or another SSE field, a naive `: ' + Note + #10#10`
     would let that line be parsed as a real event, terminating or
     corrupting the stream. Strip CR and prefix EVERY line of the
     body with `: ` so the whole thing stays inside the comment, then
     append the empty-line terminator. *)
  Clean := StringReplace(Note, #13, '', [rfReplaceAll]);
  Clean := StringReplace(Clean, #10, #10': ', [rfReplaceAll]);
  WriteRaw(': ' + Clean + #10#10);
end;

procedure TSSEStreamer.WriteError(const Msg: string);
var
  Root, Err: TJsonObject;
begin
  (* Stream-mode error after headers are already on the wire. We can't
     change the status, but we can send an OpenAI-style error frame
     followed by [DONE] so clients that recognize streaming errors
     surface them properly instead of treating an assistant turn that
     says "tool loop failed" as a normal completion. *)
  Root := TJsonObject.Create;
  try
    Err := TJsonObject.Create;
    Err.PutStr('message', Msg);
    Err.PutStr('type',    'server_error');
    Root.PutObject('error', Err);
    WriteRaw('data: ' + Root.ToJSON + #10#10);
  finally
    Root.Free;
  end;
  WriteRaw('data: [DONE]'#10#10);
  CloseStream;
end;

procedure TSSEStreamer.NoteToolCall(const Name, ArgsJSON: string);
var
  Preview: string;
begin
  (* One visible delta with a small bracketed marker so the client
     actually shows progress, plus a comment with the args for any
     consumer that wants to log structured tool activity. The visible
     delta is the bit that turns the long silence into a heartbeat the
     user can see in their chat UI. *)
  Preview := ArgsJSON;
  if Length(Preview) > 200 then Preview := Copy(Preview, 1, 200) + '...';
  if FDebugIO then
    LogDebug('chat/completions tool_call: name=%s args=%s', [Name, ArgsJSON]);
  WriteChunk(#10'[tool: ' + Name + ']'#10, '');
  WriteComment('tool_call name=' + Name + ' args=' + Preview);
end;

procedure TSSEStreamer.NoteToolResult(const Name, ResultText, Err: string);
var
  Status, Preview: string;
begin
  if Err <> '' then Status := 'err: ' + Err
  else if Length(ResultText) < 80 then Status := ResultText
  else Status := IntToStr(Length(ResultText)) + ' bytes';
  if FDebugIO then
  begin
    Preview := ResultText;
    if Length(Preview) > 4000 then Preview := Copy(Preview, 1, 4000) + '...';
    LogDebug('chat/completions tool_result: name=%s err=%s result=%s',
             [Name, Err, Preview]);
  end;
  WriteComment('tool_result name=' + Name + ' ' + Status);
end;

procedure TSSEStreamer.Finalize(const Content, FinishReason: string);
begin
  WriteChunk(Content, '');
  WriteChunk('', FinishReason);
  WriteRaw('data: [DONE]'#10#10);
  CloseStream;
end;

procedure TGatewayServer.HandleChatCompletions(AContext: TIdContext;
                                                ARequest: TIdHTTPRequestInfo;
                                                AResp: TIdHTTPResponseInfo;
                                                out AWasStreamingRequest: Boolean;
                                                out AResponseStarted: Boolean);
(* OpenAI Chat Completions API. Accepts the standard request shape
   (model, messages array of role/content objects, optional temperature,
   max_tokens, stream, tools) and routes through the existing tool loop.

   When stream:true is set we flush response headers immediately, then
   write SSE chunks to the connection as the tool loop progresses —
   one visible delta per tool call so the client renders activity in
   real time, plus structured SSE comments any consumer can log. After
   the loop completes we write the final content delta, a finish-reason
   chunk, and the [DONE] terminator. The non-streaming path is
   unchanged: build the full chat.completion JSON and reply once. *)
var
  Body, ReqModel, FinishReason, CompId: string;
  Bytes: TBytes;
  Req, MsgObj: TJsonObject;
  MsgArr: TJsonArray;
  Msgs: array of TMessage;
  i: Integer;
  WantsStream: Boolean;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  RawTemp: Double;
  ReplyObj: TJsonObject;
  Streamer: TSSEStreamer;
  StreamStarted, StreamClosed: Boolean;
  function SanitizeStreamError(const S: string): string;
  begin
    Result := StringReplace(S, #13, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
    Result := Trim(Result);
    if Result = '' then Result := 'unknown failure';
  end;
begin
  Streamer := nil;
  StreamStarted := False;
  StreamClosed := False;
  AWasStreamingRequest := False;
  AResponseStarted := False;
  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if FDebugIO then
    LogDebug('chat/completions <- %d bytes from %s: %s',
             [Length(Bytes), ARequest.RemoteIP, Body]);

  if Trim(Body) = '' then
  begin
    if FDebugIO then LogDebug('chat/completions -> 400 (empty body)');
    WriteJSON(AResp, 400,
      '{"error":{"message":"empty request body","type":"invalid_request_error"}}');
    Exit;
  end;

  Req := TJsonObject.Parse(Body);
  if Req = nil then
  begin
    if FDebugIO then LogDebug('chat/completions -> 400 (invalid JSON)');
    WriteJSON(AResp, 400,
      '{"error":{"message":"invalid JSON","type":"invalid_request_error"}}');
    Exit;
  end;

  try
    ReqModel    := Req.GetStr('model', FCfg.DefaultModel);
    WantsStream := Req.GetBool('stream', False);
    AWasStreamingRequest := WantsStream;
    if FDebugIO then
      LogDebug('chat/completions: model=%s stream=%s temperature=%g max_tokens=%d',
               [ReqModel, BoolToStr(WantsStream, True),
                Req.GetFloat('temperature', 0),
                Req.GetInt('max_tokens', 0)]);

    { Walk messages[] -> TMessageArray. We accept the OpenAI shape but
      pass the raw content string through; multimodal/image parts get
      flattened by treating content as plain text only. }
    MsgArr := Req.ChildArray('messages');
    if (MsgArr = nil) or (MsgArr.Count = 0) then
    begin
      if FDebugIO then LogDebug('chat/completions -> 400 (no messages[])');
      WriteJSON(AResp, 400,
        '{"error":{"message":"missing or empty messages[]","type":"invalid_request_error"}}');
      if MsgArr <> nil then MsgArr.Free;
      Exit;
    end;
    try
      SetLength(Msgs, MsgArr.Count);
      for i := 0 to MsgArr.Count - 1 do
      begin
        MsgObj := MsgArr.ItemObject(i);
        if MsgObj = nil then Continue;
        try
          Msgs[i] := MakeMessage(MsgRoleFromString(MsgObj.GetStr('role', 'user')),
                                  MsgObj.GetStr('content', ''));
        finally
          MsgObj.Free;
        end;
      end;
    finally
      MsgArr.Free;
    end;

    if FProvider = nil then
    begin
      if FDebugIO then LogDebug('chat/completions -> 503 (no provider configured)');
      WriteJSON(AResp, 503,
        '{"error":{"message":"no provider configured","type":"server_error"}}');
      Exit;
    end;

    LoopCfg.Provider      := FProvider;
    LoopCfg.Registry      := FRegistry;
    LoopCfg.Model         := ReqModel;
    LoopCfg.MaxIterations := FMaxIter;
    LoopCfg.Options       := DefaultChatOptions;
    { Inject the composed PasClaw system prompt — but only if the client
      didn't already supply one of their own. Third-party tooling calling
      /v1/chat/completions with its own persona/system message should win;
      bare-bones clients that send only a user message get our identity
      preamble for free. }
    if not HasSystemMessage(Msgs) then
      LoopCfg.Options.SystemPrompt := BuildSystemPrompt(FCfg, '', LoopCfg.Registry <> nil);
    { Temperature: only forward if the client actually set it (>0). Avoids
      the deprecated-field 400 from newer Claude models when the OpenAI
      client library defaults to 1.0. }
    RawTemp := Req.GetFloat('temperature', 0);
    if RawTemp > 0 then LoopCfg.Options.Temperature := RawTemp;
    if Req.Has('max_tokens') then
      LoopCfg.Options.MaxTokens := Req.GetInt('max_tokens', LoopCfg.Options.MaxTokens);
    LoopCfg.OnText        := nil;
    LoopCfg.OnToolCall    := nil;
    LoopCfg.OnToolResult  := nil;

    CompId := GenChatCompletionId;

    if WantsStream then
    begin
      { Dedicated guard for all streamed execution once headers are emitted.
        After this point we must never fall back to WriteJSON. }
      try
      { Stream path: flush SSE headers up front and hook the tool loop
        so chunks reach the client as each tool call happens. The loop
        itself still runs synchronously in this thread; the difference
        is the response body now drains incrementally instead of all
        at once at the end. }
      AResp.ResponseNo  := 200;
      AResp.ContentType := 'text/event-stream; charset=utf-8';
      AResp.CharSet     := 'utf-8';
      AResp.CustomHeaders.AddValue('Cache-Control', 'no-cache');
      AResp.CustomHeaders.AddValue('X-Accel-Buffering', 'no');
      AResp.CustomHeaders.AddValue('Transfer-Encoding', 'chunked');
      AResp.ContentLength := -1;  { suppress Indy's auto Content-Length header }
      { Avoid AResp.CloseConnection := True: combined with no
        Content-Length, Indy was emitting `Content-Length: 0` +
        `Connection: close`, and OpenAI clients (nanobot, etc.) read
        the zero-byte body, marked the response complete, and closed
        the socket immediately — which is why every subsequent SSE
        chunk hit `connection already closed` in the debug log.
        Chunked transfer encoding tells the client to keep reading
        until a zero-length terminator chunk arrives, which
        TSSEStreamer.CloseStream writes when Finalize / WriteError
        finishes. Indy still sets a Content-Length header on its own
        when none is set, so we add the chunked header via
        CustomHeaders rather than relying on AResp.TransferEncoding
        which on some Indy builds also tries to auto-frame body
        writes (and would double-chunk ours). }
      AResp.WriteHeader;
      StreamStarted := True;
      AResponseStarted := True;
      { Drain every nested write buffer so headers AND subsequent body
        writes go straight to the socket. TIdHTTPServer opens a
        connection-level buffer per request to compute Content-Length;
        WriteHeader opens another inside that to write its own bytes.
        WriteBufferFlush only flushes one level at a time and is a no-op
        when no buffer is open — so loop until WriteBufferingActive is
        False. After this, subsequent IOHandler.Write calls hit the
        socket immediately. }
      while AContext.Connection.IOHandler.WriteBufferingActive do
        AContext.Connection.IOHandler.WriteBufferClose;
      if FDebugIO then
        LogDebug('sse: headers flushed, connection still up=%s',
                 [BoolToStr(AContext.Connection.Connected, True)]);
      Streamer := TSSEStreamer.Create(AContext, CompId, ReqModel, FDebugIO);
      LoopCfg.OnToolCall   := Streamer.NoteToolCall;
      LoopCfg.OnToolResult := Streamer.NoteToolResult;
      Streamer.WriteComment('connected');
      if not RunToolLoop(LoopCfg, Msgs, Loop) then
      begin
        if FDebugIO then LogDebug('chat/completions -> 502 (tool loop failed)');
        Streamer.WriteError('tool loop failed');
        StreamClosed := Streamer.Closed;
        Exit;
      end;
      if Loop.LastResp.FinishReason <> '' then
        FinishReason := Loop.LastResp.FinishReason
      else
        FinishReason := 'stop';

      if Length(Loop.LastResp.ToolCalls) > 0 then
      begin
        Loop.Content := Trim(Loop.Content);
        if Loop.Content <> '' then Loop.Content := Loop.Content + #10#10;
        Loop.Content := Loop.Content + Format(
          '(reached MaxIterations=%d while the model was still calling tools; '+
          'last finish_reason=%s, %d pending tool call(s) — raise the --max-iter '+
          'cap on `pasclaw serve` or reduce the task scope.)',
          [FMaxIter, FinishReason, Length(Loop.LastResp.ToolCalls)]);
        FinishReason := 'length';
        LogWarn('chat/completions: tool loop hit MaxIterations=%d (%d pending tool call(s), %d content chars)',
                [FMaxIter, Length(Loop.LastResp.ToolCalls), Length(Loop.Content)]);
      end
      else if Loop.Content = '' then
      begin
        Loop.Content := Format('(no content returned by the model; finish_reason=%s)',
                                [FinishReason]);
        LogWarn('chat/completions: empty content with finish=%s iterations=%d',
                [FinishReason, Loop.Iterations]);
      end;

      if FDebugIO then
        LogDebug('chat/completions: tool loop done iterations=%d in=%d out=%d finish=%s content=%s',
                 [Loop.Iterations, Loop.LastResp.Usage.InputTokens,
                  Loop.LastResp.Usage.OutputTokens, FinishReason, Loop.Content]);
      if FDebugIO then LogDebug('chat/completions -> 200 SSE (final)');
      Streamer.Finalize(Loop.Content, FinishReason);
      StreamClosed := Streamer.Closed;
      except
        on E: Exception do
        begin
          if StreamStarted and (not StreamClosed) and
             (Streamer <> nil) and (not Streamer.Closed) then
          begin
            try
              Streamer.WriteError('internal error: ' + SanitizeStreamError(E.Message));
              StreamClosed := Streamer.Closed;
            except
              if (AContext <> nil) and (AContext.Connection <> nil) then
                AContext.Connection.Disconnect;
            end;
          end
          else if (AContext <> nil) and (AContext.Connection <> nil) then
            AContext.Connection.Disconnect;
          raise;
        end;
      end;
      Exit;
    end;

    if not RunToolLoop(LoopCfg, Msgs, Loop) then
    begin
      if FDebugIO then LogDebug('chat/completions -> 502 (tool loop failed)');
      WriteJSON(AResp, 502,
        '{"error":{"message":"tool loop failed","type":"server_error"}}');
      Exit;
    end;

    if Loop.LastResp.FinishReason <> '' then
      FinishReason := Loop.LastResp.FinishReason
    else
      FinishReason := 'stop';

    { Tag cap-exhausted turns regardless of whether the model produced
      pre-tool narration. The discriminator is the presence of pending
      tool calls in the last response: RunToolLoop only exits via the
      cap when the last turn had ToolCalls (otherwise it early-returns
      cleanly). Iterations >= FMaxIter alone is ambiguous since a clean
      completion on the very last allowed turn also reports that count.

      When the cap is hit:
        - empty Content -> the cap note is the whole message
        - non-empty Content (model said "Let me check..." then called a
          tool) -> keep the partial text and append the cap note. Set
          finish_reason=length so clients don't treat a truncated tool
          loop as a completed answer. }
    if Length(Loop.LastResp.ToolCalls) > 0 then
    begin
      Loop.Content := Trim(Loop.Content);
      if Loop.Content <> '' then Loop.Content := Loop.Content + #10#10;
      Loop.Content := Loop.Content + Format(
        '(reached MaxIterations=%d while the model was still calling tools; '+
        'last finish_reason=%s, %d pending tool call(s) — raise the --max-iter '+
        'cap on `pasclaw serve` or reduce the task scope.)',
        [FMaxIter, FinishReason, Length(Loop.LastResp.ToolCalls)]);
      FinishReason := 'length';
      LogWarn('chat/completions: tool loop hit MaxIterations=%d (%d pending tool call(s), %d content chars)',
              [FMaxIter, Length(Loop.LastResp.ToolCalls), Length(Loop.Content)]);
    end
    else if Loop.Content = '' then
    begin
      { Loop exited normally with no pending tool calls but the model
        produced no text. Some streaming clients can't represent that. }
      Loop.Content := Format('(no content returned by the model; finish_reason=%s)',
                              [FinishReason]);
      LogWarn('chat/completions: empty content with finish=%s iterations=%d',
              [FinishReason, Loop.Iterations]);
    end;

    if FDebugIO then
      LogDebug('chat/completions: tool loop done iterations=%d in=%d out=%d finish=%s content=%s',
               [Loop.Iterations, Loop.LastResp.Usage.InputTokens,
                Loop.LastResp.Usage.OutputTokens, FinishReason, Loop.Content]);

    ReplyObj := BuildOpenAICompletion(CompId, ReqModel, Loop.Content,
                                       Loop.LastResp.Usage, FinishReason);
    try
      if FDebugIO then LogDebug('chat/completions -> 200 JSON: %s', [ReplyObj.ToJSON]);
      WriteJSON(AResp, 200, ReplyObj.ToJSON);
    finally
      ReplyObj.Free;
    end;
  finally
    Req.Free;
    if Streamer <> nil then Streamer.Free;
  end;
end;


function GenResponseId: string;
{ Opaque Responses API id. Keep it distinct from chatcmpl-* so logs can
  distinguish which OpenAI-compatible surface handled the request. }
const
  Alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
var
  i: Integer;
begin
  Result := 'resp_';
  for i := 1 to 24 do
    Result := Result + Alphabet[1 + Random(Length(Alphabet))];
end;

function BuildResponsesObject(const Id, Model, Status, Content: string;
                               Usage: TUsageInfo): TJsonObject;
(* OpenAI Responses-compatible non-streaming response.

  The openai-python SDK's Pydantic `Response` model marks four fields
  as required (no default) — when any of them is absent from the JSON
  the SDK raises ValidationError and the client appears to "choke" on
  what looks like a valid 200 response:

    parallel_tool_calls : bool
    tool_choice         : ToolChoice (string "auto"/"none" or object)
    tools               : List[Tool]
    output              : List[ResponseOutputItem]

  The first three are emitted with safe defaults (`false`, `"auto"`,
  `[]`) and the fourth carries the assistant message. The remaining
  optional fields are emitted as explicit `null` rather than absent —
  Pydantic treats both the same for `Optional[X] = None`, but newer
  SDK versions have shipped stricter validators in the past, and
  explicit `null` keeps the response shape stable against future
  releases.

  `text` is emitted as `{"format": {"type": "text"}}` (the Responses
  API formatting config). `error` and `incomplete_details` are
  explicit `null` on the success path so the SDK's branch for those
  fields takes the success branch deterministically. The non-success
  path (HandleResponses' RunToolLoop-failed branch) attaches a real
  `error` object with `code` + `message` per ResponseError schema. *)
var
  OutputArr, ContentArr, AnnotationsArr, ToolsArr: TJsonArray;
  MsgObj, TextObj, UsageObj, TextCfgObj, FormatObj: TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',         Id);
  Result.PutStr('object',     'response');
  Result.PutInt('created_at', DateTimeToUnix(Now, False));
  Result.PutStr('model',      Model);
  Result.PutStr('status',     Status);

  { Required by openai-python SDK Pydantic validation. }
  Result.PutBool('parallel_tool_calls', False);
  Result.PutStr ('tool_choice',         'auto');
  ToolsArr := TJsonArray.Create;
  Result.PutArray('tools', ToolsArr);

  { Optional but emitted as explicit null/empty so older or future
    stricter SDK versions don't trip on absent keys. }
  Result.PutRaw('error',              'null');
  Result.PutRaw('incomplete_details', 'null');
  Result.PutRaw('instructions',       'null');
  Result.PutRaw('metadata',           'null');
  Result.PutRaw('temperature',        'null');
  Result.PutRaw('top_p',              'null');
  Result.PutRaw('max_output_tokens',  'null');
  Result.PutRaw('previous_response_id','null');
  Result.PutRaw('reasoning',          'null');
  Result.PutRaw('service_tier',       'null');
  Result.PutRaw('truncation',         'null');
  Result.PutRaw('user',               'null');

  TextCfgObj := TJsonObject.Create;
  FormatObj  := TJsonObject.Create;
  FormatObj.PutStr('type', 'text');
  TextCfgObj.PutObject('format', FormatObj);
  Result.PutObject('text', TextCfgObj);

  OutputArr := TJsonArray.Create;
  if Content <> '' then
  begin
    MsgObj := TJsonObject.Create;
    MsgObj.PutStr('id',     'msg_' + Copy(Id, 6, MaxInt));
    MsgObj.PutStr('type',   'message');
    MsgObj.PutStr('status', Status);
    MsgObj.PutStr('role',   'assistant');

    TextObj := TJsonObject.Create;
    TextObj.PutStr('type', 'output_text');
    TextObj.PutStr('text', Content);
    AnnotationsArr := TJsonArray.Create;
    TextObj.PutArray('annotations', AnnotationsArr);

    ContentArr := TJsonArray.Create;
    ContentArr.AddObject(TextObj);
    MsgObj.PutArray('content', ContentArr);
    OutputArr.AddObject(MsgObj);
  end;
  Result.PutArray('output', OutputArr);

  UsageObj := TJsonObject.Create;
  UsageObj.PutInt('input_tokens',  Usage.InputTokens);
  UsageObj.PutInt('output_tokens', Usage.OutputTokens);
  UsageObj.PutInt('total_tokens',  Usage.InputTokens + Usage.OutputTokens);
  Result.PutObject('usage', UsageObj);
end;

procedure TGatewayServer.HandleResponses(AContext: TIdContext;
                                          ARequest: TIdHTTPRequestInfo;
                                          AResp: TIdHTTPResponseInfo;
                                          out AWasStreamingRequest: Boolean;
                                          out AResponseStarted: Boolean);
(* OpenAI Responses API compatibility. Accepts the request shape used by
   modern OpenAI clients and KAI: model, input (string or array of
   role/content messages), stream, temperature, and max_output_tokens. The
   request is translated into the same TMessageArray/TToolLoopConfig path as
   /v1/chat/completions. Responses streaming has a different event protocol,
   so this endpoint deliberately returns an OpenAI-shaped unsupported-streaming
   error instead of pretending chat-completion chunks are Responses events. *)
var
  Body, ReqModel, InputText, FinishReason, RespId: string;
  Bytes: TBytes;
  Req, InputObj, ReplyObj, ErrObj: TJsonObject;
  InputArr: TJsonArray;
  Msgs: array of TMessage;
  i, MsgCount: Integer;
  WantsStream: Boolean;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  RawTemp: Double;

  procedure AppendMessage(Role: TMsgRole; const Content: string);
  begin
    if Trim(Content) = '' then Exit;
    SetLength(Msgs, MsgCount + 1);
    Msgs[MsgCount] := MakeMessage(Role, Content);
    Inc(MsgCount);
  end;

  function FlattenTextArray(Arr: TJsonArray): string;
  var
    PartObj: TJsonObject;
    NestedArr: TJsonArray;
    PartText, NestedText: string;
    j: Integer;
  begin
    Result := '';
    if Arr = nil then Exit;
    for j := 0 to Arr.Count - 1 do
    begin
      PartText := Arr.ItemStr(j, '');
      if PartText = '' then
      begin
        PartObj := Arr.ItemObject(j);
        if PartObj <> nil then
        try
          PartText := PartObj.GetStr('text', '');
          if PartText = '' then PartText := PartObj.GetStr('input_text', '');
          if PartText = '' then PartText := PartObj.GetStr('output_text', '');
          if PartText = '' then
          begin
            NestedArr := PartObj.ChildArray('content');
            if NestedArr <> nil then
            try
              NestedText := FlattenTextArray(NestedArr);
              PartText := NestedText;
            finally
              NestedArr.Free;
            end;
          end;
        finally
          PartObj.Free;
        end;
      end;
      if Trim(PartText) <> '' then
      begin
        if Result <> '' then Result := Result + sLineBreak;
        Result := Result + PartText;
      end;
    end;
  end;

  function ExtractMessageContent(Obj: TJsonObject): string;
  var
    ContentArr: TJsonArray;
  begin
    Result := '';
    if Obj = nil then Exit;
    ContentArr := Obj.ChildArray('content');
    if ContentArr <> nil then
    try
      Result := FlattenTextArray(ContentArr);
    finally
      ContentArr.Free;
    end
    else
    begin
      Result := Obj.GetStr('content', '');
      if Result = '' then Result := Obj.GetStr('text', '');
      if Result = '' then Result := Obj.GetStr('input_text', '');
    end;
  end;

begin
  AWasStreamingRequest := False;
  AResponseStarted := False;
  Body := '';
  SetLength(Msgs, 0);
  MsgCount := 0;

  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if FDebugIO then
    LogDebug('responses <- %d bytes from %s: %s',
             [Length(Bytes), ARequest.RemoteIP, Body]);

  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400,
      '{"error":{"message":"empty request body","type":"invalid_request_error"}}');
    Exit;
  end;

  try
    Req := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 400,
        '{"error":{"message":"invalid JSON","type":"invalid_request_error"}}');
      Exit;
    end;
  end;

  if Req = nil then
  begin
    WriteJSON(AResp, 400,
      '{"error":{"message":"invalid JSON object","type":"invalid_request_error"}}');
    Exit;
  end;

  try
    ReqModel    := Req.GetStr('model', FCfg.DefaultModel);
    WantsStream := Req.GetBool('stream', False);
    AWasStreamingRequest := WantsStream;

    if WantsStream then
    begin
      WriteJSON(AResp, 400,
        '{"error":{"message":"Responses streaming is not yet supported; use stream:false or /v1/chat/completions for SSE.","type":"invalid_request_error","param":"stream","code":"unsupported_streaming"}}');
      Exit;
    end;

    InputArr := Req.ChildArray('input');
    if InputArr <> nil then
    try
      for i := 0 to InputArr.Count - 1 do
      begin
        InputObj := InputArr.ItemObject(i);
        if InputObj <> nil then
        try
          InputText := ExtractMessageContent(InputObj);
          AppendMessage(MsgRoleFromString(InputObj.GetStr('role', 'user')), InputText);
        finally
          InputObj.Free;
        end
        else
          AppendMessage(mrUser, InputArr.ItemStr(i, ''));
      end;
    finally
      InputArr.Free;
    end
    else
      AppendMessage(mrUser, Req.GetStr('input', ''));

    if MsgCount = 0 then
    begin
      WriteJSON(AResp, 400,
        '{"error":{"message":"missing or empty input","type":"invalid_request_error","param":"input"}}');
      Exit;
    end;

    if FProvider = nil then
    begin
      WriteJSON(AResp, 503,
        '{"error":{"message":"no provider configured","type":"server_error"}}');
      Exit;
    end;

    LoopCfg.Provider      := FProvider;
    LoopCfg.Registry      := FRegistry;
    LoopCfg.Model         := ReqModel;
    LoopCfg.MaxIterations := FMaxIter;
    LoopCfg.Options       := DefaultChatOptions;
    if not HasSystemMessage(Msgs) then
      LoopCfg.Options.SystemPrompt := BuildSystemPrompt(FCfg, '', LoopCfg.Registry <> nil);
    RawTemp := Req.GetFloat('temperature', 0);
    if RawTemp > 0 then LoopCfg.Options.Temperature := RawTemp;
    if Req.Has('max_output_tokens') then
      LoopCfg.Options.MaxTokens := Req.GetInt('max_output_tokens', LoopCfg.Options.MaxTokens)
    else if Req.Has('max_tokens') then
      LoopCfg.Options.MaxTokens := Req.GetInt('max_tokens', LoopCfg.Options.MaxTokens);
    LoopCfg.OnText        := nil;
    LoopCfg.OnToolCall    := nil;
    LoopCfg.OnToolResult  := nil;

    RespId := GenResponseId;

    if not RunToolLoop(LoopCfg, Msgs, Loop) then
    begin
      ReplyObj := BuildResponsesObject(RespId, ReqModel, 'failed', '', Loop.LastResp.Usage);
      try
        (* ResponseError schema is {code, message}. BuildResponsesObject
          set error: null on the success path; overwrite with the real
          shape here. SDK validators expect `code` to match a known
          enum, with `server_error` covering the "tool loop blew up
          server-side" case. *)
        ErrObj := TJsonObject.Create;
        ErrObj.PutStr('code',    'server_error');
        ErrObj.PutStr('message', 'tool loop failed');
        ReplyObj.PutObject('error', ErrObj);
        WriteJSON(AResp, 502, ReplyObj.ToJSON);
      finally
        ReplyObj.Free;
      end;
      Exit;
    end;

    if Loop.LastResp.FinishReason <> '' then
      FinishReason := Loop.LastResp.FinishReason
    else
      FinishReason := 'stop';

    if Length(Loop.LastResp.ToolCalls) > 0 then
    begin
      Loop.Content := Trim(Loop.Content);
      if Loop.Content <> '' then Loop.Content := Loop.Content + #10#10;
      Loop.Content := Loop.Content + Format(
        '(reached MaxIterations=%d while the model was still calling tools; '+
        'last finish_reason=%s, %d pending tool call(s) — raise the --max-iter '+
        'cap on `pasclaw serve` or reduce the task scope.)',
        [FMaxIter, FinishReason, Length(Loop.LastResp.ToolCalls)]);
      FinishReason := 'length';
      LogWarn('responses: tool loop hit MaxIterations=%d (%d pending tool call(s), %d content chars)',
              [FMaxIter, Length(Loop.LastResp.ToolCalls), Length(Loop.Content)]);
    end
    else if Loop.Content = '' then
    begin
      Loop.Content := Format('(no content returned by the model; finish_reason=%s)',
                              [FinishReason]);
      LogWarn('responses: empty content with finish=%s iterations=%d',
              [FinishReason, Loop.Iterations]);
    end;

    ReplyObj := BuildResponsesObject(RespId, ReqModel, 'completed', Loop.Content,
                                      Loop.LastResp.Usage);
    try
      if FDebugIO then LogDebug('responses -> 200 JSON: %s', [ReplyObj.ToJSON]);
      WriteJSON(AResp, 200, ReplyObj.ToJSON);
    finally
      ReplyObj.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure TGatewayServer.HandleModels(AResp: TIdHTTPResponseInfo);
{ OpenAI-compatible model list. Reports the default model only;
  enumerating every supported provider/model combination is a deeper
  change. A real one-model response is the contract most clients
  need to validate the endpoint. }
var
  Root, Item: TJsonObject;
  DataArr: TJsonArray;
  ModelId: string;
begin
  ModelId := FCfg.DefaultModel;
  if ModelId = '' then ModelId := 'pasclaw';

  Root := TJsonObject.Create;
  try
    Root.PutStr('object', 'list');
    DataArr := TJsonArray.Create;

    Item := TJsonObject.Create;
    Item.PutStr('id',       ModelId);
    Item.PutStr('object',   'model');
    Item.PutInt('created',  DateTimeToUnix(Now, False));
    Item.PutStr('owned_by', 'pasclaw');
    DataArr.AddObject(Item);

    Root.PutArray('data', DataArr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

end.
