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
  PasClaw.Tools.Memory,
  PasClaw.Tools.WebSearch,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Compact,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Agent.Prompt,
  PasClaw.Agent.Subagent,
  PasClaw.Session.Store,
  PasClaw.Tools.Sandbox;

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
    { Session id to resume. Empty = start a fresh in-memory
      conversation (not persisted until /save or `/new`). Non-empty
      AND existing on disk = load history + system-prompt override
      from workspace/sessions/<id>.json. Non-empty AND missing on
      disk = create that session id with empty history (so a script
      can pre-seed an id like "daily-2026-06-01"). }
    Session:       string;
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
    if Argv[i] = '--session'     then begin if i = High(Argv) then Exit(False); A.Session := Argv[i + 1]; Inc(i, 2); Continue; end;
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
  RegisterMemoryTools(Result);
  RegisterWebSearchTool(Result);
  RegisterWebFetchTool(Result);
  Skills := LoadSkillManifests(GetHome);
  RegisterSkills(Result, Skills);
end;

{ When the operator declared subagents in config.json, install the
  `spawn` tool into the registry — once MCP tools have already been
  bridged in so subagents can include them in their allowlist.
  Returns the created spawn tool so the caller can `Free` it during
  cleanup; nil when no subagents are configured. }
function MaybeRegisterSpawnTool(Cfg: TConfig; Provider: ILLMProvider;
                                 Reg: TToolRegistry; const Model: string): TSpawnTool;
var
  Ctx: TSubagentContext;
begin
  Result := nil;
  if (Reg = nil) or (Length(Cfg.Subagents) = 0) then Exit;
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := Model;
  Result := RegisterSpawnTool(Reg, Ctx, Cfg.Subagents);
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
  Result.Parallel := True;
  Result.Fallbacks     := ResolveFallbacks(Cfg);
  Result.Options       := DefaultChatOptions;
  { ToolsEnabled tracks the registry we are about to hand RunToolLoop
    so the system prompt stays in sync with what the model can
    actually call. Reg is nil when --no-tools is set (RunBuilder
    passes nil; see Run* call sites above) — deriving from the
    registry, not from A.NoTools, also handles the case where future
    callers nil out Reg for other reasons. }
  Result.Options.SystemPrompt  := BuildSystemPrompt(Cfg, A.SystemPrompt, Reg <> nil);
  Result.Options.ThinkingLevel := A.Thinking;
  if A.MaxTokens > 0 then Result.Options.MaxTokens := A.MaxTokens;
  Result.OnText        := nil;
  Result.OnToolCall    := Handlers.OnToolCall;
  Result.OnToolResult  := Handlers.OnToolResult;
  { Conversation-history compaction: on by default with picoclaw-ish
    defaults (80K-token threshold, last 8 turns preserved). The tool
    loop only pays the cost of a summariser round when the running
    history actually trips the threshold, so short conversations
    are unaffected. Channels that thread their own RunToolLoop
    config can opt in the same way. }
  Result.CompactEnabled := True;
  Result.CompactOpts    := DefaultCompactOptions;
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
  Spawn: TSpawnTool;
