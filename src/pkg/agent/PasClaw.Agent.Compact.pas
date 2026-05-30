(*
  PasClaw.Agent.Compact - conversation-history compaction.

  When the tool loop's running history grows past a token budget, the
  next provider call risks overflowing the model's context window —
  either rejected outright (Anthropic / OpenAI return 400) or eating
  the user's quota for diminishing returns. Compaction replaces the
  older portion of the history with a single summarised system
  message, keeping the most recent N turns verbatim so the model
  still sees fresh context.

  Picoclaw does this; we left a stub in the Phase A memory PR. This
  unit ships the core mechanism; the tool loop wires it in.

  Shape:
    TCompactOptions   tuning knobs (token threshold, recent-turn
                       count, optional memory-flush callback).
    NeedsCompact      cheap token-count check; tool loop calls each
                       iteration before the LLM round.
    CompactMessages   does the work: slice off everything before
                       the last KeepRecentTurns, summarise the
                       sliced portion via Provider.Chat, return a
                       new message list with the summary as a
                       single system message followed by the
                       preserved tail.

  Memory-flush hook:
    OnBeforeCompact fires once, RIGHT before the summarisation call,
    with the full pre-compact history. The memory subsystem's
    intended use: write important facts / preferences / decisions
    to workspace/memory/MEMORY.md so the model can read them later
    via memory_search. Mirror's openclaw's "memory flush" pattern.
    Wave 1 just exposes the hook; the concrete writer lands with
    Memory Phase B.

  Defaults match what most Claude / GPT-4 deployments tolerate:
    ThresholdTokens   80_000   (compact well before the 100/200K cap)
    KeepRecentTurns   8        (last 4 user+assistant pairs verbatim)
    SummaryBudget     800      (tokens; the summariser is told to
                                 stay under this)
*)
unit PasClaw.Agent.Compact;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TCompactBeforeCallback = procedure(const Messages: array of TMessage) of object;

  TCompactOptions = record
    ThresholdTokens: Integer;
    KeepRecentTurns: Integer;
    SummaryBudget:   Integer;
    OnBefore:        TCompactBeforeCallback;
  end;

function DefaultCompactOptions: TCompactOptions;

(* True iff the combined message bodies estimate above
   ThresholdTokens. Cheap — uses the existing 4-chars-per-token
   heuristic from PasClaw.Tokenizer. Returns False unconditionally
   if Threshold <= 0 so a misconfigured threshold disables the
   feature instead of compacting on every call. *)
function NeedsCompact(const Messages: array of TMessage;
                      Threshold: Integer): Boolean;

(* Returns a new message list with the older portion replaced by a
   single summarised system message. Logic:
     1. If Length(Messages) <= KeepRecentTurns, return Messages
        verbatim — nothing to compact.
     2. Fire OnBefore (if set) with the full original list so the
        memory subsystem can persist anything it cares about.
     3. Build a prompt asking the provider to summarise the
        prefix portion (everything but the last KeepRecentTurns).
     4. Call Provider.Chat with that single-message conversation.
     5. Assemble: [original-system-messages if any] + [summary as
        new system message] + [last KeepRecentTurns of the input].
     6. On summariser failure, return the input verbatim and log
        warn — never replace context with a broken summary. *)
function CompactMessages(Provider: ILLMProvider; const Model: string;
                         const Messages: array of TMessage;
                         const Opts: TCompactOptions): TMessageArray;

implementation

uses
  PasClaw.Tokenizer,
  PasClaw.Logger;

function DefaultCompactOptions: TCompactOptions;
begin
  Result.ThresholdTokens := 80000;
  Result.KeepRecentTurns := 8;
  Result.SummaryBudget   := 800;
  Result.OnBefore        := nil;
end;

function NeedsCompact(const Messages: array of TMessage;
                      Threshold: Integer): Boolean;
var
  i, Total: Integer;
begin
  Result := False;
  if Threshold <= 0 then Exit;
  Total := 0;
  for i := 0 to High(Messages) do
  begin
    Total := Total + EstimateTokens(Messages[i].Content) + 4;   { envelope }
    if Total >= Threshold then Exit(True);
  end;
end;

