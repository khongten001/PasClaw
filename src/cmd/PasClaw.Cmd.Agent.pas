{
  Agent — chat with the assistant. Two modes:
    pasclaw agent -m "single query"   one-shot
    pasclaw agent                     interactive
  Wires through PasClaw.Providers.Factory; falls back to an offline preview
  when no API key is configured so the CLI still demonstrates the shape.
}
unit PasClaw.Cmd.Agent;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Agent_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI, PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory;

type
  TAgentArgs = record
    Message:       string;
    Model:         string;
    Provider:      string;
    SystemPrompt:  string;
    Thinking:      string;
    MaxTokens:     Integer;
  end;

function DefaultAgentArgs: TAgentArgs;
begin
  Result.Message       := '';
  Result.Model         := '';
  Result.Provider      := '';
  Result.SystemPrompt  := '';
  Result.Thinking      := '';
  Result.MaxTokens     := 4096;
end;

function ParseArgs(const Argv: array of string; var A: TAgentArgs): Boolean;
var
  i: Integer;
begin
  Result := True;
  A := DefaultAgentArgs;
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-m') or (Argv[i] = '--message') then
    begin
      if i = High(Argv) then Exit(False);
      A.Message := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--model' then
    begin
      if i = High(Argv) then Exit(False);
      A.Model := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--provider' then
    begin
      if i = High(Argv) then Exit(False);
      A.Provider := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--system' then
    begin
      if i = High(Argv) then Exit(False);
      A.SystemPrompt := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--thinking' then
    begin
      if i = High(Argv) then Exit(False);
      A.Thinking := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--max-tokens' then
    begin
      if i = High(Argv) then Exit(False);
      A.MaxTokens := StrToIntDef(Argv[i + 1], A.MaxTokens); Inc(i, 2); Continue;
    end;
    Inc(i);
  end;
end;

function PickProvider(Cfg: TConfig; const A: TAgentArgs;
                      out Provider: ILLMProvider; out Err: string): Boolean;
var
  Name: string;
begin
  if A.Provider <> '' then Name := A.Provider else Name := Cfg.DefaultProvider;
  if Name = '' then
  begin
    Err := 'no provider configured';
    Exit(False);
  end;
  Result := NewProviderFromConfig(Cfg, Name, Provider, Err);
end;

procedure RunSingleTurn(const Cfg: TConfig; const A: TAgentArgs; const Prompt: string);
var
  Provider: ILLMProvider;
  Err: string;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  Opts: TChatOptions;
  Resp: TLLMResponse;
  Model: string;
begin
  if not PickProvider(Cfg, A, Provider, Err) then
  begin
    WriteLn(Ansi.Yellow, '(offline preview — ', Err, ')', Ansi.Reset);
    WriteLn('You: ', Prompt);
    WriteLn('Assistant: ', '<provider not configured; run `pasclaw onboard` to enable>');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Prompt);
  SetLength(Tools, 0);

  Opts := DefaultChatOptions;
  Opts.SystemPrompt  := A.SystemPrompt;
  Opts.ThinkingLevel := A.Thinking;
  if A.MaxTokens > 0 then Opts.MaxTokens := A.MaxTokens;

  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;

  WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (', Provider.GetName, '/', Model, '):');
  Resp := Provider.Chat(Msgs, Tools, Model, Opts);
  WriteLn(Resp.Content);
  if Resp.Usage.InputTokens + Resp.Usage.OutputTokens > 0 then
    WriteLn(Ansi.Dim,
      Format('  [tokens in=%d out=%d]', [Resp.Usage.InputTokens, Resp.Usage.OutputTokens]),
      Ansi.Reset);
end;

procedure RunInteractive(const Cfg: TConfig; const A: TAgentArgs);
var
  Line: string;
  Provider: ILLMProvider;
  Err: string;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  Opts: TChatOptions;
  Resp: TLLMResponse;
  Model: string;
  Offline: Boolean;
begin
  Offline := not PickProvider(Cfg, A, Provider, Err);
  if Offline then
    WriteLn(Ansi.Yellow, '(offline preview — ', Err, ')', Ansi.Reset);
  WriteLn(Ansi.Dim, 'PasClaw interactive chat. /quit to exit, /reset to clear history.', Ansi.Reset);

  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
  Opts := DefaultChatOptions;
  Opts.SystemPrompt  := A.SystemPrompt;
  Opts.ThinkingLevel := A.Thinking;
  if A.MaxTokens > 0 then Opts.MaxTokens := A.MaxTokens;
  SetLength(Tools, 0);
  SetLength(Msgs, 0);

  while True do
  begin
    Write(Ansi.Bold, '> ', Ansi.Reset);
    if EOF then Break;
    ReadLn(Line);
    Line := Trim(Line);
    if (Line = '/quit') or (Line = '/exit') then Break;
    if Line = '/reset' then
    begin
      SetLength(Msgs, 0);
      WriteLn(Ansi.Dim, '(history cleared)', Ansi.Reset);
      Continue;
    end;
    if Line = '' then Continue;

    SetLength(Msgs, Length(Msgs) + 1);
    Msgs[High(Msgs)] := MakeMessage(mrUser, Line);

    if Offline then
    begin
      WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (offline): I would respond once a provider is configured.');
      SetLength(Msgs, Length(Msgs) + 1);
      Msgs[High(Msgs)] := MakeMessage(mrAssistant, '(no response — offline)');
      Continue;
    end;

    Resp := Provider.Chat(Msgs, Tools, Model, Opts);
    WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (', Provider.GetName, '/', Model, '):');
    WriteLn(Resp.Content);

    SetLength(Msgs, Length(Msgs) + 1);
    Msgs[High(Msgs)] := MakeMessage(mrAssistant, Resp.Content);
  end;
end;

function Cmd_Agent_Run(const Argv: array of string): Integer;
var
  A: TAgentArgs;
  Cfg: TConfig;
begin
  if not ParseArgs(Argv, A) then
  begin
    WriteLn(ErrOutput, 'usage: pasclaw agent [-m "message"] [--model M] [--provider P] [--system S] [--thinking low|medium|high]');
    Exit(1);
  end;

  Cfg := LoadConfig;
  try
    if A.Message <> '' then RunSingleTurn(Cfg, A, A.Message)
    else                    RunInteractive(Cfg, A);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
