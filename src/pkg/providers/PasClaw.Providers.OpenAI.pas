{
  PasClaw.Providers.OpenAI - OpenAI Chat Completions client (also handles
  OpenAI-compatible endpoints: Together, Groq, Ollama, etc.).

  Endpoint: POST <api_base>/v1/chat/completions
  Auth:     Authorization: Bearer <key>
}
unit PasClaw.Providers.OpenAI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TOpenAIProvider = class(TInterfacedObject, ILLMProvider)
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
  PasClaw.JSON,
  PasClaw.Providers.HTTP,
  PasClaw.Logger;

constructor TOpenAIProvider.Create(const APIKey, APIBase, DefaultModel: string);
begin
  inherited Create;
  FAPIKey := APIKey;
  if APIBase <> '' then FAPIBase := APIBase else FAPIBase := 'https://api.openai.com';
  if DefaultModel <> '' then FDefaultModel := DefaultModel else FDefaultModel := 'gpt-4o-mini';
end;

function TOpenAIProvider.GetDefaultModel: string;     begin Result := FDefaultModel; end;
function TOpenAIProvider.GetName: string;             begin Result := 'openai'; end;
function TOpenAIProvider.SupportsThinking: Boolean;   begin Result := False; end;
function TOpenAIProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TOpenAIProvider.SupportsStreaming: Boolean;  begin Result := False; end;

function BuildOAIRequest(const Messages: array of TMessage;
                         const Tools:    array of TToolDefinition;
                         const Model:    string;
                         const Options:  TChatOptions): string;
var
  Root, M, ToolObj, FObj, TCObj, EmptyParams: TJsonObject;
  MsgArr, ToolArr, TCArr: TJsonArray;
  i, j: Integer;
  Sys: string;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('model', Model);
    if Options.MaxTokens > 0 then Root.PutInt('max_tokens', Options.MaxTokens);
    if Options.Temperature > 0 then Root.PutFloat('temperature', Options.Temperature);

    Sys := Options.SystemPrompt;

    MsgArr := TJsonArray.Create;
    if Sys <> '' then
    begin
      M := TJsonObject.Create;
      M.PutStr('role',    'system');
      M.PutStr('content', Sys);
      MsgArr.AddObject(M);
    end;

    for i := 0 to High(Messages) do
    begin
      if (Messages[i].Role = mrSystem) and (Sys <> '') then
        Continue;  { already added above }

      M := TJsonObject.Create;
      M.PutStr('role', MsgRoleToString(Messages[i].Role));
      M.PutStr('content', Messages[i].Content);

      if Messages[i].Role = mrTool then
        M.PutStr('tool_call_id', Messages[i].ToolCallId);

      if Length(Messages[i].ToolCalls) > 0 then
      begin
        TCArr := TJsonArray.Create;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          TCObj := TJsonObject.Create;
          TCObj.PutStr('id',   Messages[i].ToolCalls[j].Id);
          TCObj.PutStr('type', 'function');
          FObj := TJsonObject.Create;
          FObj.PutStr('name',      Messages[i].ToolCalls[j].Func.Name);
          FObj.PutStr('arguments', Messages[i].ToolCalls[j].Func.Arguments);
          TCObj.PutObject('function', FObj);
          TCArr.AddObject(TCObj);
        end;
        M.PutArray('tool_calls', TCArr);
      end;

      MsgArr.AddObject(M);
    end;
    Root.PutArray('messages', MsgArr);

    if Length(Tools) > 0 then
    begin
      ToolArr := TJsonArray.Create;
      for i := 0 to High(Tools) do
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('type', 'function');
        FObj := TJsonObject.Create;
        FObj.PutStr('name', Tools[i].Name);
        if Tools[i].Description <> '' then FObj.PutStr('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
          FObj.PutRaw('parameters', Tools[i].Schema)
        else
        begin
          EmptyParams := TJsonObject.Create;
          FObj.PutObject('parameters', EmptyParams);
        end;
        ToolObj.PutObject('function', FObj);
        ToolArr.AddObject(ToolObj);
      end;
      Root.PutArray('tools', ToolArr);
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure ParseOAIResponse(const Body: string; var Resp: TLLMResponse);
var
  Obj, Choice, Msg, FObj, TCObj, Usage: TJsonObject;
  Choices, TCArr: TJsonArray;
  i: Integer;
  TC: TToolCall;
begin
  Resp.Content := '';
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Resp.Model := Obj.GetStr('model', '');
    Choices := Obj.ChildArray('choices');
    if Choices <> nil then
    try
      if Choices.Count > 0 then
      begin
        Choice := Choices.ItemObject(0);
        if Choice <> nil then
        try
          Resp.FinishReason := Choice.GetStr('finish_reason', '');
          Msg := Choice.ChildObject('message');
          if Msg <> nil then
          try
            Resp.Content := Msg.GetStr('content', '');
            TCArr := Msg.ChildArray('tool_calls');
            if TCArr <> nil then
            try
              for i := 0 to TCArr.Count - 1 do
              begin
                TCObj := TCArr.ItemObject(i);
                if TCObj = nil then Continue;
                try
                  TC.Id   := TCObj.GetStr('id', '');
                  TC.Kind := TCObj.GetStr('type', 'function');
                  FObj := TCObj.ChildObject('function');
                  if FObj <> nil then
                  try
                    TC.Func.Name      := FObj.GetStr('name', '');
                    TC.Func.Arguments := FObj.GetStr('arguments', '{}');
                  finally
                    FObj.Free;
                  end;
                  SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
                  Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
                finally
                  TCObj.Free;
                end;
              end;
            finally
              TCArr.Free;
            end;
          finally
            Msg.Free;
          end;
        finally
          Choice.Free;
        end;
      end;
    finally
      Choices.Free;
    end;
    Usage := Obj.ChildObject('usage');
    if Usage <> nil then
    try
      Resp.Usage.InputTokens  := Usage.GetInt('prompt_tokens',     0);
      Resp.Usage.OutputTokens := Usage.GetInt('completion_tokens', 0);
    finally
      Usage.Free;
    end;
  finally
    Obj.Free;
  end;
end;

function TOpenAIProvider.Chat(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions): TLLMResponse;
var
  Body, URL, UseModel: string;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL  := FAPIBase + '/v1/chat/completions';
  Body := BuildOAIRequest(Messages, Tools, UseModel, Options);

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FAPIKey);

  LogDebug('openai POST %s (model=%s, body=%d bytes)', [URL, UseModel, Length(Body)]);
  Resp := PostJSON(URL, Body, Headers, 120);

  Result.Content := '';
  SetLength(Result.ToolCalls, 0);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
    ParseOAIResponse(Resp.Body, Result)
  else
  begin
    if Resp.Body <> '' then
      Result.Content := Format('openai error %d: %s', [Resp.StatusCode, Resp.Body])
    else
      Result.Content := Format('openai error: status=%d msg=%s', [Resp.StatusCode, Resp.ErrorMsg]);
    Result.FinishReason := 'error';
  end;
end;

function TOpenAIProvider.ChatStream(const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
var
  C: TStreamChunk;
begin
  Result := Chat(Messages, Tools, Model, Options);
  if Assigned(OnChunk) then
  begin
    C.Kind := 'text'; C.Text := Result.Content; OnChunk(C);
    C.Kind := 'done'; C.Text := '';             OnChunk(C);
  end;
end;

end.
