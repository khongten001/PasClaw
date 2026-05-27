{
  PasClaw.MCP.StdioClient - spawns the configured MCP server command and
  speaks JSON-RPC 2.0 over its stdin/stdout pipes. Mirrors a thin slice of
  pkg/mcp/manager.go in picoclaw.

  Protocol flow:
    1. Spawn `cmd args...` with piped stdin/stdout.
    2. Send `initialize` request, receive server capabilities.
    3. Send `tools/list`, get the available tool descriptors.
    4. Optionally `tools/call` to invoke one.
    5. `shutdown` + close pipes; reap.

  Message framing: one JSON object per line (LSP-style "Content-Length"
  headers are also valid but most MCP servers default to newline-delimited
  JSON, which is what we implement here).
}
unit PasClaw.MCP.StdioClient;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes, Process,
  PasClaw.MCP.Types;

type
  TMCPStdioClient = class(TMCPBaseClient)
  private
    FProcess: TProcess;
    FCmd, FArgs, FName: string;
    FNextId:  Integer;
    FBuffer:  string;
    function  ReadLine(out Line: string; TimeoutMs: Integer): Boolean;
    function  WriteLine(const S: string): Boolean;
    function  RoundTrip(const Method, ParamsJSON: string;
                        TimeoutMs: Integer; out RespJSON: string): Boolean;
  public
    constructor Create(const Name, Cmd, Args: string);
    destructor  Destroy; override;

    function Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean; override;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean; override;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean; override;
    procedure Close;
  end;

implementation

uses
  fpjson, jsonparser,
  PasClaw.Logger;

constructor TMCPStdioClient.Create(const Name, Cmd, Args: string);
begin
  inherited Create;
  FName   := Name;
  FCmd    := Cmd;
  FArgs   := Args;
  FNextId := 1;
  FBuffer := '';
end;

