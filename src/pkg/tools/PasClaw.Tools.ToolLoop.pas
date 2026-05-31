{
  PasClaw.Tools.ToolLoop - the core agent loop. Repeatedly calls the LLM
  with the running message history; if the response contains tool_calls,
  dispatches each through the registry, appends the tool result as a tool
  message, and continues. Mirrors pkg/tools/toolloop.go.
}
unit PasClaw.Tools.ToolLoop;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry,
  PasClaw.Agent.Compact;

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
    (* Compaction: when the running history exceeds Compact.ThresholdTokens,
       slice off the older portion, summarise it via Provider.Chat, and
       replace it with a single system message before the next round.
       CompactEnabled gates the whole thing — default off; the
       command-layer enables it from Cfg.Compaction. CompactOpts is the
       full options struct (threshold, recent-turn count, summary budget,
       and the OnBefore memory-flush hook). *)
    CompactEnabled: Boolean;
    CompactOpts:    TCompactOptions;
    (* Parallel tool dispatch. When True, RunToolLoop partitions each
       round's tool calls into batches: consecutive tcReadOnly calls
       (see PasClaw.Tools.Types.TToolCategory) form one parallel batch
       and run on dedicated worker threads; each tcMutating call is a
       batch of one and runs serially. When False, every call runs
       serially in array order — same as the pre-parallel behaviour.
       Default False on the record (zero-init); the CLI and the
       built-in components flip it on explicitly. *)
    Parallel:       Boolean;
    (* Provider fallback chain. When the primary Provider returns a
       retryable error (StatusCode = 0 / -1 / 408 / 429 / 5xx),
       RunToolLoop walks Fallbacks in order, calling Chat on each
       until one succeeds (StatusCode 2xx) or all fail. Empty
       array — same as the old behaviour, primary failure surfaces
       directly. Callers populate from TConfig.Fallbacks by
       resolving each name through NewProviderFromConfig. *)
    Fallbacks:      array of ILLMProvider;
  end;

  TToolLoopResult = record
    Content:     string;
    Iterations:  Integer;
    LastResp:    TLLMResponse;
    (* The final history at the moment RunToolLoop returns, with all
       in-flight compactions applied. Interactive callers (Cmd.Agent's
       RunInteractive, the TUI) read this back into their own message
       array so the NEXT turn starts from the compacted state instead
       of re-summarising the original transcript on every prompt
       (Codex PR #87 P2). Includes assistant + tool messages produced
       during the loop; leading mrSystem entries that compaction lifted
       into Options.SystemPrompt are NOT in this list. *)
    FinalMessages:    TMessageArray;
    FinalSystemPrompt: string;
  end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;

implementation

uses
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Hashline,
  PasClaw.Tools.Types;

type
  { Per-call work unit. The same record is filled in by a worker thread
    (parallel) or by an inline call (serial), then read by the main
    loop to append the tool_result to history. Workers never touch the
    history array directly — race-free by construction. }
  TToolCallDispatch = record
    Call:       TToolCall;
    ResultText: string;
    Err:        string;
  end;
  PToolCallDispatch = ^TToolCallDispatch;

  { Worker thread that runs one tool call's PreflightToolCall +
    Registry.RunTool + hashline retry logic, writes the result back
    into a TToolCallDispatch slot, exits. FreeOnTerminate is False —
    the main thread WaitFor's then Free's each worker in array order. }
  TToolCallWorker = class(TThread)
  private
    FCfg:  TToolLoopConfig;
    FSlot: PToolCallDispatch;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACfg: TToolLoopConfig; ASlot: PToolCallDispatch);
  end;

  TToolBatch      = array of Integer;        { indices into Resp.ToolCalls }
  TToolBatchArray = array of TToolBatch;

