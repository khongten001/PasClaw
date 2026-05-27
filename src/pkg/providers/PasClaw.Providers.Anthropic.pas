{
  PasClaw.Providers.Anthropic - Anthropic Messages API client.
  Mirrors pkg/providers/anthropic_messages in picoclaw.

  Endpoint: POST <api_base>/v1/messages
  Auth:     x-api-key: <key>, anthropic-version: 2023-06-01
}
unit PasClaw.Providers.Anthropic;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TAnthropicProvider = class(TInterfacedObject, ILLMProvider)
  private
    FAPIKey:  string;
    FAPIBase: string;
    FDefaultModel: string;
  public
    constructor Create(const APIKey, APIBase, DefaultModel: string);
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

implementation

uses
  fpjson, jsonparser,
  PasClaw.Providers.HTTP,
  PasClaw.Providers.Stream,
  PasClaw.Logger;

constructor TAnthropicProvider.Create(const APIKey, APIBase, DefaultModel: string);
begin
  inherited Create;
  FAPIKey := APIKey;
  if APIBase <> '' then FAPIBase := APIBase else FAPIBase := 'https://api.anthropic.com';
  if DefaultModel <> '' then FDefaultModel := DefaultModel else FDefaultModel := 'claude-opus-4-7';
end;

function TAnthropicProvider.GetDefaultModel: string;
begin
  Result := FDefaultModel;
end;

function TAnthropicProvider.GetName: string;
begin
  Result := 'anthropic';
end;

function TAnthropicProvider.SupportsThinking: Boolean;
begin
  Result := True;
end;

function TAnthropicProvider.SupportsNativeSearch: Boolean;
begin
  Result := False;
end;

function TAnthropicProvider.SupportsStreaming: Boolean;
begin
  Result := True;
end;

function RoleForAnthropic(R: TMsgRole): string;
begin
  case R of
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'user';   { tool result is delivered as user turn with tool_result content }
  else           Result := 'user';
  end;
end;

