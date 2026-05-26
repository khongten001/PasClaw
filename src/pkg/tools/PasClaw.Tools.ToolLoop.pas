{
  PasClaw.Tools.ToolLoop - the core agent loop. Repeatedly calls the LLM
  with the running message history; if the response contains tool_calls,
  dispatches each through the registry, appends the tool result as a tool
  message, and continues. Mirrors pkg/tools/toolloop.go.
}
unit PasClaw.Tools.ToolLoop;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TToolLoopConfig = record
    Provider:      ILLMProvider;
    Registry:      TToolRegistry;
    Model:         string;
    MaxIterations: Integer;
    Options:       TChatOptions;
    OnText:        procedure(const S: string) of object;   { streaming-ish stdout }
    OnToolCall:    procedure(const Name, ArgsJSON: string) of object;
    OnToolResult:  procedure(const Name, ResultText, Err: string) of object;
  end;

  TToolLoopResult = record
    Content:     string;
    Iterations:  Integer;
    LastResp:    TLLMResponse;
  end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;

implementation

uses
  PasClaw.Logger;

function MakeAssistantWithToolCalls(const Content: string;
                                    const Calls: array of TToolCall): TMessage;
var
  i: Integer;
begin
  Result.Role       := mrAssistant;
  Result.Content    := Content;
  Result.Name       := '';
  Result.ToolCallId := '';
  SetLength(Result.ToolCalls, Length(Calls));
  for i := 0 to High(Calls) do Result.ToolCalls[i] := Calls[i];
end;

function MakeToolResult(const ToolCallId, Content: string): TMessage;
begin
  Result := MakeMessage(mrTool, Content);
  Result.ToolCallId := ToolCallId;
end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;
var
  Iter, i: Integer;
  Tools: array of TToolDefinition;
  Resp: TLLMResponse;
  Hist: array of TMessage;
  ResultText, Err: string;
begin
  Loop.Content    := '';
  Loop.Iterations := 0;

  if Cfg.Provider = nil then Exit(False);

  { Copy input messages to a growable history. }
  SetLength(Hist, Length(Messages));
  for i := 0 to High(Messages) do Hist[i] := Messages[i];

  if Cfg.Registry <> nil then
    Tools := Cfg.Registry.ToProviderDefs
  else
    SetLength(Tools, 0);

  Iter := 0;
  while Iter < Cfg.MaxIterations do
  begin
    Inc(Iter);
    LogDebug('toolloop iteration %d / %d', [Iter, Cfg.MaxIterations]);

    Resp := Cfg.Provider.Chat(Hist, Tools, Cfg.Model, Cfg.Options);
    Loop.LastResp := Resp;

    { Stream the text part to the caller now so they can show progress. }
    if Assigned(Cfg.OnText) and (Resp.Content <> '') then
      Cfg.OnText(Resp.Content);

    if Length(Resp.ToolCalls) = 0 then
    begin
      Loop.Content    := Resp.Content;
      Loop.Iterations := Iter;
      Exit(True);
    end;

    { Append the assistant turn (text + tool calls) and dispatch each call. }
    SetLength(Hist, Length(Hist) + 1);
    Hist[High(Hist)] := MakeAssistantWithToolCalls(Resp.Content, Resp.ToolCalls);

    for i := 0 to High(Resp.ToolCalls) do
    begin
      if Assigned(Cfg.OnToolCall) then
        Cfg.OnToolCall(Resp.ToolCalls[i].Func.Name, Resp.ToolCalls[i].Func.Arguments);

      Err := '';
      ResultText := '';
      if Cfg.Registry <> nil then
        ResultText := Cfg.Registry.Dispatch(Resp.ToolCalls[i].Func.Name,
                                            Resp.ToolCalls[i].Func.Arguments,
                                            Err)
      else
        Err := 'no tool registry';

      if Assigned(Cfg.OnToolResult) then
        Cfg.OnToolResult(Resp.ToolCalls[i].Func.Name, ResultText, Err);

      SetLength(Hist, Length(Hist) + 1);
      if Err <> '' then
        Hist[High(Hist)] := MakeToolResult(Resp.ToolCalls[i].Id, 'ERROR: ' + Err)
      else
        Hist[High(Hist)] := MakeToolResult(Resp.ToolCalls[i].Id, ResultText);
    end;
  end;

  { Max iterations exhausted; return whatever we last got. }
  Loop.Content    := Resp.Content;
  Loop.Iterations := Iter;
  Result := True;
end;

end.
