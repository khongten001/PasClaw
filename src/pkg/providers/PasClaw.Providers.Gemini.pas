(*
  PasClaw.Providers.Gemini - Google Gemini "generateContent" REST client.

  Endpoint : POST <api_base>/v1beta/models/<model>:generateContent
  Auth     : x-goog-api-key: <api_key>

  Gemini's wire shape differs from OpenAI / Anthropic in three places
  that matter for the tool loop:

    1. Roles: messages use "user" / "model" (not "assistant"). System
       prompts do not go in the messages array — they live in a
       top-level `systemInstruction` field.

    2. Tool calls live inside `parts[].functionCall`, and tool results
       come back via `parts[].functionResponse` (sent with role "user"
       per Google's spec). Function responses are keyed by tool NAME,
       not by ID — we build an id->name map on the fly when scanning
       earlier assistant turns.

    3. Tools are sent at the top level as
       `tools: [{functionDeclarations: [{name, description, parameters}]}]`.

  Scope of this initial cut: text + tool calls + tool results, plus
  basic generationConfig (max_tokens, temperature) and usage parsing.
  Streaming, thinkingConfig, image attachments, and proxy / extraBody
  knobs are deferred — ChatStream falls back to a synchronous Chat()
  call and emits the result as one text chunk, matching what
  TOpenAIProvider does for its non-streaming providers.
*)
unit PasClaw.Providers.Gemini;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TGeminiProvider = class(TInterfacedObject, ILLMProvider)
  private
    FAPIKey:       string;
    FAPIBase:      string;
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

constructor TGeminiProvider.Create(const APIKey, APIBase, DefaultModel: string);
begin
  inherited Create;
  FAPIKey := APIKey;
  if APIBase <> '' then FAPIBase := APIBase
                   else FAPIBase := 'https://generativelanguage.googleapis.com';
  if DefaultModel <> '' then FDefaultModel := DefaultModel
                       else FDefaultModel := 'gemini-1.5-flash';
end;

function TGeminiProvider.GetDefaultModel: string;     begin Result := FDefaultModel; end;
function TGeminiProvider.GetName: string;             begin Result := 'gemini';      end;
function TGeminiProvider.SupportsThinking: Boolean;   begin Result := False;         end;
function TGeminiProvider.SupportsNativeSearch: Boolean; begin Result := False;       end;
function TGeminiProvider.SupportsStreaming: Boolean;  begin Result := False;         end;

{ Map TMsgRole to Gemini's content.role. Note tool/system are special
  cases handled by the caller — system goes in systemInstruction,
  tool result content is wrapped with role "user" + functionResponse
  part. This helper only matters for plain user / assistant turns. }
function RoleForGemini(R: TMsgRole): string;
begin
  case R of
    mrAssistant: Result := 'model';
  else
    Result := 'user';
  end;
end;

{ Builds the request body. Mirrors picoclaw's pkg/providers/httpapi
  gemini_provider.go buildRequestBody, trimmed to text + tool support. }
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions): string;
var
  Root, Content, Part, ToolObj, FuncDecl, FuncCall, FuncResp,
    FuncRespBody, EmptyObj, GenCfg, SysContent, SysPart, ToolsTop: TJsonObject;
  Contents, Parts, ToolsArr, FuncDecls, SysParts: TJsonArray;
  i, j: Integer;
  Sys, ToolName, ArgsJSON: string;
  ToolIds, ToolNames: TStringList;   { id -> name map, parallel arrays }
  Idx: Integer;