function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions): string;
var
  Root: TJSONObject;
  MsgArr, ToolArr, ContentArr: TJSONArray;
  Msg, Block, ToolObj: TJSONObject;
  i, j: Integer;
  Sys: string;
  ToolSchema: TJSONData;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('model', Model);
    Root.Add('max_tokens', Options.MaxTokens);
    if Options.Temperature > 0 then Root.Add('temperature', Options.Temperature);

    { System prompt: prefer Options.SystemPrompt, else first system message. }
    Sys := Options.SystemPrompt;
    for i := 0 to High(Messages) do
      if (Messages[i].Role = mrSystem) and (Sys = '') then
        Sys := Messages[i].Content;
    if Sys <> '' then Root.Add('system', Sys);

    if Options.ThinkingLevel <> '' then
    begin
      Block := TJSONObject.Create;
      Block.Add('type', 'enabled');
      if Options.ThinkingLevel = 'low'    then Block.Add('budget_tokens', 1024)
      else if Options.ThinkingLevel = 'high' then Block.Add('budget_tokens', 8192)
      else Block.Add('budget_tokens', 2048);
      Root.Add('thinking', Block);
    end;

    MsgArr := TJSONArray.Create;
    for i := 0 to High(Messages) do
    begin
      if Messages[i].Role = mrSystem then Continue;
      Msg := TJSONObject.Create;
      Msg.Add('role', RoleForAnthropic(Messages[i].Role));
      ContentArr := TJSONArray.Create;
      if Messages[i].Role = mrTool then
      begin
        Block := TJSONObject.Create;
        Block.Add('type', 'tool_result');
        Block.Add('tool_use_id', Messages[i].ToolCallId);
        Block.Add('content', Messages[i].Content);
        ContentArr.Add(Block);
      end
      else if Length(Messages[i].ToolCalls) > 0 then
      begin
        if Messages[i].Content <> '' then
        begin
          Block := TJSONObject.Create;
          Block.Add('type', 'text');
          Block.Add('text', Messages[i].Content);
          ContentArr.Add(Block);
        end;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          Block := TJSONObject.Create;
          Block.Add('type', 'tool_use');
          Block.Add('id',    Messages[i].ToolCalls[j].Id);
          Block.Add('name',  Messages[i].ToolCalls[j].Func.Name);
          if Messages[i].ToolCalls[j].Func.Arguments <> '' then
          begin
            try
              Block.Add('input', GetJSON(Messages[i].ToolCalls[j].Func.Arguments));
            except
              Block.Add('input', TJSONObject.Create);
            end;
          end
          else
            Block.Add('input', TJSONObject.Create);
          ContentArr.Add(Block);
        end;
      end
      else
      begin
        Block := TJSONObject.Create;
        Block.Add('type', 'text');
        Block.Add('text', Messages[i].Content);
        ContentArr.Add(Block);
      end;
      Msg.Add('content', ContentArr);
      MsgArr.Add(Msg);
    end;
    Root.Add('messages', MsgArr);

    if Length(Tools) > 0 then
    begin
      ToolArr := TJSONArray.Create;
      for i := 0 to High(Tools) do
      begin
        ToolObj := TJSONObject.Create;
        ToolObj.Add('name', Tools[i].Name);
        if Tools[i].Description <> '' then ToolObj.Add('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
        begin
          try
            ToolSchema := GetJSON(Tools[i].Schema);
            ToolObj.Add('input_schema', ToolSchema);
          except
            ToolObj.Add('input_schema', TJSONObject.Create);
          end;
        end
        else
          ToolObj.Add('input_schema', TJSONObject.Create);
        ToolArr.Add(ToolObj);
      end;
      Root.Add('tools', ToolArr);
    end;

    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

procedure ParseResponse(const Body: string; var Resp: TLLMResponse);
var
  Root: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  Block: TJSONObject;
  Kind, Text: string;
  TC: TToolCall;
  Usage: TJSONObject;
  Input: TJSONData;
begin
  Resp.Content := '';
  Resp.FinishReason := '';
  Resp.Model := '';
  Resp.Usage.InputTokens := 0;
  Resp.Usage.OutputTokens := 0;
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Root := GetJSON(Body);
  if not (Root is TJSONObject) then begin Root.Free; Exit; end;
  Obj := TJSONObject(Root);
  try
    Resp.Model        := Obj.Get('model', '');
    Resp.FinishReason := Obj.Get('stop_reason', '');
    if Obj.IndexOfName('content') >= 0 then
    begin
      Arr := Obj.Arrays['content'];
      for i := 0 to Arr.Count - 1 do
      begin
        Block := TJSONObject(Arr[i]);
        Kind := Block.Get('type', '');
        if Kind = 'text' then
        begin
          Text := Block.Get('text', '');
          if Resp.Content <> '' then Resp.Content := Resp.Content + sLineBreak;
          Resp.Content := Resp.Content + Text;
        end
        else if Kind = 'tool_use' then
        begin
          TC.Id        := Block.Get('id', '');
          TC.Kind      := 'function';
          TC.Func.Name := Block.Get('name', '');
          if Block.IndexOfName('input') >= 0 then
          begin
            Input := Block.Find('input');
            if Input <> nil then TC.Func.Arguments := Input.AsJSON
            else TC.Func.Arguments := '{}';
          end
          else
            TC.Func.Arguments := '{}';
          SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
          Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
        end;
      end;
    end;
    if Obj.IndexOfName('usage') >= 0 then
    begin
      Usage := Obj.Objects['usage'];
      Resp.Usage.InputTokens        := Usage.Get('input_tokens',  0);
      Resp.Usage.OutputTokens       := Usage.Get('output_tokens', 0);
      Resp.Usage.CacheReadTokens    := Usage.Get('cache_read_input_tokens', 0);
      Resp.Usage.CacheCreatedTokens := Usage.Get('cache_creation_input_tokens', 0);
    end;
  finally
    Root.Free;
  end;
end;

function TAnthropicProvider.Chat(const Messages: array of TMessage;
                                 const Tools:    array of TToolDefinition;
                                 const Model:    string;
                                 const Options:  TChatOptions): TLLMResponse;
var
  Body, URL, UseModel: string;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
  ErrJSON: TJSONData;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL  := FAPIBase + '/v1/messages';
  Body := BuildRequest(Messages, Tools, UseModel, Options);

  SetLength(Headers, 2);
  Headers[0] := MakeHeader('x-api-key',          FAPIKey);
  Headers[1] := MakeHeader('anthropic-version', '2023-06-01');

  LogDebug('anthropic POST %s (model=%s, body=%d bytes)', [URL, UseModel, Length(Body)]);
  Resp := PostJSON(URL, Body, Headers, 120);

  Result.Content := '';
  SetLength(Result.ToolCalls, 0);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    ParseResponse(Resp.Body, Result);
    Exit;
  end;

  { Surface API error message rather than swallowing it. }
  if Resp.Body <> '' then
  begin
    try
      ErrJSON := GetJSON(Resp.Body);
      try
        Result.Content := Format('anthropic error %d: %s', [Resp.StatusCode, ErrJSON.AsJSON]);
      finally
        ErrJSON.Free;
      end;
    except
      Result.Content := Format('anthropic error %d: %s', [Resp.StatusCode, Resp.Body]);
    end;
  end
  else
    Result.Content := Format('anthropic error: status=%d msg=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result.FinishReason := 'error';
end;

var
  GStreamCB:   TStreamCallback;
  GStreamAcc:  string;
  GStreamLast: TLLMResponse;

procedure HandleAnthropicSSE(const Event, Data: string);
var
  Obj: TJSONData;
  Root, Delta, Usage: TJSONObject;
  Kind, Text: string;
  Chunk: TStreamChunk;
begin
  if Data = '' then Exit;
  try
    Obj := GetJSON(Data);
  except
    Exit;
  end;
  try
    if not (Obj is TJSONObject) then Exit;
    Root := TJSONObject(Obj);
    Kind := Root.Get('type', Event);

    if Kind = 'content_block_delta' then
    begin
      if Root.IndexOfName('delta') < 0 then Exit;
      Delta := Root.Objects['delta'];
      if Delta.Get('type', '') = 'text_delta' then
      begin
        Text := Delta.Get('text', '');
        if Text <> '' then
        begin
          GStreamAcc := GStreamAcc + Text;
          Chunk.Kind := 'text';
          Chunk.Text := Text;
          if Assigned(GStreamCB) then GStreamCB(Chunk);
        end;
      end;
    end
    else if Kind = 'message_delta' then
    begin
      if Root.IndexOfName('usage') >= 0 then
      begin
        Usage := Root.Objects['usage'];
        GStreamLast.Usage.OutputTokens := Usage.Get('output_tokens', GStreamLast.Usage.OutputTokens);
      end;
      if Root.IndexOfName('delta') >= 0 then
      begin
        Delta := Root.Objects['delta'];
        GStreamLast.FinishReason := Delta.Get('stop_reason', GStreamLast.FinishReason);
      end;
    end
    else if Kind = 'message_start' then
    begin
      if Root.IndexOfName('message') >= 0 then
      begin
        Delta := Root.Objects['message'];
        GStreamLast.Model := Delta.Get('model', GStreamLast.Model);
        if Delta.IndexOfName('usage') >= 0 then
        begin
          Usage := Delta.Objects['usage'];
          GStreamLast.Usage.InputTokens := Usage.Get('input_tokens', 0);
        end;
      end;
    end
    else if Kind = 'message_stop' then
    begin
      Chunk.Kind := 'done';
      Chunk.Text := '';
      if Assigned(GStreamCB) then GStreamCB(Chunk);
    end;
  finally
    Obj.Free;
  end;
end;

function TAnthropicProvider.ChatStream(const Messages: array of TMessage;
                                       const Tools:    array of TToolDefinition;
                                       const Model:    string;
                                       const Options:  TChatOptions;
                                       OnChunk: TStreamCallback): TLLMResponse;
var
  Body, URL, UseModel: string;
  Headers: array of THeaderPair;
  Opts: TChatOptions;
  Status: Integer;
  Err: string;
  Root: TJSONObject;
  Stream: TJSONBoolean;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL := FAPIBase + '/v1/messages';

  { Force stream:true in the request body. }
  Opts := Options;
  Opts.Stream := True;
  Body := BuildRequest(Messages, Tools, UseModel, Opts);
  try
    Root := TJSONObject(GetJSON(Body));
    try
      Stream := TJSONBoolean.Create(True);
      Root.Add('stream', Stream);
      Body := Root.AsJSON;
    finally
      Root.Free;
    end;
  except
    { fall back to non-stream }
    Result := Chat(Messages, Tools, UseModel, Options);
    Exit;
  end;

  SetLength(Headers, 2);
  Headers[0] := MakeHeader('x-api-key',         FAPIKey);
  Headers[1] := MakeHeader('anthropic-version', '2023-06-01');

  GStreamCB  := OnChunk;
  GStreamAcc := '';
  FillChar(GStreamLast, SizeOf(GStreamLast), 0);
  GStreamLast.Model := UseModel;
  try
    LogDebug('anthropic SSE POST %s (model=%s)', [URL, UseModel]);
    PostStreaming(URL, Body, Headers, 120, @HandleAnthropicSSE, Status, Err);
    Result.Content      := GStreamAcc;
    Result.FinishReason := GStreamLast.FinishReason;
    Result.Usage        := GStreamLast.Usage;
    Result.Model        := GStreamLast.Model;
    if (Status < 200) or (Status >= 300) then
    begin
      if Result.Content = '' then
        Result.Content := Format('anthropic stream error: status=%d msg=%s', [Status, Err]);
      Result.FinishReason := 'error';
    end;
  finally
    GStreamCB := nil;
  end;
end;

end.
