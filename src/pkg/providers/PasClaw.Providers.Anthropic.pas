{
  PasClaw.Providers.Anthropic - Anthropic Messages API client.
  Mirrors pkg/providers/anthropic_messages in picoclaw.

  Endpoint: POST <api_base>/v1/messages
  Auth:     x-api-key: <key>, anthropic-version: 2023-06-01
}
unit PasClaw.Providers.Anthropic;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
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

{ Exposed so tests + embedders can render the wire body without
  hitting the network. Pure function; doesn't depend on the provider
  instance. Same code path Chat / ChatStream execute. }
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions): string;

implementation

uses
  PasClaw.JSON,
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

(* Build a fresh ephemeral cache_control object (with optional
   ttl="1h") for attaching to a content block / tool entry. Caller
   takes ownership via PutObject. The TTL field is optional —
   Anthropic's default cache TTL is 5 minutes and we pass that
   through implicitly by omitting the field; only "1h" (extended
   TTL beta) is recognised and emitted. *)
function MakeCacheControl(const TTL: string): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('type', 'ephemeral');
  if TTL = '1h' then Result.PutStr('ttl', '1h');
end;

function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions): string;
var
  Root, Block, ToolObj, Thinking, Msg, EmptyInput, SysBlock, CC: TJsonObject;
  MsgArr, ToolArr, ContentArr, SysArr: TJsonArray;
  i, j: Integer;
  Sys: string;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('model',      Model);
    Root.PutInt('max_tokens', Options.MaxTokens);
    if Options.Temperature > 0 then Root.PutFloat('temperature', Options.Temperature);

    { System prompt: prefer Options.SystemPrompt, else first system message. }
    Sys := Options.SystemPrompt;
    for i := 0 to High(Messages) do
      if (Messages[i].Role = mrSystem) and (Sys = '') then
        Sys := Messages[i].Content;
    if Sys <> '' then
    begin
      if Options.CacheEnabled then
      begin
        (* Block form is required to attach cache_control. Anthropic
           accepts system as either a plain string or an array of
           text blocks (each with optional cache_control). Tagging
           the system prompt caches everything up to the tools array
           on the next turn — biggest single-breakpoint win for
           multi-turn chats. *)
        SysArr   := TJsonArray.Create;
        SysBlock := TJsonObject.Create;
        SysBlock.PutStr('type', 'text');
        SysBlock.PutStr('text', Sys);
        CC := MakeCacheControl(Options.CacheTTL);
        SysBlock.PutObject('cache_control', CC);
        SysArr.AddObject(SysBlock);
        Root.PutArray('system', SysArr);
      end
      else
        Root.PutStr('system', Sys);
    end;

    if Options.ThinkingLevel <> '' then
    begin
      Thinking := TJsonObject.Create;
      Thinking.PutStr('type', 'enabled');
      if      Options.ThinkingLevel = 'low'  then Thinking.PutInt('budget_tokens', 1024)
      else if Options.ThinkingLevel = 'high' then Thinking.PutInt('budget_tokens', 8192)
      else                                        Thinking.PutInt('budget_tokens', 2048);
      Root.PutObject('thinking', Thinking);
    end;

    MsgArr := TJsonArray.Create;
    for i := 0 to High(Messages) do
    begin
      if Messages[i].Role = mrSystem then Continue;
      Msg := TJsonObject.Create;
      Msg.PutStr('role', RoleForAnthropic(Messages[i].Role));
      ContentArr := TJsonArray.Create;
      if Messages[i].Role = mrTool then
      begin
        Block := TJsonObject.Create;
        Block.PutStr('type',        'tool_result');
        Block.PutStr('tool_use_id', Messages[i].ToolCallId);
        Block.PutStr('content',     Messages[i].Content);
        ContentArr.AddObject(Block);
      end
      else if Length(Messages[i].ToolCalls) > 0 then
      begin
        if Messages[i].Content <> '' then
        begin
          Block := TJsonObject.Create;
          Block.PutStr('type', 'text');
          Block.PutStr('text', Messages[i].Content);
          ContentArr.AddObject(Block);
        end;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          Block := TJsonObject.Create;
          Block.PutStr('type', 'tool_use');
          Block.PutStr('id',   Messages[i].ToolCalls[j].Id);
          Block.PutStr('name', Messages[i].ToolCalls[j].Func.Name);
          if Messages[i].ToolCalls[j].Func.Arguments <> '' then
            Block.PutRaw('input', Messages[i].ToolCalls[j].Func.Arguments)
          else
          begin
            EmptyInput := TJsonObject.Create;
            Block.PutObject('input', EmptyInput);
          end;
          ContentArr.AddObject(Block);
        end;
      end
      else
      begin
        Block := TJsonObject.Create;
        Block.PutStr('type', 'text');
        Block.PutStr('text', Messages[i].Content);
        ContentArr.AddObject(Block);
      end;
      Msg.PutArray('content', ContentArr);
      MsgArr.AddObject(Msg);
    end;
    Root.PutArray('messages', MsgArr);

    if Length(Tools) > 0 then
    begin
      ToolArr := TJsonArray.Create;
      for i := 0 to High(Tools) do
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('name', Tools[i].Name);
        if Tools[i].Description <> '' then ToolObj.PutStr('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
          ToolObj.PutRaw('input_schema', Tools[i].Schema)
        else
        begin
          EmptyInput := TJsonObject.Create;
          ToolObj.PutObject('input_schema', EmptyInput);
        end;
        { Tag the LAST tool entry with cache_control — Anthropic
          caches up to and including the tagged block, so a single
          breakpoint on the trailing tool covers the entire tools
          array as a stable prefix. Combined with the system-prompt
          breakpoint above we use 2 of Anthropic's 4-breakpoint
          budget; the remaining two are reserved for compaction
          summaries or higher-layer hints later. }
        if Options.CacheEnabled and (i = High(Tools)) then
        begin
          CC := MakeCacheControl(Options.CacheTTL);
          ToolObj.PutObject('cache_control', CC);
        end;
        ToolArr.AddObject(ToolObj);
      end;
      Root.PutArray('tools', ToolArr);

      (* tool_choice mapping (Anthropic Messages API):
          "auto"     -> {"type":"auto"}     (model decides; Anthropic default)
          "required" -> {"type":"any"}      (must call one of the tools)
          "none"     -> {"type":"none"}     (must not call any tool; needed
                                              because omitting the field with
                                              a non-empty tools array still
                                              lets the model call them)
        Empty string means "don't emit; let provider default apply". *)
      if (Options.ToolChoice = 'auto')
         or (Options.ToolChoice = 'required')
         or (Options.ToolChoice = 'none') then
      begin
        ToolObj := TJsonObject.Create;
        if Options.ToolChoice = 'auto' then
          ToolObj.PutStr('type', 'auto')
        else if Options.ToolChoice = 'required' then
          ToolObj.PutStr('type', 'any')
        else
          ToolObj.PutStr('type', 'none');
        Root.PutObject('tool_choice', ToolObj);
      end;
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure ParseResponse(const Body: string; var Resp: TLLMResponse);
var
  Obj, Block, Usage, InputObj: TJsonObject;
  Arr: TJsonArray;
  InputArr: TJsonArray;
  i: Integer;
  Kind, Text: string;
  TC: TToolCall;
begin
  Resp.Content := '';
  Resp.FinishReason := '';
  Resp.Model := '';
  Resp.Usage.InputTokens := 0;
  Resp.Usage.OutputTokens := 0;
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Resp.Model        := Obj.GetStr('model',       '');
    Resp.FinishReason := Obj.GetStr('stop_reason', '');
    Arr := Obj.ChildArray('content');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Block := Arr.ItemObject(i);
        if Block = nil then Continue;
        try
          Kind := Block.GetStr('type', '');
          if Kind = 'text' then
          begin
            Text := Block.GetStr('text', '');
            if Resp.Content <> '' then Resp.Content := Resp.Content + sLineBreak;
            Resp.Content := Resp.Content + Text;
          end
          else if Kind = 'tool_use' then
          begin
            TC.Id        := Block.GetStr('id',   '');
            TC.Kind      := 'function';
            TC.Func.Name := Block.GetStr('name', '');
            InputObj := Block.ChildObject('input');
            if InputObj <> nil then
            try
              TC.Func.Arguments := InputObj.ToJSON;
            finally
              InputObj.Free;
            end
            else
            begin
              InputArr := Block.ChildArray('input');
              if InputArr <> nil then
              try
                TC.Func.Arguments := InputArr.ToJSON;
              finally
                InputArr.Free;
              end
              else
                TC.Func.Arguments := '{}';
            end;
            SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
            Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
          end;
        finally
          Block.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Usage := Obj.ChildObject('usage');
    if Usage <> nil then
    try
      Resp.Usage.InputTokens        := Usage.GetInt('input_tokens',  0);
      Resp.Usage.OutputTokens       := Usage.GetInt('output_tokens', 0);
      Resp.Usage.CacheReadTokens    := Usage.GetInt('cache_read_input_tokens',     0);
      Resp.Usage.CacheCreatedTokens := Usage.GetInt('cache_creation_input_tokens', 0);
    finally
      Usage.Free;
    end;
  finally
    Obj.Free;
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
  Result.StatusCode := Resp.StatusCode;
  SetLength(Result.ToolCalls, 0);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    ParseResponse(Resp.Body, Result);
    Exit;
  end;

  if Resp.Body <> '' then
    Result.Content := Format('anthropic error %d: %s', [Resp.StatusCode, Resp.Body])
  else
    Result.Content := Format('anthropic error: status=%d msg=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result.FinishReason := 'error';
end;

var
  GStreamCB:   TStreamCallback;
  GStreamAcc:  string;
  GStreamLast: TLLMResponse;
  { Tool-use accumulation across content_block_start / _delta / _stop.
    Anthropic streams tool_use blocks as: start carries id+name+(empty)
    input, delta carries partial_json fragments, stop signals end. We
    buffer the JSON and flush into GStreamLast.ToolCalls on stop so
    the streaming path matches Chat()'s non-streaming behavior — without
    this, tool-call-only assistant turns reached the gateway with no
    ToolCalls and Codex never saw its function_call output items. }
  GToolBlockActive: Boolean;
  GToolBlockId:     string;
  GToolBlockName:   string;
  GToolBlockArgs:   string;

procedure HandleAnthropicSSE(const Event, Data: string);
var
  Root, Delta, Usage, MsgObj, CB: TJsonObject;
  Kind, Text, BlockKind, PartialJson: string;
  Chunk: TStreamChunk;
  Tc: TToolCall;
begin
  if Data = '' then Exit;
  Root := TJsonObject.Parse(Data);
  if Root = nil then Exit;
  try
    Kind := Root.GetStr('type', Event);

    if Kind = 'content_block_start' then
    begin
      CB := Root.ChildObject('content_block');
      if CB <> nil then
      try
        BlockKind := CB.GetStr('type', '');
        if BlockKind = 'tool_use' then
        begin
          GToolBlockActive := True;
          GToolBlockId     := CB.GetStr('id',   '');
          GToolBlockName   := CB.GetStr('name', '');
          GToolBlockArgs   := '';
        end;
      finally
        CB.Free;
      end;
    end
    else if Kind = 'content_block_delta' then
    begin
      Delta := Root.ChildObject('delta');
      if Delta = nil then Exit;
      try
        if Delta.GetStr('type', '') = 'text_delta' then
        begin
          Text := Delta.GetStr('text', '');
          if Text <> '' then
          begin
            GStreamAcc := GStreamAcc + Text;
            Chunk.Kind := 'text';
            Chunk.Text := Text;
            if Assigned(GStreamCB) then GStreamCB(Chunk);
          end;
        end
        else if (Delta.GetStr('type', '') = 'input_json_delta') and GToolBlockActive then
        begin
          PartialJson := Delta.GetStr('partial_json', '');
          if PartialJson <> '' then
            GToolBlockArgs := GToolBlockArgs + PartialJson;
        end;
      finally
        Delta.Free;
      end;
    end
    else if Kind = 'content_block_stop' then
    begin
      if GToolBlockActive then
      begin
        Tc.Id   := GToolBlockId;
        Tc.Kind := 'function';
        Tc.Func.Name := GToolBlockName;
        if Trim(GToolBlockArgs) <> '' then
          Tc.Func.Arguments := GToolBlockArgs
        else
          Tc.Func.Arguments := '{}';
        SetLength(GStreamLast.ToolCalls, Length(GStreamLast.ToolCalls) + 1);
        GStreamLast.ToolCalls[High(GStreamLast.ToolCalls)] := Tc;
        GToolBlockActive := False;
        GToolBlockId     := '';
        GToolBlockName   := '';
        GToolBlockArgs   := '';
      end;
    end
    else if Kind = 'message_delta' then
    begin
      Usage := Root.ChildObject('usage');
      if Usage <> nil then
      try
        GStreamLast.Usage.OutputTokens :=
          Usage.GetInt('output_tokens', GStreamLast.Usage.OutputTokens);
      finally
        Usage.Free;
      end;
      Delta := Root.ChildObject('delta');
      if Delta <> nil then
      try
        GStreamLast.FinishReason :=
          Delta.GetStr('stop_reason', GStreamLast.FinishReason);
      finally
        Delta.Free;
      end;
    end
    else if Kind = 'message_start' then
    begin
      MsgObj := Root.ChildObject('message');
      if MsgObj <> nil then
      try
        GStreamLast.Model := MsgObj.GetStr('model', GStreamLast.Model);
        Usage := MsgObj.ChildObject('usage');
        if Usage <> nil then
        try
          GStreamLast.Usage.InputTokens := Usage.GetInt('input_tokens', 0);
        finally
          Usage.Free;
        end;
      finally
        MsgObj.Free;
      end;
    end
    else if Kind = 'message_stop' then
    begin
      Chunk.Kind := 'done';
      Chunk.Text := '';
      if Assigned(GStreamCB) then GStreamCB(Chunk);
    end;
  finally
    Root.Free;
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
  Root: TJsonObject;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL := FAPIBase + '/v1/messages';

  { Force stream:true in the request body. }
  Opts := Options;
  Opts.Stream := True;
  Body := BuildRequest(Messages, Tools, UseModel, Opts);
  Root := TJsonObject.Parse(Body);
  if Root = nil then
  begin
    Result := Chat(Messages, Tools, UseModel, Options);
    Exit;
  end;
  try
    Root.PutBool('stream', True);
    Body := Root.ToJSON;
  finally
    Root.Free;
  end;

  SetLength(Headers, 2);
  Headers[0] := MakeHeader('x-api-key',         FAPIKey);
  Headers[1] := MakeHeader('anthropic-version', '2023-06-01');

  GStreamCB  := OnChunk;
  GStreamAcc := '';
  Finalize(GStreamLast);
  FillChar(GStreamLast, SizeOf(GStreamLast), 0);
  GStreamLast.Model := UseModel;
  GToolBlockActive := False;
  GToolBlockId     := '';
  GToolBlockName   := '';
  GToolBlockArgs   := '';
  try
    LogDebug('anthropic SSE POST %s (model=%s)', [URL, UseModel]);
    PostStreaming(URL, Body, Headers, 120, @HandleAnthropicSSE, Status, Err);
    Result.Content      := GStreamAcc;
    Result.FinishReason := GStreamLast.FinishReason;
    Result.Usage        := GStreamLast.Usage;
    Result.Model        := GStreamLast.Model;
    Result.ToolCalls    := Copy(GStreamLast.ToolCalls, 0, Length(GStreamLast.ToolCalls));
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
