(*
  PasClaw.MCP.HttpClient - MCP over Streamable HTTP transport.

  Each call is a single POST to the configured URL with the JSON-RPC envelope.
  The same socket may be reused for the response stream (server-sent events)
  when the server elects to stream multi-part results — we handle both:

    * Content-Type: application/json  -> response is one JSON object
    * Content-Type: text/event-stream -> parse `data:` lines, join, decode

  Auth tokens come from the configured `args` slot in the MCP server entry,
  shaped as "--header Authorization: Bearer ..." or just "Bearer ...". The
  args field is space-separated; we sniff for an Authorization header.

  Spec: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
*)
unit PasClaw.MCP.HttpClient;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.MCP.Types;

type
  TMCPHttpClient = class
  private
    FName, FURL, FAuth: string;
    FNextId: Integer;
    FInfo:   TMCPServerInfo;
    function RoundTrip(const Method, ParamsJSON: string;
                       TimeoutSeconds: Integer; out RespJSON: string): Boolean;
  public
    constructor Create(const Name, URL, AuthHeader: string);
    function Connect(TimeoutSeconds: Integer; out ErrMsg: string): Boolean;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean;
    property ServerInfo: TMCPServerInfo read FInfo;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

constructor TMCPHttpClient.Create(const Name, URL, AuthHeader: string);
begin
  inherited Create;
  FName    := Name;
  FURL     := URL;
  FAuth    := AuthHeader;
  FNextId  := 1;
end;

(* Join all `data:` lines into one body (text/event-stream framing). *)
function CollapseSSE(const Body: string): string;
var
  L: TStringList;
  i: Integer;
  Line: string;
  Out_: TStringBuilder;
begin
  Result := '';
  if Pos('data:', Body) = 0 then
  begin
    Result := Body;
    Exit;
  end;
  L := TStringList.Create;
  Out_ := TStringBuilder.Create;
  try
    L.Text := Body;
    for i := 0 to L.Count - 1 do
    begin
      Line := L[i];
      if Copy(Line, 1, 5) = 'data:' then
      begin
        Line := Trim(Copy(Line, 6, MaxInt));
        if Line <> '' then Out_.Append(Line);
      end;
    end;
    Result := Out_.ToString;
  finally
    Out_.Free;
    L.Free;
  end;
end;

function TMCPHttpClient.RoundTrip(const Method, ParamsJSON: string;
                                  TimeoutSeconds: Integer;
                                  out RespJSON: string): Boolean;
var
  Req: TJsonObject;
  Body: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  HeaderCount: Integer;