begin
  if not PickProvider(Cfg, A, Provider, Err) then
  begin
    WriteLn(Ansi.Yellow, '(offline preview — ', Err, ')', Ansi.Reset);
    WriteLn('You: ', Prompt);
    WriteLn('Assistant: <provider not configured; run `pasclaw onboard`>');
    Exit;
  end;

  { Resolve the effective model BEFORE registering the spawn tool.
    MaybeRegisterSpawnTool captures Model into the TSubagentContext
    by value; if we hand it an empty string the child subagent loop
    will fall back to the provider's GetDefaultModel instead of the
    user's --model selection. RunInteractive already does this in the
    right order — fixing the asymmetry here. (Codex P2 on PR #107.) }
  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;

  Reg := nil;
  if not A.NoTools then Reg := NewBuiltinRegistry(not A.NoHashline);
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  Handlers := TLoopHandlers.Create;
  try
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, Prompt);

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
    if Spawn <> nil then Spawn.Free;
    Reg.Free;
  end;
end;

procedure RunInteractive(const Cfg: TConfig; const A: TAgentArgs);
var
  Line: string;
  Provider: ILLMProvider;
  Err: string;
  Msgs: TMessageArray;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  Offline: Boolean;
  i: Integer;
  Names: TStringArray;
  MCPClients: TMCPClientList;
  Spawn: TSpawnTool;
  SystemPromptOverride: string;   { tracks the compacted system prompt across turns }
  ThinkingOn: Boolean;             { toggled by /think; cleared each turn after sending }
  CompactOptsLocal: TCompactOptions;
  CompactedLiveOpts: TChatOptions;
  Session: TSession;               { non-nil iff --session was passed }
begin
  SystemPromptOverride := '';
  Session := nil;
  Offline := not PickProvider(Cfg, A, Provider, Err);
  if Offline then
    WriteLn(Ansi.Yellow, '(offline preview — ', Err, ')', Ansi.Reset);
  WriteLn(Ansi.Dim, 'PasClaw interactive chat. /help for commands, /quit to exit.', Ansi.Reset);

  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
  Reg := nil;
  if not A.NoTools then Reg := NewBuiltinRegistry(not A.NoHashline);
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  Handlers := TLoopHandlers.Create;
  try
    SetLength(Msgs, 0);
    ThinkingOn := False;

    { Session resume: load Msgs + SystemPromptOverride from the
      session file on disk when --session was passed. A non-existent
      id gets created fresh (lets a script pre-seed an id like
      "daily-2026-06-01"). The session is saved after each turn
      below — so a Ctrl-C / crash mid-conversation only loses the
      currently-typed prompt, not the whole history. }
    if A.Session <> '' then
    begin
      Session := TSession.Create(A.Session);
      if Session.MetaExists then
      begin
        SetLength(Msgs, Length(Session.Messages));
        for i := 0 to High(Session.Messages) do Msgs[i] := Session.Messages[i];
        SystemPromptOverride := Session.Meta.SystemPromptOverride;
        WriteLn(Ansi.Dim, '(resumed session ', Session.Meta.Id,
                ' — ', Length(Msgs), ' messages)', Ansi.Reset);
      end
      else
        WriteLn(Ansi.Dim, '(new session ', Session.Meta.Id, ')', Ansi.Reset);
    end;

    while True do
    begin
      Write(Ansi.Bold, '> ', Ansi.Reset);
      if EOF then Break;
      ReadLn(Line);
      Line := Trim(Line);
      if (Line = '/quit') or (Line = '/exit') then Break;
      if (Line = '/reset') or (Line = '/new') then
      begin
        SetLength(Msgs, 0);
        SystemPromptOverride := '';   { drop the compacted summary too }
        { /new starts a brand-new session id so the existing one
          stays on disk for resume; /reset keeps the current session
          but clears its messages. Distinction matches openclaw and
          nanobot semantics. }
        if Session <> nil then
        begin
          if Line = '/new' then
          begin
            Session.Free;
            Session := TSession.Create('');   { fresh id }
            WriteLn(Ansi.Dim, '(new session ', Session.Meta.Id, ')', Ansi.Reset);
            Continue;
          end
          else
          begin
            Session.ClearMessages;
            Session.Meta.SystemPromptOverride := '';
            Session.Touch;
            Session.Save;
          end;
        end;
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
      if (Line = '/help') or (Line = '/?') then
      begin
        WriteLn('  /help     show this list');
        WriteLn('  /status   model + provider + message count + thinking state');
        WriteLn('  /new      clear conversation history (alias: /reset)');
        WriteLn('  /reset    clear conversation history');
        WriteLn('  /compact  force a one-shot summariser pass on the history now');
        WriteLn('  /think    toggle extended thinking on the next turn (if the provider supports it)');
        WriteLn('  /tools    list registered tools');
        WriteLn('  /quit     exit (alias: /exit)');
        Continue;
      end;
      if Line = '/status' then
      begin
        if Provider <> nil then
          WriteLn('  provider:  ', Provider.GetName)
        else
          WriteLn('  provider:  (offline)');
        WriteLn('  model:     ', Model);
        WriteLn('  messages:  ', Length(Msgs));
        if Reg <> nil then
          WriteLn('  tools:     ', Reg.Count)
        else
          WriteLn('  tools:     (disabled)');
        if ThinkingOn then
          WriteLn('  thinking:  on (next turn)')
        else
          WriteLn('  thinking:  off');
        if SystemPromptOverride <> '' then
          WriteLn('  compacted: yes (summary in system prompt)')
        else
          WriteLn('  compacted: no');
        Continue;
      end;
      if Line = '/think' then
      begin
        if (Provider <> nil) and (not Provider.SupportsThinking) then
        begin
          WriteLn(Ansi.Yellow, 'provider ', Provider.GetName,
                  ' does not support extended thinking — flag ignored.', Ansi.Reset);
          Continue;
        end;
        ThinkingOn := not ThinkingOn;
        if ThinkingOn then
          WriteLn(Ansi.Dim, '(thinking on for next turn)', Ansi.Reset)
        else
          WriteLn(Ansi.Dim, '(thinking off)', Ansi.Reset);
        Continue;
      end;
      if Line = '/compact' then
      begin
        if Length(Msgs) = 0 then
        begin
          WriteLn(Ansi.Dim, '(no history to compact)', Ansi.Reset);
          Continue;
        end;
        if Offline then
        begin
          WriteLn(Ansi.Yellow, '/compact needs a configured provider to summarise.', Ansi.Reset);
          Continue;
        end;
        CompactOptsLocal := DefaultCompactOptions;
        CompactOptsLocal.ThresholdTokens := 1;  { force the slice }
        CompactedLiveOpts := DefaultChatOptions;
        if SystemPromptOverride <> '' then
          CompactedLiveOpts.SystemPrompt := SystemPromptOverride;
        Msgs := CompactMessages(Provider, Model, Msgs,
                                 CompactedLiveOpts, CompactOptsLocal);
        SystemPromptOverride := CompactedLiveOpts.SystemPrompt;
        WriteLn(Ansi.Dim, '(history compacted; summary folded into system prompt)', Ansi.Reset);
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
      { After the first compaction the summary lives in
        LiveOptions.SystemPrompt inside RunToolLoop and gets returned
        via Loop.FinalSystemPrompt. We override here so the next turn
        ships the summary back to the provider; without it
        BuildSystemPrompt rebuilds the original prompt and the
        compacted summary leaks out of the conversation. }
      if SystemPromptOverride <> '' then
        LoopCfg.Options.SystemPrompt := SystemPromptOverride;
      { /think: apply ThinkingLevel for this turn, then clear so
        subsequent turns reset (matches the OpenClaw /think model —
        single-turn extended thinking). The user can /think again
        to keep it on. }
      if ThinkingOn then
      begin
        LoopCfg.Options.ThinkingLevel := 'medium';
        ThinkingOn := False;
      end;

      if RunToolLoop(LoopCfg, Msgs, Loop) then
      begin
        WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (', Provider.GetName, '/', Model, '):');
        WriteLn(Loop.Content);

        { Pick up the compacted history from RunToolLoop so the next
          interactive turn starts from the summarised state, not the
          full pre-compaction transcript (Codex PR #87 P2). If
          compaction didn't fire this turn, Loop.FinalMessages mirrors
          Msgs + new assistant/tool entries — same growth path as
          before. If it DID fire, Msgs shrinks to the compacted view
          and SystemPromptOverride below preserves the summary across
          subsequent BuildLoopConfig calls. }
        if Length(Loop.FinalMessages) > 0 then
        begin
          SetLength(Msgs, Length(Loop.FinalMessages) + 1);
          for i := 0 to High(Loop.FinalMessages) do
            Msgs[i] := Loop.FinalMessages[i];
          Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
        end
        else
        begin
          SetLength(Msgs, Length(Msgs) + 1);
          Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
        end;
        SystemPromptOverride := Loop.FinalSystemPrompt;

        { Persist after every successful turn — crash / Ctrl-C in
          the middle of the NEXT user prompt only loses what they
          were typing, not the existing conversation. }
        if Session <> nil then
        begin
          SetLength(Session.Messages, Length(Msgs));
          for i := 0 to High(Msgs) do Session.Messages[i] := Msgs[i];
          Session.Meta.SystemPromptOverride := SystemPromptOverride;
          Session.Meta.Model    := Model;
          if Provider <> nil then Session.Meta.Provider := Provider.GetName;
          Session.AutoTitle;
          Session.Touch;
          Session.Save;
        end;
      end;
    end;
  finally
    Handlers.Free;
    FreeMCPClients(MCPClients);
    if Spawn <> nil then Spawn.Free;
    Reg.Free;
    if Session <> nil then Session.Free;
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
  ConfigureSandbox(Cfg.Sandbox, '');
  try
    if A.Message <> '' then RunSingleTurn(Cfg, A, A.Message)
    else                    RunInteractive(Cfg, A);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