{ Provider error classes worth retrying on a fallback: network/TLS
  errors (StatusCode <= 0 — provider couldn't talk to the upstream),
  request-timeout (408), rate-limit (429), and any 5xx. Anything
  else (4xx auth / invalid request) is a configuration bug the
  fallback wouldn't fix. }
function IsRetryableStatus(Status: Integer): Boolean;
begin
  Result := (Status <= 0) or (Status = 408) or (Status = 429) or
            ((Status >= 500) and (Status < 600));
end;

function IsPatchFormatError(const Err: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Err);
  Result := (Pos('patch parse:', L) > 0) or
            (Pos('patch preflight:', L) > 0) or
            (Pos('unsupported inline payload token', L) > 0);
end;

function NormalizePatchForCompare(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if (C <> #13) and (C <> #10) and (C <> #9) and (C <> ' ') then
      Result[i] := C
    else
      Result[i] := #0;
  end;
  Result := StringReplace(Result, #0, '', [rfReplaceAll]);
end;

function CanonicalizeHashlinePatch(const Patch: string;
                                   out Canonical: string;
                                   out HasUnsupportedTokens: Boolean): Boolean;
var
  Sections: THLSectionArray;
  ParseErr: string;
  i, j: Integer;
  E: THLEdit;
  Sb: TStringBuilder;
begin
  Canonical := '';
  HasUnsupportedTokens := False;
  if not ParseHashlinePatch(Patch, Sections, ParseErr) then Exit(False);
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Sections) do
    begin
      if i > 0 then Sb.Append(#10);
      if Sections[i].HasFileHash then
        Sb.Append(FormatHashlineHeader(Sections[i].Path, Sections[i].FileHash))
      else
        Sb.Append(HL_FILE_PREFIX + Sections[i].Path);
      Sb.Append(#10);
      for j := 0 to High(Sections[i].Edits) do
      begin
        E := Sections[i].Edits[j];
        Sb.Append(IntToStr(E.Anchor.LineNum)).Append(HL_LINE_BODY_SEP).Append(#10);
        case E.PayloadKind of
          hpkReplace: Sb.Append(HL_PAYLOAD_REPLACE);
          hpkAbove:   Sb.Append(HL_PAYLOAD_ABOVE);
          hpkBelow:   Sb.Append(HL_PAYLOAD_BELOW);
        else
          HasUnsupportedTokens := True;
          Sb.Append(HL_PAYLOAD_REPLACE);
        end;
        Sb.Append(E.Text).Append(#10);
      end;
    end;
    Canonical := Sb.ToString;
  finally
    Sb.Free;
  end;
  Result := True;
end;

function PreflightToolCall(const Name, ArgsJSON: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Patch, VErr: string;
begin
  Result := True;
  Err := '';
  if Name <> 'fs_edit_hashline' then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then
  begin
    Err := 'invalid JSON arguments for fs_edit_hashline';
    Exit(False);
  end;
  try
    Patch := Obj.GetStr('patch', '');
  finally
    Obj.Free;
  end;
  if Patch = '' then Exit;
  if not ValidateHashlinePatchGrammar(Patch, VErr) then
  begin
    Err := 'patch preflight: ' + VErr + ' (remediation: regenerate patch with ¶path#hash header, anchor line like "N:" or "N-M:", then payload lines prefixed by |/↑/↓ only)';
    Exit(False);
  end;
end;

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

{ Run one tool call: PreflightToolCall → Registry.RunTool → fs_edit_hashline
  retry on format errors. Writes ResultText / Err into the dispatch slot.
  Pure with respect to shared state (uses per-call HTTP clients, reads
  the registry's name table read-only, calls thread-safe LogWarn), so it
  is safe to call from a worker thread alongside other DispatchOneToolCall
  invocations against different ToolCall inputs. Callers fire
  OnToolCall / OnToolResult on the main thread before / after; we
  deliberately don't invoke them in here to keep the worker stateless
  with respect to the embedder's event-handler thread affinity. }
procedure DispatchOneToolCall(const Cfg: TToolLoopConfig;
                               var D: TToolCallDispatch);
var
  RetryArgs, Patch, CanonicalPatch, N1, N2: string;
  ArgsObj: TJsonObject;
  HasUnsup: Boolean;
begin
  D.Err        := '';
  D.ResultText := '';
  RetryArgs    := D.Call.Func.Arguments;
  if not PreflightToolCall(D.Call.Func.Name, RetryArgs, D.Err) then
    D.ResultText := ''
  else if Cfg.Registry <> nil then
    D.ResultText := Cfg.Registry.RunTool(D.Call.Func.Name, RetryArgs, D.Err)
  else
    D.Err := 'no tool registry';

  if (D.Call.Func.Name = 'fs_edit_hashline') and IsPatchFormatError(D.Err) then
  begin
    LogWarn('tool-retry attempt=1 strategy=raw_hashline normalized_patch_len=%d has_unsupported_tokens=%s class=format_error',
      [Length(NormalizePatchForCompare(RetryArgs)), BoolToStr(False, True)]);
    ArgsObj := TJsonObject.Parse(RetryArgs);
    Patch := '';
    if ArgsObj <> nil then
    begin
      try
        Patch := ArgsObj.GetStr('patch', '');
      finally
        ArgsObj.Free;
      end;
    end;
    if (Patch <> '') and CanonicalizeHashlinePatch(Patch, CanonicalPatch, HasUnsup) then
    begin
      ArgsObj := TJsonObject.Create;
      try
        ArgsObj.PutStr('patch', CanonicalPatch);
        RetryArgs := ArgsObj.ToJSON;
      finally
        ArgsObj.Free;
      end;
      N1 := NormalizePatchForCompare(Patch);
      N2 := NormalizePatchForCompare(CanonicalPatch);
      LogWarn('tool-retry attempt=2 strategy=strict_hashline_formatter normalized_patch_len=%d has_unsupported_tokens=%s class=format_error',
        [Length(N2), BoolToStr(HasUnsup, True)]);
      D.Err := '';
      if not PreflightToolCall(D.Call.Func.Name, RetryArgs, D.Err) then
        D.ResultText := ''
      else if Cfg.Registry <> nil then
        D.ResultText := Cfg.Registry.RunTool(D.Call.Func.Name, RetryArgs, D.Err)
      else
        D.Err := 'no tool registry';
      if IsPatchFormatError(D.Err) and (N1 = N2) then
        D.Err := 'format_error: deterministic fallback exhausted; two consecutive retries had equivalent normalized patch content. ' +
                 'Regenerate patch intent or use safer apply-patch/unified-diff edit path.';
    end
    else
      D.Err := 'format_error: unable to canonicalize patch for deterministic retry; regenerate patch intent or use safer apply-patch/unified-diff edit path. original=' + D.Err;
  end;
end;

constructor TToolCallWorker.Create(const ACfg: TToolLoopConfig;
                                    ASlot: PToolCallDispatch);
begin
  inherited Create(True);  { suspended; main thread calls Start after all workers in the batch are constructed }
  FreeOnTerminate := False;
  FCfg  := ACfg;
  FSlot := ASlot;
end;

procedure TToolCallWorker.Execute;
begin
  try
    DispatchOneToolCall(FCfg, FSlot^);
  except
    on E: Exception do
    begin
      FSlot^.ResultText := '';
      FSlot^.Err        := 'worker exception: ' + E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ Partition a round's tool calls into batches that are safe to run in
  parallel within each batch. Read-only tools (Category = tcReadOnly)
  coalesce into one batch; each mutating tool is its own batch of one.
  Tools not found in the registry are treated as tcMutating (safe
  default — applies to skill / MCP tools and to any handler that
  forgot to set the Category field). Order is preserved across
  batches, so the agent loop appends tool_results in the same order
  the model emitted tool_use blocks.

  Calls is declared as an open array rather than `TToolCallArray`
  because the source is `TLLMResponse.ToolCalls`, which the providers
  record as an inline `array of TToolCall` — Delphi 12 dcc64 enforces
  strict named-type matching on dynamic-array parameters and rejects
  the bare-array → TToolCallArray pass-through with E2010. FPC happens
  to accept it either way, but the open-array form compiles cleanly
  under both. }
function PartitionToolBatches(const Calls: array of TToolCall;
                              Reg: TToolRegistry): TToolBatchArray;
var
  i: Integer;
  IsRO: Boolean;
  T: TTool;
  Cur: TToolBatch;

  procedure FlushCur;
  begin
    if Length(Cur) > 0 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Cur;
      SetLength(Cur, 0);
    end;
  end;

begin
  SetLength(Result, 0);
  SetLength(Cur, 0);
  for i := 0 to High(Calls) do
  begin
    IsRO := False;
    if (Reg <> nil) and Reg.Find(Calls[i].Func.Name, T) and (T.Category = tcReadOnly) then
      IsRO := True;
    if IsRO then
    begin
      SetLength(Cur, Length(Cur) + 1);
      Cur[High(Cur)] := i;
    end
    else
    begin
      { Flush the in-flight read-only batch (if any), then emit a
        batch-of-one for the mutating call. }
      FlushCur;
      SetLength(Cur, 1);
      Cur[0] := i;
      FlushCur;
    end;
  end;
  FlushCur;
end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;
var
  Iter, i, bi, j, fbi: Integer;
  Tools: TToolDefinitionArray;
  FallbackModel: string;
  Resp: TLLMResponse;
  Hist: TMessageArray;
  LiveOptions: TChatOptions;
  Dispatches: array of TToolCallDispatch;
  Batches: TToolBatchArray;
  Batch: TToolBatch;
  Workers: array of TToolCallWorker;
begin
  Loop.Content    := '';
  Loop.Iterations := 0;

  if Cfg.Provider = nil then Exit(False);

  { Copy input messages to a growable history. }
  SetLength(Hist, Length(Messages));
  for i := 0 to High(Messages) do Hist[i] := Messages[i];

  { Local mutable copy of Cfg.Options so compaction can fold the
    summary into LiveOptions.SystemPrompt without touching the
    caller's const Cfg. The provider call uses LiveOptions, not
    Cfg.Options, from here on. }
  LiveOptions := Cfg.Options;

  if Cfg.Registry <> nil then
    Tools := Cfg.Registry.ToProviderDefs
  else
    SetLength(Tools, 0);

  Iter := 0;
  while Iter < Cfg.MaxIterations do
  begin
    Inc(Iter);
    LogDebug('toolloop iteration %d / %d', [Iter, Cfg.MaxIterations]);

    { Pre-call compaction. NeedsCompact is a cheap token estimate;
      only when it trips do we pay for a summariser round.
      CompactMessages may rewrite Hist AND modify
      LiveOptions.SystemPrompt — the summary folds into the system
      prompt because both OpenAI and Anthropic builders silently
      drop in-message mrSystem entries when SystemPrompt is set
      (Codex PR #87 P1). Returns verbatim on summariser failure,
      so a broken summary can never wipe live context. }
    if Cfg.CompactEnabled and
       NeedsCompact(Hist, Cfg.CompactOpts.ThresholdTokens) then
      Hist := CompactMessages(Cfg.Provider, Cfg.Model, Hist,
                               LiveOptions, Cfg.CompactOpts);

    Resp := Cfg.Provider.Chat(Hist, Tools, Cfg.Model, LiveOptions);
    { Provider fallback. Retryable conditions: HTTP 408 / 429 / 5xx,
      and StatusCode <= 0 (network / TLS / pre-HTTP failure that the
      provider couldn't classify). Walk Cfg.Fallbacks in order until
      one returns a 2xx.

      Model selection per fallback: ask the fallback's own
      GetDefaultModel — anthropic-only model names ("claude-opus-4-7")
      passed verbatim to an OpenAI fallback would fail at the remote
      API and trigger the next fallback even when the chain was
      otherwise healthy. We only fall back to Cfg.Model when the
      fallback explicitly returns '' for its default. A per-fallback
      override (Cfg.FallbackModels: array of string) is a clean
      follow-up but the GetDefaultModel path gets the right behaviour
      out of the box for the catalog providers we ship. }
    if IsRetryableStatus(Resp.StatusCode) and (Length(Cfg.Fallbacks) > 0) then
    begin
      LogWarn('provider primary returned status=%d, walking %d fallback(s)',
              [Resp.StatusCode, Length(Cfg.Fallbacks)]);
      for fbi := 0 to High(Cfg.Fallbacks) do
      begin
        if Cfg.Fallbacks[fbi] = nil then Continue;
        FallbackModel := Cfg.Fallbacks[fbi].GetDefaultModel;
        if FallbackModel = '' then FallbackModel := Cfg.Model;
        LogDebug('fallback %d: trying %s with model=%s',
                 [fbi, Cfg.Fallbacks[fbi].GetName, FallbackModel]);
        Resp := Cfg.Fallbacks[fbi].Chat(Hist, Tools, FallbackModel, LiveOptions);
        if not IsRetryableStatus(Resp.StatusCode) then
        begin
          LogWarn('fallback hit: %s status=%d',
                  [Cfg.Fallbacks[fbi].GetName, Resp.StatusCode]);
          Break;
        end;
      end;
    end;
    Loop.LastResp := Resp;

    { Stream the text part to the caller now so they can show progress. }
    if Assigned(Cfg.OnText) and (Resp.Content <> '') then
      Cfg.OnText(Resp.Content);

    if Length(Resp.ToolCalls) = 0 then
    begin
      Loop.Content    := Resp.Content;
      Loop.Iterations := Iter;
      Loop.FinalMessages    := Hist;
      Loop.FinalSystemPrompt := LiveOptions.SystemPrompt;
      Exit(True);
    end;

    { Append the assistant turn (text + tool calls) and dispatch each call. }
    SetLength(Hist, Length(Hist) + 1);
    Hist[High(Hist)] := MakeAssistantWithToolCalls(Resp.Content, Resp.ToolCalls);

    { Allocate one dispatch slot per tool call upfront so workers can hold
      a pointer to a slot without worrying about array reallocation. }
    SetLength(Dispatches, Length(Resp.ToolCalls));
    for i := 0 to High(Resp.ToolCalls) do
    begin
      Dispatches[i].Call       := Resp.ToolCalls[i];
      Dispatches[i].ResultText := '';
      Dispatches[i].Err        := '';
    end;

    { Partition into batches: read-only calls fan out concurrently
      within a batch when Cfg.Parallel is on; mutating calls each
      get a batch of one and stay serial. Order across batches is
      preserved, so tool_results land in Hist in the same order the
      model emitted them. }
    Batches := PartitionToolBatches(Resp.ToolCalls, Cfg.Registry);

    for bi := 0 to High(Batches) do
    begin
      Batch := Batches[bi];

      { Fire OnToolCall for every call in the batch on the main thread,
        in array order, before any worker starts. Embedders rely on
        OnToolCall firing before its matching OnToolResult and on the
        announcements appearing in the same order the model produced
        the tool_use blocks. }
      for j := 0 to High(Batch) do
        if Assigned(Cfg.OnToolCall) then
          Cfg.OnToolCall(Dispatches[Batch[j]].Call.Func.Name,
                          Dispatches[Batch[j]].Call.Func.Arguments);

      if Cfg.Parallel and (Length(Batch) > 1) then
      begin
        { Parallel batch: spawn one TThread per call, suspended; Start
          all in array order; WaitFor all in array order; Free each
          worker after WaitFor. }
        SetLength(Workers, Length(Batch));
        for j := 0 to High(Batch) do
          Workers[j] := TToolCallWorker.Create(Cfg, @Dispatches[Batch[j]]);
        for j := 0 to High(Workers) do
          Workers[j].Start;
        for j := 0 to High(Workers) do
        begin
          Workers[j].WaitFor;
          Workers[j].Free;
        end;
        SetLength(Workers, 0);
      end
      else
      begin
        { Serial batch (or Parallel disabled): just run inline on the
          main thread. Same DispatchOneToolCall the workers use, so
          fs_edit_hashline retry semantics are identical. }
        for j := 0 to High(Batch) do
          DispatchOneToolCall(Cfg, Dispatches[Batch[j]]);
      end;

      { Fire OnToolResult and append tool_result messages on the main
        thread, in array order, AFTER the whole batch has joined. }
      for j := 0 to High(Batch) do
      begin
        if Assigned(Cfg.OnToolResult) then
          Cfg.OnToolResult(Dispatches[Batch[j]].Call.Func.Name,
                           Dispatches[Batch[j]].ResultText,
                           Dispatches[Batch[j]].Err);
        SetLength(Hist, Length(Hist) + 1);
        if Dispatches[Batch[j]].Err <> '' then
          Hist[High(Hist)] := MakeToolResult(Dispatches[Batch[j]].Call.Id,
                                              'ERROR: ' + Dispatches[Batch[j]].Err)
        else
          Hist[High(Hist)] := MakeToolResult(Dispatches[Batch[j]].Call.Id,
                                              Dispatches[Batch[j]].ResultText);
      end;
    end;
  end;

  { Max iterations exhausted; return whatever we last got. }
  Loop.Content    := Resp.Content;
  Loop.Iterations := Iter;
  Loop.FinalMessages    := Hist;
  Loop.FinalSystemPrompt := LiveOptions.SystemPrompt;
  Result := True;
end;

end.
