{
  Agent — chat with the assistant.

  Two modes:
    pasclaw agent -m "single query"   one-shot
    pasclaw agent                     interactive

  Always wires the built-in tools registry (fs_read, fs_write, fs_list,
  shell_exec). Falls back to an offline preview if no provider is configured.
}
unit PasClaw.Cmd.Agent;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Agent_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI, PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.ToolLoop,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Agent.Prompt;

type
  TAgentArgs = record
    Message:       string;
    Model:         string;
    Provider:      string;
    SystemPrompt:  string;
    Thinking:      string;
    MaxTokens:     Integer;
    MaxIterations: Integer;
    NoTools:       Boolean;
    NoMCP:         Boolean;
    NoHashline:    Boolean;
  end;

  TLoopHandlers = class
    procedure OnToolCall(const Name, ArgsJSON: string);
    procedure OnToolResult(const Name, ResultText, Err: string);
  end;

procedure TLoopHandlers.OnToolCall(const Name, ArgsJSON: string);
begin
  WriteLn(Ansi.Magenta, '› tool ', Name, Ansi.Reset, ' ', Copy(ArgsJSON, 1, 200));
end;

procedure TLoopHandlers.OnToolResult(const Name, ResultText, Err: string);
var
  Preview: string;
begin
  if Err <> '' then
    WriteLn(Ansi.Red, '  ✗ ', Err, Ansi.Reset)
  else
  begin
    Preview := ResultText;
    if Length(Preview) > 200 then Preview := Copy(Preview, 1, 200) + '…';
    WriteLn(Ansi.Dim, '  ✓ ', Preview, Ansi.Reset);
  end;
end;

function DefaultAgentArgs: TAgentArgs;
begin
  Result.Message       := '';
  Result.Model         := '';
  Result.Provider      := '';
  Result.SystemPrompt  := '';
  Result.Thinking      := '';
  Result.MaxTokens     := 8192;   { see DefaultChatOptions in PasClaw.Providers.Types — same rationale }
  Result.MaxIterations := 8;
  Result.NoTools       := False;
  Result.NoMCP         := False;
  Result.NoHashline    := False;
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
    if Argv[i] = '--model'    then begin if i = High(Argv) then Exit(False); A.Model := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--provider' then begin if i = High(Argv) then Exit(False); A.Provider := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--system'   then begin if i = High(Argv) then Exit(False); A.SystemPrompt := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--thinking' then begin if i = High(Argv) then Exit(False); A.Thinking := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--max-tokens'     then begin if i = High(Argv) then Exit(False); A.MaxTokens     := StrToIntDef(Argv[i + 1], A.MaxTokens);     Inc(i, 2); Continue; end;
    if Argv[i] = '--max-iterations' then begin if i = High(Argv) then Exit(False); A.MaxIterations := StrToIntDef(Argv[i + 1], A.MaxIterations); Inc(i, 2); Continue; end;
    if Argv[i] = '--no-tools'    then begin A.NoTools    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-mcp'      then begin A.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-hashline' then begin A.NoHashline := True; Inc(i); Continue; end;
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

function NewBuiltinRegistry(UseHashline: Boolean = True): TToolRegistry;
var
  Skills: TSkillSpecArray;
begin
  Result := TToolRegistry.Create;
  RegisterFSTools(Result, UseHashline);
  RegisterShellTool(Result);
  Skills := LoadSkillManifests(GetHome);
  RegisterSkills(Result, Skills);
end;

function ConnectMCP(Cfg: TConfig; Reg: TToolRegistry; NoMCP: Boolean): TMCPClientList;
begin
  SetLength(Result, 0);
  if NoMCP then Exit;
  if Reg = nil then Exit;
  Result := ConnectMCPServers(Cfg, Reg);
end;

function BuildLoopConfig(const Cfg: TConfig;
                         Provider: ILLMProvider; Reg: TToolRegistry;
                         const Model: string; const A: TAgentArgs;
                         Handlers: TLoopHandlers): TToolLoopConfig;