destructor TMCPStdioClient.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TMCPStdioClient.Close;
begin
  if FProcess <> nil then
  begin
    try
      if FProcess.Running then
        FProcess.Terminate(0);
    except
      { ignore — we're tearing down }
    end;
    FreeAndNil(FProcess);
  end;
end;

function SplitArgs(const S: string): TStringList;
var
  i, last, n: Integer;
  inQuote: Boolean;
  qc: Char;
  cur: string;
begin
  Result := TStringList.Create;
  n := Length(S);
  cur := '';
  inQuote := False;
  qc := ' ';
  i := 1;
  last := 1;
  while i <= n do
  begin
    if inQuote then
    begin
      if S[i] = qc then inQuote := False
      else cur := cur + S[i];
    end
    else
    begin
      if (S[i] = '"') or (S[i] = '''') then
      begin
        inQuote := True;
        qc := S[i];
      end
      else if S[i] = ' ' then
      begin
        if cur <> '' then begin Result.Add(cur); cur := ''; end;
      end
      else
        cur := cur + S[i];
    end;
    Inc(i);
    Inc(last);
  end;
  if cur <> '' then Result.Add(cur);
end;

function TMCPStdioClient.WriteLine(const S: string): Boolean;
var
  Bytes: TBytes;
  Buf: string;
begin
  if (FProcess = nil) or not FProcess.Running then Exit(False);
  Buf := S + #10;
  try
    FProcess.Input.Write(Buf[1], Length(Buf));
    Result := True;
  except
    Result := False;
  end;
end;

function TMCPStdioClient.ReadLine(out Line: string; TimeoutMs: Integer): Boolean;
var
  Buf: array[0..4095] of Byte;
  N, Waited, NLPos: Integer;
  Chunk: string;
begin
  Line := '';
  Waited := 0;
  if FProcess = nil then Exit(False);
  while True do
  begin
    NLPos := Pos(#10, FBuffer);
    if NLPos > 0 then
    begin
      Line    := Copy(FBuffer, 1, NLPos - 1);
      FBuffer := Copy(FBuffer, NLPos + 1, MaxInt);
      Exit(True);
    end;
    if not FProcess.Running and (FProcess.Output.NumBytesAvailable = 0) then
      Exit(False);
    if FProcess.Output.NumBytesAvailable > 0 then
    begin
      N := FProcess.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Chunk, N);
        Move(Buf[0], Chunk[1], N);
        FBuffer := FBuffer + Chunk;
      end;
    end
    else
    begin
      Sleep(20);
      Inc(Waited, 20);
      if Waited >= TimeoutMs then Exit(False);
    end;
  end;
end;

function TMCPStdioClient.RoundTrip(const Method, ParamsJSON: string;
                                   TimeoutMs: Integer;
                                   out RespJSON: string): Boolean;
var
  Id: Integer;
  Req: TJSONObject;
  ParamsData: TJSONData;
  Line: string;
  RespRoot: TJSONData;
  RespObj: TJSONObject;
begin
  RespJSON := '';
  Id := FNextId; Inc(FNextId);

  Req := TJSONObject.Create;
  try
    Req.Add('jsonrpc', JSONRPCVersion);
    Req.Add('id', Id);
    Req.Add('method', Method);
    if ParamsJSON <> '' then
    begin
      try
        ParamsData := GetJSON(ParamsJSON);
        Req.Add('params', ParamsData);
      except
        Req.Add('params', TJSONObject.Create);
      end;
    end;
    if not WriteLine(Req.AsJSON) then Exit(False);
  finally
    Req.Free;
  end;

  while ReadLine(Line, TimeoutMs) do
  begin
    Line := Trim(Line);
    if Line = '' then Continue;
    LogDebug('mcp[%s] <- %s', [FName, Copy(Line, 1, 200)]);
    try
      RespRoot := GetJSON(Line);
    except
      Continue;
    end;
    try
      if not (RespRoot is TJSONObject) then Continue;
      RespObj := TJSONObject(RespRoot);
      { Skip notifications (no id) and responses to other requests. }
      if (RespObj.IndexOfName('id') < 0) or
         (RespObj.Integers['id'] <> Id) then Continue;
      RespJSON := Line;
      Exit(True);
    finally
      RespRoot.Free;
    end;
  end;
  Result := False;
end;

function TMCPStdioClient.Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean;
var
  ArgList: TStringList;
  i: Integer;
  Params, ServerCaps, ServerInfo: TJSONObject;
  Resp: string;
  RespData: TJSONData;
  RespObj, ResultObj: TJSONObject;
begin
  ErrMsg := '';
  if FCmd = '' then begin ErrMsg := 'no command configured'; Exit(False); end;

  FProcess := TProcess.Create(nil);
  FProcess.Executable := FCmd;
  ArgList := SplitArgs(FArgs);
  try
    for i := 0 to ArgList.Count - 1 do FProcess.Parameters.Add(ArgList[i]);
  finally
    ArgList.Free;
  end;
  FProcess.Options := [poUsePipes];
  try
    FProcess.Execute;
  except
    on E: Exception do
    begin
      ErrMsg := 'failed to spawn ' + FCmd + ': ' + E.Message;
      Exit(False);
    end;
  end;

  { initialize }
  Params := TJSONObject.Create;
  try
    Params.Add('protocolVersion', MCPProtocolVersion);
    ServerCaps := TJSONObject.Create;
    Params.Add('capabilities', ServerCaps);
    ServerInfo := TJSONObject.Create;
    ServerInfo.Add('name', 'pasclaw');
    ServerInfo.Add('version', '0.1');
    Params.Add('clientInfo', ServerInfo);
    if not RoundTrip('initialize', Params.AsJSON, TimeoutMs, Resp) then
    begin
      ErrMsg := 'no response to initialize from ' + FCmd;
      Exit(False);
    end;
  finally
    Params.Free;
  end;

  { Parse server info & capabilities out of the response. }
  RespData := GetJSON(Resp);
  try
    if RespData is TJSONObject then
    begin
      RespObj := TJSONObject(RespData);
      if RespObj.IndexOfName('error') >= 0 then
      begin
        ErrMsg := 'initialize error: ' + RespObj.Find('error').AsJSON;
        Exit(False);
      end;
      if RespObj.IndexOfName('result') >= 0 then
      begin
        ResultObj := RespObj.Objects['result'];
        if ResultObj.IndexOfName('serverInfo') >= 0 then
        begin
          FInfo.Name    := ResultObj.Objects['serverInfo'].Get('name', '');
          FInfo.Version := ResultObj.Objects['serverInfo'].Get('version', '');
        end;
        if ResultObj.IndexOfName('capabilities') >= 0 then
        begin
          FInfo.Caps.Tools     := ResultObj.Objects['capabilities'].IndexOfName('tools')     >= 0;
          FInfo.Caps.Resources := ResultObj.Objects['capabilities'].IndexOfName('resources') >= 0;
          FInfo.Caps.Prompts   := ResultObj.Objects['capabilities'].IndexOfName('prompts')   >= 0;
        end;
      end;
    end;
  finally
    RespData.Free;
  end;

  { Send "initialized" notification (no id, no response expected). }
  WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Result := True;
end;

function TMCPStdioClient.ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean;
var
  Resp: string;
  Data: TJSONData;
  Obj, ResultObj, ToolObj: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  ErrMsg := '';
  SetLength(Tools, 0);
  if not RoundTrip('tools/list', '{}', 5000, Resp) then
  begin
    ErrMsg := 'no response to tools/list';
    Exit(False);
  end;
  Data := GetJSON(Resp);
  try
    if not (Data is TJSONObject) then Exit(False);
    Obj := TJSONObject(Data);
    if Obj.IndexOfName('error') >= 0 then
    begin
      ErrMsg := 'tools/list error: ' + Obj.Find('error').AsJSON;
      Exit(False);
    end;
    if Obj.IndexOfName('result') < 0 then Exit(False);
    ResultObj := Obj.Objects['result'];
    if ResultObj.IndexOfName('tools') < 0 then Exit(True);   { server has none }
    Arr := ResultObj.Arrays['tools'];
    SetLength(Tools, Arr.Count);
    for i := 0 to Arr.Count - 1 do
    begin
      ToolObj := TJSONObject(Arr[i]);
      Tools[i].Name        := ToolObj.Get('name', '');
      Tools[i].Description := ToolObj.Get('description', '');
      if ToolObj.IndexOfName('inputSchema') >= 0 then
        Tools[i].Schema := ToolObj.Find('inputSchema').AsJSON
      else
        Tools[i].Schema := '{"type":"object"}';
      Tools[i].Server := FName;
    end;
  finally
    Data.Free;
  end;
  Result := True;
end;

function TMCPStdioClient.CallTool(const ToolName, ArgsJSON: string;
                                  out ResultText, ErrMsg: string): Boolean;
var
  Params: TJSONObject;
  ArgsData: TJSONData;
  Resp: string;
  Data: TJSONData;
  Obj, ResultObj, Block: TJSONObject;
  ContentArr: TJSONArray;
  i: Integer;
  Kind: string;
begin
  ResultText := '';
  ErrMsg := '';
  Params := TJSONObject.Create;
  try
    Params.Add('name', ToolName);
    if ArgsJSON <> '' then
    begin
      try
        ArgsData := GetJSON(ArgsJSON);
        Params.Add('arguments', ArgsData);
      except
        Params.Add('arguments', TJSONObject.Create);
      end;
    end
    else
      Params.Add('arguments', TJSONObject.Create);

    if not RoundTrip('tools/call', Params.AsJSON, 30000, Resp) then
    begin
      ErrMsg := 'no response to tools/call';
      Exit(False);
    end;
  finally
    Params.Free;
  end;

  Data := GetJSON(Resp);
  try
    if not (Data is TJSONObject) then Exit(False);
    Obj := TJSONObject(Data);
    if Obj.IndexOfName('error') >= 0 then
    begin
      ErrMsg := 'tools/call error: ' + Obj.Find('error').AsJSON;
      Exit(False);
    end;
    if Obj.IndexOfName('result') < 0 then Exit(False);
    ResultObj := Obj.Objects['result'];
    if ResultObj.IndexOfName('content') >= 0 then
    begin
      ContentArr := ResultObj.Arrays['content'];
      for i := 0 to ContentArr.Count - 1 do
      begin
        Block := TJSONObject(ContentArr[i]);
        Kind := Block.Get('type', '');
        if Kind = 'text' then
        begin
          if ResultText <> '' then ResultText := ResultText + sLineBreak;
          ResultText := ResultText + Block.Get('text', '');
        end;
      end;
    end;
    if (ResultText = '') and (ResultObj.IndexOfName('isError') >= 0) and
       (ResultObj.Booleans['isError']) then
      ErrMsg := 'tool reported error (no text content)';
  finally
    Data.Free;
  end;
  Result := ErrMsg = '';
end;

end.
