{
  PasClaw.Providers.OpenAI - OpenAI Chat Completions client (also handles
  OpenAI-compatible endpoints: Together, Groq, Ollama, etc.).

  Endpoint: POST <api_base>/v1/chat/completions
  Auth:     Authorization: Bearer <key>
}
unit PasClaw.Providers.OpenAI;

{$MODE DELPHI}
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
  fpjson, jsonparser,
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
  Root: TJSONObject;
  MsgArr, ToolArr, TCArr: TJSONArray;
  M, ToolObj, FObj, TCObj: TJSONObject;
  i, j: Integer;
  Sys: string;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('model', Model);
    if Options.MaxTokens > 0 then Root.Add('max_tokens', Options.MaxTokens);
    if Options.Temperature > 0 then Root.Add('temperature', Options.Temperature);

    Sys := Options.SystemPrompt;

    MsgArr := TJSONArray.Create;
    if Sys <> '' then
    begin
      M := TJSONObject.Create;
      M.Add('role', 'system');
      M.Add('content', Sys);
      MsgArr.Add(M);
    end;

    for i := 0 to High(Messages) do
    begin
      if (Messages[i].Role = mrSystem) and (Sys <> '') then
        Continue;  { already added above }

      M := TJSONObject.Create;
      M.Add('role', MsgRoleToString(Messages[i].Role));
      if Messages[i].Content <> '' then M.Add('content', Messages[i].Content)
      else M.Add('content', '');

      if Messages[i].Role = mrTool then
        M.Add('tool_call_id', Messages[i].ToolCallId);

      if Length(Messages[i].ToolCalls) > 0 then
      begin
        TCArr := TJSONArray.Create;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          TCObj := TJSONObject.Create;
          TCObj.Add('id',   Messages[i].ToolCalls[j].Id);
          TCObj.Add('type', 'function');
          FObj := TJSONObject.Create;
          FObj.Add('name',      Messages[i].ToolCalls[j].Func.Name);
          FObj.Add('arguments', Messages[i].ToolCalls[j].Func.Arguments);
          TCObj.Add('function', FObj);
          TCArr.Add(TCObj);
        end;
        M.Add('tool_calls', TCArr);
      end;

      MsgArr.Add(M);
    end;
    Root.Add('messages', MsgArr);

    if Length(Tools) > 0 then
    begin
      ToolArr := TJSONArray.Create;
      for i := 0 to High(Tools) do
      begin
        ToolObj := TJSONObject.Create;
        ToolObj.Add('type', 'function');
        FObj := TJSONObject.Create;
        FObj.Add('name', Tools[i].Name);
        if Tools[i].Description <> '' then FObj.Add('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
        begin
          try
            FObj.Add('parameters', GetJSON(Tools[i].Schema));
          except
            FObj.Add('parameters', TJSONObject.Create);
          end;
        end
        else
          FObj.Add('parameters', TJSONObject.Create);
        ToolObj.Add('function', FObj);
        ToolArr.Add(ToolObj);
      end;
      Root.Add('tools', ToolArr);
    end;

    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

procedure ParseOAIResponse(const Body: string; var Resp: TLLMResponse);
var
  Root: TJSONData;
  Obj, Choice, Msg, FObj, TCObj, Usage: TJSONObject;
  Choices, TCArr: TJSONArray;
  i: Integer;
  TC: TToolCall;
begin
  Resp.Content := '';
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Root := GetJSON(Body);
  if not (Root is TJSONObject) then begin Root.Free; Exit; end;
  Obj := TJSONObject(Root);
  try
    Resp.Model := Obj.Get('model', '');
    if Obj.IndexOfName('choices') >= 0 then
    begin
      Choices := Obj.Arrays['choices'];
      if Choices.Count > 0 then
      begin
        Choice := TJSONObject(Choices[0]);
        Resp.FinishReason := Choice.Get('finish_reason', '');
        Msg := Choice.Objects['message'];
        Resp.Content := Msg.Get('content', '');
        if Msg.IndexOfName('tool_calls') >= 0 then
        begin
          TCArr := Msg.Arrays['tool_calls'];
          for i := 0 to TCArr.Count - 1 do
          begin
            TCObj := TJSONObject(TCArr[i]);
            TC.Id   := TCObj.Get('id', '');
            TC.Kind := TCObj.Get('type', 'function');
            FObj := TCObj.Objects['function'];
            TC.Func.Name      := FObj.Get('name', '');
            TC.Func.Arguments := FObj.Get('arguments', '{}');
            SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
            Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
          end;
        end;
      end;
    end;
    if Obj.IndexOfName('usage') >= 0 then
    begin
      Usage := Obj.Objects['usage'];
      Resp.Usage.InputTokens  := Usage.Get('prompt_tokens',     0);
      Resp.Usage.OutputTokens := Usage.Get('completion_tokens', 0);
    end;
  finally
    Root.Free;
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