begin
  Result.Provider      := Provider;
  Result.Registry      := Reg;
  Result.Model         := Model;
  Result.MaxIterations := A.MaxIterations;
  Result.Options       := DefaultChatOptions;
  Result.Options.SystemPrompt  := BuildSystemPrompt(Cfg, A.SystemPrompt);
  Result.Options.ThinkingLevel := A.Thinking;
  if A.MaxTokens > 0 then Result.Options.MaxTokens := A.MaxTokens;
  Result.OnText        := nil;
  Result.OnToolCall    := Handlers.OnToolCall;
  Result.OnToolResult  := Handlers.OnToolResult;
end;

procedure RunSingleTurn(const Cfg: TConfig; const A: TAgentArgs; const Prompt: string);
var
  Provider: ILLMProvider;
  Err: string;
  Msgs: array of TMessage;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  MCPClients: TMCPClientList;
begin
  if not PickProvider(Cfg, A, Provider, Err) then
  begin
    WriteLn(Ansi.Yellow, '(offline preview — ', Err, ')', Ansi.Reset);
    WriteLn('You: ', Prompt);
    WriteLn('Assistant: <provider not configured; run `pasclaw onboard`>');
    Exit;
  end;

  Reg := nil;
  if not A.NoTools then Reg := NewBuiltinRegistry(not A.NoHashline);
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Handlers := TLoopHandlers.Create;
  try
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, Prompt);

    if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
    LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers);

    WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (', Provider.GetName, '/', Model, '):');
    if RunToolLoop(LoopCfg, Msgs, Loop) then
      WriteLn(Loop.Content)
    else
      WriteLn('(loop failed)');
    if Loop.LastResp.Usage.InputTokens + Loop.LastResp.Usage.OutputTokens > 0 then
      WriteLn(Ansi.Dim, Format('  [tokens in=%d out=%d, iters=%d]',
        [Loop.LastResp.Usage.InputTokens, Loop.LastResp.Usage.OutputTokens, Loop.Iterations]),
        Ansi.Reset);
  finally
    Handlers.Free;
    FreeMCPClients(MCPClients);
    Reg.Free;
  end;
end;

procedure RunInteractive(const Cfg: TConfig; const A: TAgentArgs);
var
  Line: string;
  Provider: ILLMProvider;
  Err: string;
  Msgs: array of TMessage;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  Offline: Boolean;
  i: Integer;
  Names: TStringArray;
  MCPClients: TMCPClientList;
begin
  Offline := not PickProvider(Cfg, A, Provider, Err);
  if Offline then
    WriteLn(Ansi.Yellow, '(offline preview — ', Err, ')', Ansi.Reset);
  WriteLn(Ansi.Dim, 'PasClaw interactive chat. /quit to exit, /reset to clear history, /tools to list.', Ansi.Reset);

  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
  Reg := nil;
  if not A.NoTools then Reg := NewBuiltinRegistry(not A.NoHashline);
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Handlers := TLoopHandlers.Create;
  try
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
      if Line = '/tools' then
      begin
        if Reg = nil then
          WriteLn('(tools disabled — restart without --no-tools)')
        else
        begin
          Names := Reg.Names;
          for i := 0 to High(Names) do WriteLn('  ', Names[i]);
        end;
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

      LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers);
      if RunToolLoop(LoopCfg, Msgs, Loop) then
      begin
        WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (', Provider.GetName, '/', Model, '):');
        WriteLn(Loop.Content);
        SetLength(Msgs, Length(Msgs) + 1);
        Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
      end;
    end;
  finally
    Handlers.Free;
    FreeMCPClients(MCPClients);
    Reg.Free;
  end;
end;

function Cmd_Agent_Run(const Argv: array of string): Integer;
var
  A: TAgentArgs;
  Cfg: TConfig;
begin
  if not ParseArgs(Argv, A) then
  begin
    WriteLn(ErrOutput, 'usage: pasclaw agent [-m "msg"] [--model M] [--provider P] [--system S]');
    WriteLn(ErrOutput, '                     [--thinking low|medium|high] [--max-tokens N]');
    WriteLn(ErrOutput, '                     [--max-iterations N] [--no-tools]');
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