begin
  RespJSON := '';
  Req := TJsonObject.Create;
  try
    Req.PutStr('jsonrpc', JSONRPCVersion);
    Req.PutInt('id', FNextId);
    Inc(FNextId);
    Req.PutStr('method', Method);
    if ParamsJSON <> '' then Req.PutRaw('params', ParamsJSON);
    Body := Req.ToJSON;
  finally
    Req.Free;
  end;

  HeaderCount := 0;
  if FAuth <> '' then HeaderCount := 1;
  SetLength(Headers, HeaderCount + 1);
  Headers[0] := MakeHeader('Accept', 'application/json, text/event-stream');
  if HeaderCount = 1 then
    Headers[1] := MakeHeader('Authorization', FAuth);

  Resp := PostJSON(FURL, Body, Headers, TimeoutSeconds);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    LogWarn('mcp-http[%s] status=%d body=%s',
            [FName, Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit(False);
  end;
  RespJSON := CollapseSSE(Resp.Body);
  Result := RespJSON <> '';
end;

function TMCPHttpClient.Connect(TimeoutSeconds: Integer; out ErrMsg: string): Boolean;
var
  Params, ServerInfo: TJsonObject;
  Caps: TJsonObject;
  Resp: string;
  RespObj, ResultObj: TJsonObject;
  ServerInfoObj, CapsObj: TJsonObject;
begin
  ErrMsg := '';
  Params     := TJsonObject.Create;
  ServerInfo := TJsonObject.Create;
  Caps       := TJsonObject.Create;
  try
    Params.PutStr('protocolVersion', MCPProtocolVersion);
    ServerInfo.PutStr('name',    'pasclaw');
    ServerInfo.PutStr('version', '0.1');
    Params.PutObject('clientInfo', ServerInfo);
    Params.PutObject('capabilities', Caps);
    if not RoundTrip('initialize', Params.ToJSON, TimeoutSeconds, Resp) then
    begin
      ErrMsg := 'initialize failed';
      Exit(False);
    end;
  finally
    Params.Free;
    if ServerInfo <> nil then ServerInfo.Free;
    if Caps <> nil then Caps.Free;
  end;

  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then begin ErrMsg := 'bad initialize response'; Exit(False); end;
  try
    if RespObj.Has('error') then
    begin
      ErrMsg := 'initialize error';
      Exit(False);
    end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj = nil then begin ErrMsg := 'no result'; Exit(False); end;
    try
      ServerInfoObj := ResultObj.ChildObject('serverInfo');
      if ServerInfoObj <> nil then
      try
        FInfo.Name    := ServerInfoObj.GetStr('name', '');
        FInfo.Version := ServerInfoObj.GetStr('version', '');
      finally
        ServerInfoObj.Free;
      end;
      CapsObj := ResultObj.ChildObject('capabilities');
      if CapsObj <> nil then
      try
        FInfo.Caps.Tools     := CapsObj.Has('tools');
        FInfo.Caps.Resources := CapsObj.Has('resources');
        FInfo.Caps.Prompts   := CapsObj.Has('prompts');
      finally
        CapsObj.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;
  Result := True;
end;

function TMCPHttpClient.ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean;
var
  Resp: string;
  RespObj, ResultObj, ToolObj: TJsonObject;
  Arr: TJsonArray;
  Schema: TJsonObject;
  i: Integer;
begin
  ErrMsg := '';
  SetLength(Tools, 0);
  if not RoundTrip('tools/list', '{}', 10, Resp) then
  begin
    ErrMsg := 'tools/list failed';
    Exit(False);
  end;
  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then Exit(False);
  try
    if RespObj.Has('error') then begin ErrMsg := 'tools/list error'; Exit(False); end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj = nil then Exit(True);
    try
      Arr := ResultObj.ChildArray('tools');
      if Arr = nil then Exit(True);
      try
        SetLength(Tools, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          ToolObj := Arr.ItemObject(i);
          if ToolObj = nil then Continue;
          try
            Tools[i].Name        := ToolObj.GetStr('name', '');
            Tools[i].Description := ToolObj.GetStr('description', '');
            Schema := ToolObj.ChildObject('inputSchema');
            if Schema <> nil then
            try
              Tools[i].Schema := Schema.ToJSON;
            finally
              Schema.Free;
            end
            else
              Tools[i].Schema := '{"type":"object"}';
            Tools[i].Server := FName;
          finally
            ToolObj.Free;
          end;
        end;
      finally
        Arr.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;
  Result := True;
end;

function TMCPHttpClient.CallTool(const ToolName, ArgsJSON: string;
                                 out ResultText, ErrMsg: string): Boolean;
var
  Params: TJsonObject;
  Resp: string;
  RespObj, ResultObj, Block: TJsonObject;
  ContentArr: TJsonArray;
  i: Integer;
begin
  ResultText := '';
  ErrMsg := '';
  Params := TJsonObject.Create;
  try
    Params.PutStr('name', ToolName);
    if ArgsJSON <> '' then Params.PutRaw('arguments', ArgsJSON)
    else Params.PutRaw('arguments', '{}');
    if not RoundTrip('tools/call', Params.ToJSON, 60, Resp) then
    begin
      ErrMsg := 'tools/call failed';
      Exit(False);
    end;
  finally
    Params.Free;
  end;
  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then Exit(False);
  try
    if RespObj.Has('error') then begin ErrMsg := 'tools/call error'; Exit(False); end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj = nil then Exit(False);
    try
      ContentArr := ResultObj.ChildArray('content');
      if ContentArr <> nil then
      try
        for i := 0 to ContentArr.Count - 1 do
        begin
          Block := ContentArr.ItemObject(i);
          if Block = nil then Continue;
          try
            if Block.GetStr('type', '') = 'text' then
            begin
              if ResultText <> '' then ResultText := ResultText + sLineBreak;
              ResultText := ResultText + Block.GetStr('text', '');
            end;
          finally
            Block.Free;
          end;
        end;
      finally
        ContentArr.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;
  Result := True;
end;

end.
