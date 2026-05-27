{
  PasClaw.Providers.Types - protocol type records shared by every LLM provider.
  Mirrors pkg/providers/protocoltypes in picoclaw.
}
unit PasClaw.Providers.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { Role for a chat message. }
  TMsgRole = (mrSystem, mrUser, mrAssistant, mrTool);

  { One function-call requested by the model. }
  TFunctionCall = record
    Name:      string;
    Arguments: string;   { raw JSON }
  end;

  TToolCall = record
    Id:       string;
    Kind:     string;    { "function" for now }
    Func:     TFunctionCall;
  end;

  { A chat message. The Content field holds plain text; ToolCalls and
    ToolCallId are non-empty for assistant tool-call responses and tool-result
    inputs respectively. }
  TMessage = record
    Role:       TMsgRole;
    Content:    string;
    Name:       string;
    ToolCallId: string;
    ToolCalls:  array of TToolCall;
  end;

  { A tool exposed to the model (OpenAI-compatible function shape; Anthropic
    translates this at the edge). }
  TToolDefinition = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON schema for parameters }
  end;

  TToolDefinitionArray = array of TToolDefinition;
  TMessageArray        = array of TMessage;
  TToolCallArray       = array of TToolCall;

  TUsageInfo = record
    InputTokens:        Integer;
    OutputTokens:       Integer;
    CacheReadTokens:    Integer;
    CacheCreatedTokens: Integer;
  end;

  TLLMResponse = record
    Content:    string;
    ToolCalls:  array of TToolCall;
    FinishReason: string;
    Usage:      TUsageInfo;
    Model:      string;
  end;

  TStreamChunk = record
    Kind:     string;     { "text" | "tool_call" | "usage" | "done" }
    Text:     string;
    ToolCall: TToolCall;
    Usage:    TUsageInfo;
  end;

  { Generic chat options handed to a provider. Anything provider-specific is
    JSON-encoded into the Extra field rather than baking another type alias. }
  TChatOptions = record
    Temperature:   Double;
    MaxTokens:     Integer;
    Stream:        Boolean;
    SystemPrompt:  string;
    ThinkingLevel: string;   { "", "low", "medium", "high" }
    Extra:         string;   { provider-specific JSON object }
  end;

function MsgRoleToString(R: TMsgRole): string;
function MsgRoleFromString(const S: string): TMsgRole;
function DefaultChatOptions: TChatOptions;
function MakeMessage(Role: TMsgRole; const Content: string): TMessage;

implementation

function MsgRoleToString(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else
    Result := 'user';
  end;
end;

function MsgRoleFromString(const S: string): TMsgRole;
begin
  if      S = 'system'    then Result := mrSystem
  else if S = 'assistant' then Result := mrAssistant
  else if S = 'tool'      then Result := mrTool
  else                         Result := mrUser;
end;

function DefaultChatOptions: TChatOptions;
begin
  Result.Temperature   := 0.7;
  Result.MaxTokens     := 4096;
  Result.Stream        := False;
  Result.SystemPrompt  := '';
  Result.ThinkingLevel := '';
  Result.Extra         := '';
end;

function MakeMessage(Role: TMsgRole; const Content: string): TMessage;
begin
  Result.Role       := Role;
  Result.Content    := Content;
  Result.Name       := '';
  Result.ToolCallId := '';
  SetLength(Result.ToolCalls, 0);
end;

end.