begin
  ToolIds   := TStringList.Create;
  ToolNames := TStringList.Create;
  Root := TJsonObject.Create;
  try
    Contents := TJsonArray.Create;

    { First pass: collect every system prompt for systemInstruction. }
    Sys := Options.SystemPrompt;
    for i := 0 to High(Messages) do
      if (Messages[i].Role = mrSystem) and (Trim(Messages[i].Content) <> '') then
      begin
        if Sys = '' then
          Sys := Messages[i].Content
        else
          Sys := Sys + sLineBreak + Messages[i].Content;
      end;

    { Pre-scan assistant turns so tool-result messages can resolve a
      function name from their tool_call_id. Gemini's functionResponse
      requires the NAME, not the id. }
    for i := 0 to High(Messages) do
      if Messages[i].Role = mrAssistant then
        for j := 0 to High(Messages[i].ToolCalls) do
          if (Messages[i].ToolCalls[j].Id <> '') and
             (ToolIds.IndexOf(Messages[i].ToolCalls[j].Id) < 0) then
          begin
            ToolIds.Add(Messages[i].ToolCalls[j].Id);
            ToolNames.Add(Messages[i].ToolCalls[j].Func.Name);
          end;

    { Second pass: build contents[] in order. }
    for i := 0 to High(Messages) do
    begin
      if Messages[i].Role = mrSystem then Continue;

      if Messages[i].Role = mrTool then
      begin
        { Tool result → role:user, parts:[{functionResponse}]. }
        Content := TJsonObject.Create;
        Content.PutStr('role', 'user');
        Parts := TJsonArray.Create;

        Part := TJsonObject.Create;
        FuncResp := TJsonObject.Create;

        Idx := ToolIds.IndexOf(Messages[i].ToolCallId);
        if Idx >= 0 then ToolName := ToolNames[Idx]
                    else ToolName := '';
        FuncResp.PutStr('name', ToolName);

        FuncRespBody := TJsonObject.Create;
        FuncRespBody.PutStr('result', Messages[i].Content);
        FuncResp.PutObject('response', FuncRespBody);

        Part.PutObject('functionResponse', FuncResp);
        Parts.AddObject(Part);
        Content.PutArray('parts', Parts);
        Contents.AddObject(Content);
        Continue;
      end;

      if Messages[i].Role = mrAssistant then
      begin
        Content := TJsonObject.Create;
        Content.PutStr('role', 'model');
        Parts := TJsonArray.Create;

        if Trim(Messages[i].Content) <> '' then
        begin
          Part := TJsonObject.Create;
          Part.PutStr('text', Messages[i].Content);
          Parts.AddObject(Part);
        end;

        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          if Messages[i].ToolCalls[j].Func.Name = '' then Continue;
          Part := TJsonObject.Create;
          FuncCall := TJsonObject.Create;
          FuncCall.PutStr('name', Messages[i].ToolCalls[j].Func.Name);
          ArgsJSON := Messages[i].ToolCalls[j].Func.Arguments;
          if Trim(ArgsJSON) = '' then
          begin
            EmptyObj := TJsonObject.Create;
            FuncCall.PutObject('args', EmptyObj);
          end
          else
            FuncCall.PutRaw('args', ArgsJSON);
          Part.PutObject('functionCall', FuncCall);
          Parts.AddObject(Part);
        end;

        if Parts.Count > 0 then
        begin
          Content.PutArray('parts', Parts);
          Contents.AddObject(Content);
        end
        else
        begin
          { Drop the empty assistant turn — Gemini rejects empty parts. }
          Parts.Free;
          Content.Free;
        end;
        Continue;
      end;

      { Plain user turn. }
      Content := TJsonObject.Create;
      Content.PutStr('role', RoleForGemini(Messages[i].Role));
      Parts := TJsonArray.Create;
      Part := TJsonObject.Create;
      Part.PutStr('text', Messages[i].Content);
      Parts.AddObject(Part);
      Content.PutArray('parts', Parts);
      Contents.AddObject(Content);
    end;

    Root.PutArray('contents', Contents);

    if Sys <> '' then
    begin
      SysContent := TJsonObject.Create;
      SysParts := TJsonArray.Create;
      SysPart := TJsonObject.Create;
      SysPart.PutStr('text', Sys);
      SysParts.AddObject(SysPart);
      SysContent.PutArray('parts', SysParts);
      Root.PutObject('systemInstruction', SysContent);
    end;

    if Length(Tools) > 0 then
    begin
      FuncDecls := TJsonArray.Create;
      for i := 0 to High(Tools) do
      begin
        FuncDecl := TJsonObject.Create;
        FuncDecl.PutStr('name', Tools[i].Name);
        if Tools[i].Description <> '' then
          FuncDecl.PutStr('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
          FuncDecl.PutRaw('parameters', Tools[i].Schema)
        else
        begin
          EmptyObj := TJsonObject.Create;
          FuncDecl.PutObject('parameters', EmptyObj);
        end;
        FuncDecls.AddObject(FuncDecl);
      end;
      ToolObj := TJsonObject.Create;
      ToolObj.PutArray('functionDeclarations', FuncDecls);
      ToolsArr := TJsonArray.Create;
      ToolsArr.AddObject(ToolObj);
      Root.PutArray('tools', ToolsArr);
    end;

    if (Options.MaxTokens > 0) or (Options.Temperature > 0) then
    begin
      GenCfg := TJsonObject.Create;
      if Options.MaxTokens > 0 then GenCfg.PutInt('maxOutputTokens', Options.MaxTokens);
      if Options.Temperature > 0 then GenCfg.PutFloat('temperature', Options.Temperature);
      Root.PutObject('generationConfig', GenCfg);
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
    ToolIds.Free;
    ToolNames.Free;
  end;
end;

procedure ParseResponse(const Body: string; var Resp: TLLMResponse);
var
  Obj, Candidate, ContentObj, Part, FuncCall, ArgsObj, Usage: TJsonObject;
  Candidates, Parts: TJsonArray;
  i, j: Integer;
  Text: string;
  TC: TToolCall;
begin
  Resp.Content := '';
  Resp.FinishReason := '';
  Resp.Model := '';
  Resp.Usage.InputTokens  := 0;
  Resp.Usage.OutputTokens := 0;
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Resp.Model := Obj.GetStr('modelVersion', '');

    Candidates := Obj.ChildArray('candidates');
    if Candidates <> nil then
    try
      for i := 0 to Candidates.Count - 1 do
      begin
        Candidate := Candidates.ItemObject(i);
        if Candidate = nil then Continue;
        try
          if Resp.FinishReason = '' then
            Resp.FinishReason := Candidate.GetStr('finishReason', '');

          ContentObj := Candidate.ChildObject('content');
          if ContentObj = nil then Continue;
          try
            Parts := ContentObj.ChildArray('parts');
            if Parts = nil then Continue;
            try
              for j := 0 to Parts.Count - 1 do
              begin
                Part := Parts.ItemObject(j);
                if Part = nil then Continue;
                try
                  Text := Part.GetStr('text', '');
                  if Text <> '' then
                  begin
                    if Resp.Content <> '' then Resp.Content := Resp.Content + sLineBreak;
                    Resp.Content := Resp.Content + Text;
                  end;
                  FuncCall := Part.ChildObject('functionCall');
                  if FuncCall <> nil then
                  try
                    TC.Kind      := 'function';
                    TC.Func.Name := FuncCall.GetStr('name', '');
                    { Gemini's functionCall has name + args but no
                      OpenAI-style id. The tool loop later records this
                      id on the mrTool result, and BuildRequest above
                      needs a non-empty id to resolve the call->name
                      map for functionResponse — leaving Id empty
                      makes the tool result go back with name: "" and
                      the model can't associate it with the requested
                      call. Synthesize a deterministic local id from
                      the function name + the position of this call in
                      the response. Collisions across turns are fine:
                      same id always maps to the same name. }
                    TC.Id        := FuncCall.GetStr('id', '');
                    if Trim(TC.Id) = '' then
                      TC.Id := Format('gemini_call_%s_%d',
                                      [TC.Func.Name, Length(Resp.ToolCalls)]);
                    ArgsObj := FuncCall.ChildObject('args');
                    if ArgsObj <> nil then
                    try
                      TC.Func.Arguments := ArgsObj.ToJSON;
                    finally
                      ArgsObj.Free;
                    end
                    else
                      TC.Func.Arguments := '{}';
                    SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
                    Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
                  finally
                    FuncCall.Free;
                  end;
                finally
                  Part.Free;
                end;
              end;
            finally
              Parts.Free;
            end;
          finally
            ContentObj.Free;
          end;
        finally
          Candidate.Free;
        end;
      end;
    finally
      Candidates.Free;
    end;

    { Map Gemini's STOP / MAX_TOKENS / etc. to the canonical OpenAI-style
      finish_reason strings the rest of PasClaw expects. }
    if Resp.FinishReason = 'STOP' then
    begin
      if Length(Resp.ToolCalls) > 0 then Resp.FinishReason := 'tool_calls'
                                    else Resp.FinishReason := 'stop';
    end
    else if Resp.FinishReason = 'MAX_TOKENS' then
      Resp.FinishReason := 'length'
    else if (Resp.FinishReason <> '') and (Length(Resp.ToolCalls) > 0) then
      Resp.FinishReason := 'tool_calls';

    Usage := Obj.ChildObject('usageMetadata');
    if Usage <> nil then
    try
      Resp.Usage.InputTokens  := Usage.GetInt('promptTokenCount',     0);
      Resp.Usage.OutputTokens := Usage.GetInt('candidatesTokenCount', 0);
    finally
      Usage.Free;
    end;
  finally
    Obj.Free;
  end;
end;

function TGeminiProvider.Chat(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions): TLLMResponse;
var
  Body, URL, UseModel: string;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL  := FAPIBase + '/v1beta/models/' + UseModel + ':generateContent';
  Body := BuildRequest(Messages, Tools, UseModel, Options);

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('x-goog-api-key', FAPIKey);

  LogDebug('gemini POST %s (model=%s, body=%d bytes)', [URL, UseModel, Length(Body)]);
  Resp := PostJSON(URL, Body, Headers, 120);

  Result.Content := '';
  SetLength(Result.ToolCalls, 0);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    ParseResponse(Resp.Body, Result);
    Exit;
  end;

  if Resp.Body <> '' then
    Result.Content := Format('gemini error %d: %s', [Resp.StatusCode, Resp.Body])
  else
    Result.Content := Format('gemini error: status=%d msg=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result.FinishReason := 'error';
end;

function TGeminiProvider.ChatStream(const Messages: array of TMessage;
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