function FormatRole(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else           Result := 'user';
  end;
end;

function BuildSummaryPrompt(const Slice: array of TMessage;
                             Budget: Integer): string;
var
  i: Integer;
  Lines: string;
begin
  Lines := '';
  for i := 0 to High(Slice) do
  begin
    Lines := Lines + '[' + FormatRole(Slice[i].Role) + ']' + sLineBreak;
    Lines := Lines + Trim(Slice[i].Content) + sLineBreak + sLineBreak;
  end;
  Result :=
    'Summarise the conversation below into a concise running record. ' +
    'Preserve: key user facts and preferences, decisions made, code ' +
    'paths or symbols referenced, errors encountered, and open questions. ' +
    'Drop: small talk, redundant restatements, tool output that has been ' +
    'superseded. Stay under ' + IntToStr(Budget) + ' tokens. Write as a ' +
    'compact note, not a dialogue.' + sLineBreak + sLineBreak +
    '--- conversation ---' + sLineBreak + sLineBreak +
    Lines;
end;

function CompactMessages(Provider: ILLMProvider; const Model: string;
                         const Messages: array of TMessage;
                         const Opts: TCompactOptions): TMessageArray;
var
  SliceLen, KeepLen, i, OutIdx: Integer;
  Slice, OneCall: array of TMessage;
  EmptyTools: array of TToolDefinition;
  CallOptions: TChatOptions;
  Resp: TLLMResponse;
  Summary: string;
begin
  Result := nil;
  KeepLen := Opts.KeepRecentTurns;
  if KeepLen < 0 then KeepLen := 0;

  if Length(Messages) <= KeepLen + 1 then
  begin
    { Nothing meaningful to compact — fewer turns than we'd
      preserve. Return verbatim. }
    SetLength(Result, Length(Messages));
    for i := 0 to High(Messages) do Result[i] := Messages[i];
    Exit;
  end;

  if Provider = nil then
  begin
    LogWarn('compact: no provider — skipping compaction, returning verbatim', []);
    SetLength(Result, Length(Messages));
    for i := 0 to High(Messages) do Result[i] := Messages[i];
    Exit;
  end;

  if Assigned(Opts.OnBefore) then
  try
    Opts.OnBefore(Messages);
  except
    on E: Exception do
      LogWarn('compact: OnBefore raised %s: %s — continuing', [E.ClassName, E.Message]);
  end;

  SliceLen := Length(Messages) - KeepLen;
  SetLength(Slice, SliceLen);
  for i := 0 to SliceLen - 1 do Slice[i] := Messages[i];

  SetLength(OneCall, 1);
  OneCall[0] := MakeMessage(mrUser,
                            BuildSummaryPrompt(Slice, Opts.SummaryBudget));

  CallOptions := DefaultChatOptions;
  CallOptions.MaxTokens := Opts.SummaryBudget * 2;   { allow some slack }
  if CallOptions.MaxTokens < 1024 then CallOptions.MaxTokens := 1024;

  SetLength(EmptyTools, 0);
  try
    Resp := Provider.Chat(OneCall, EmptyTools, Model, CallOptions);
  except
    on E: Exception do
    begin
      LogWarn('compact: summary call raised %s: %s — returning verbatim',
              [E.ClassName, E.Message]);
      SetLength(Result, Length(Messages));
      for i := 0 to High(Messages) do Result[i] := Messages[i];
      Exit;
    end;
  end;

  Summary := Trim(Resp.Content);
  if Summary = '' then
  begin
    LogWarn('compact: empty summary — returning verbatim', []);
    SetLength(Result, Length(Messages));
    for i := 0 to High(Messages) do Result[i] := Messages[i];
    Exit;
  end;

  { Build the compacted list: [summary as system message] + [last
    KeepLen messages]. Drop the sliced prefix entirely. Original
    system messages inside the slice get rolled into the summary
    body; that's intentional — the new system message replaces
    them as the canonical record of what happened. }
  SetLength(Result, 1 + KeepLen);
  Result[0] := MakeMessage(mrSystem,
                            '[Conversation summary so far]' + sLineBreak +
                            Summary);
  OutIdx := 1;
  for i := SliceLen to High(Messages) do
  begin
    Result[OutIdx] := Messages[i];
    Inc(OutIdx);
  end;

  LogInfo('compact: %d msgs → 1 summary + %d kept (summary ~%d tokens)',
          [Length(Messages), KeepLen, EstimateTokens(Summary)]);
end;

end.
