(*
  PasClaw.TUI - terminal UI for `pasclaw tui`.

  Two implementations behind the same TTUI class shape:

    {$IFNDEF FPC}  Delphi build: positioned full-screen TUI built on
                   MVCFramework.Console (vendored in
                   src/pkg/vendor/dmvcframework/, Apache-2.0). Two
                   panes — session list on the left, chat scrollback +
                   input on the right — themed via ConsoleThemeNavy.
                   Per-frame redraw (~30 fps), KeyPressed/GetKey loop,
                   background TRunToolLoopThread for the LLM call so
                   the chat pane stays responsive (spinner + steering
                   counter visible while the loop runs).

    {$IFDEF FPC}   FPC build: original line-based ANSI renderer.
                   Works in any vt100-class terminal including
                   tmux/screen scrollback. No external deps. Session
                   integration not wired here — `pasclaw tui` on FPC
                   stays in-memory; Delphi build gets the full session
                   list / persistence. (Cmd_TUI_Run sets SessionId
                   regardless; the FPC branch ignores it.)

  Both share the same loop shape (TRunToolLoopThread + DoneEvent).
  The differences are visual + how chat history is presented.
*)
unit PasClaw.TUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Registry,
  PasClaw.Session.Store;

type
  {$IFNDEF FPC}
  TFocus = (foSessions, foChat);
  {$ENDIF}

  TTUI = class
  private
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FModel:    string;
    FQuit:     Boolean;
    {$IFNDEF FPC}
    { positioned-TUI state — see Run() for the per-frame loop }
    FFocus:             TFocus;
    FSession:           TSession;
    FSessions:          TSessionMetaArray;
    FSelSessIdx:        Integer;
    FSessScroll:        Integer;
    FChatScroll:        Integer;       { lines back from the bottom; 0 = pinned to latest }
    FInputBuf:          string;
    FLoopThread:        TObject;       { TRunToolLoopThread — opaque here to avoid forward-decl gymnastics }
    FLoopStartedAt:     TDateTime;
    FSpinnerFrame:      Integer;
    FConfirmDelete:     Boolean;
    FLastSessRefresh:   TDateTime;
    FLastResizeW:       Integer;
    FLastResizeH:       Integer;
    FStatusFlash:       string;        { one-line transient message shown in footer }
    FStatusFlashUntil:  TDateTime;
    FLoopSessionId:     string;        { id of the session that originated the
                                         in-flight loop — Codex P1 on PR #122:
                                         if the user swaps sessions while a
                                         loop is running, the result must land
                                         in the ORIGINATING session, never in
                                         whatever FSession now points at }
    procedure DrawFrame;
    procedure DrawHeaderBar(W: Integer);
    procedure DrawSessionPane(X, Y, W, H: Integer);
    procedure DrawChatPane(X, Y, W, H: Integer);
    procedure DrawFooterBar(Y, W: Integer);
    procedure HandleKey(Key: Integer);
    procedure HandleSessionKey(Key: Integer);
    procedure HandleChatKey(Key: Integer);
    procedure SubmitInput;
    procedure StartTurn(const UserText: string);
    procedure PollLoopWorker;
    procedure RefreshSessions;
    procedure SelectSession(Id: string);
    procedure StartNewSession;
    procedure DeleteSelectedSession;
    procedure PersistSession;
    procedure Flash(const Msg: string);
    function CurrentSpinnerChar: Char;
    {$ENDIF}
    procedure DrawHeader;
    procedure ShowHelp;
    procedure ShowTools;
    procedure HandleSlashCommand(const Cmd: string);
    procedure HandleUserInput(const Text: string);
  public
    (* Operator's prompt-cache settings. Defaults to default-on (matches
       DefaultChatOptions). Cmd_TUI_Run copies Cfg.PromptCache into this
       after construction so `prompt_cache.enabled: false` in config.json
       turns caching off here too — see PasClaw.Config.ApplyPromptCacheConfig
       and Codex P2 on PR #118. *)
    PromptCacheEnabled: Boolean;
    PromptCacheTTL:     string;
    (* Initial session to load. Empty = auto-allocate a fresh id (Delphi
       branch only; FPC branch ignores it). Cmd_TUI_Run forwards
       --session here, mirroring `pasclaw agent --session <id>`. *)
    SessionId:          string;
    constructor Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
    {$IFNDEF FPC}destructor Destroy; override;{$ENDIF}
    procedure Run;
  end;

implementation

uses
  Classes,
  SyncObjs,
  DateUtils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Steering
  {$IFNDEF FPC}
  , Math, StrUtils,
  MVCFramework.Console, LoggerPro.AnsiColors
  {$ENDIF}
  ;

type
  TRunToolLoopThread = class(TThread)
  private
    FCfg: TToolLoopConfig;
    FMsgs: array of TMessage;
    FLoop: TToolLoopResult;
    FOk: Boolean;
    FErr: string;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACfg: TToolLoopConfig; const AMsgs: array of TMessage);
    destructor Destroy; override;
    property LoopResult: TToolLoopResult read FLoop;
    property Ok: Boolean read FOk;
    property Err: string read FErr;
    property DoneEvent: TEvent read FDone;
  end;

function ResolveRequestTimeoutSeconds: Integer;
var
  V: string;
  N: Integer;
begin
  Result := 120;
  V := Trim(GetEnvironmentVariable('PASCLAW_REQUEST_TIMEOUT'));
  if V = '' then Exit;
  if TryStrToInt(V, N) and (N > 0) then
    Result := N;
end;

constructor TRunToolLoopThread.Create(const ACfg: TToolLoopConfig; const AMsgs: array of TMessage);
var
  i: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCfg := ACfg;
  SetLength(FMsgs, Length(AMsgs));
  for i := 0 to High(AMsgs) do
    FMsgs[i] := AMsgs[i];
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TRunToolLoopThread.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TRunToolLoopThread.Execute;
begin
  try
    FOk := RunToolLoop(FCfg, FMsgs, FLoop);
  except
    on E: Exception do
    begin
      FOk := False;
      FErr := E.Message;
    end;
  end;
  FDone.SetEvent;
end;


constructor TTUI.Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
begin
  inherited Create;
  FProvider := Provider;
  FRegistry := Registry;
  FModel    := Model;
  PromptCacheEnabled := True;
  PromptCacheTTL     := '';
end;

function StatusLine(Provider: ILLMProvider; const Model: string;
                    Registry: TToolRegistry): string;
begin
  if Provider <> nil then
    Result := Provider.GetName + '/' + Model
  else
    Result := 'offline';
  if Registry <> nil then
    Result := Result + '  tools:' + IntToStr(Registry.Count);
end;

{ ============================== Delphi (rich) ============================== }
{$IFNDEF FPC}

destructor TTUI.Destroy;
const
  CleanupWaitMs = 250;
var
  Worker: TRunToolLoopThread;
begin
  if FLoopThread <> nil then
  begin
    Worker := TRunToolLoopThread(FLoopThread);
    Worker.Terminate;
    { Bounded wait — RunToolLoop doesn't poll Terminated, so a slow
      provider HTTP call or hung shell-tool can block WaitFor
      indefinitely. Give it a quarter second to wrap up cleanly,
      otherwise hand ownership to the OS via FreeOnTerminate and
      let the process teardown reap it. Codex P2 on PR #122. }
    if Worker.DoneEvent.WaitFor(CleanupWaitMs) = wrSignaled then
    begin
      Worker.WaitFor;
      Worker.Free;
    end
    else
      Worker.FreeOnTerminate := True;
    FLoopThread := nil;
  end;
  FSession.Free;
  inherited Destroy;
end;

procedure TTUI.Flash(const Msg: string);
begin
  FStatusFlash := Msg;
  FStatusFlashUntil := IncSecond(Now, 3);
end;

function TTUI.CurrentSpinnerChar: Char;
const
  Frames: array[0..3] of Char = ('|', '/', '-', '\');
begin
  if FLoopThread = nil then
    Result := ' '
  else
    Result := Frames[FSpinnerFrame mod 4];
end;

procedure TTUI.RefreshSessions;
var
  i: Integer;
begin
  FSessions := ListSessions;
  FLastSessRefresh := Now;
  { Keep selection on the same session id when possible. }
  if (FSession <> nil) and (Length(FSessions) > 0) then
  begin
    FSelSessIdx := -1;
    for i := 0 to High(FSessions) do
      if FSessions[i].Id = FSession.Meta.Id then
      begin
        FSelSessIdx := i;
        Break;
      end;
    if FSelSessIdx < 0 then FSelSessIdx := 0;
  end
  else if FSelSessIdx < 0 then
    FSelSessIdx := 0
  else if FSelSessIdx >= Length(FSessions) then
    FSelSessIdx := Length(FSessions) - 1;
end;

procedure TTUI.PersistSession;
begin
  if FSession = nil then Exit;
  FSession.Meta.Model := FModel;
  if FProvider <> nil then FSession.Meta.Provider := FProvider.GetName;
  FSession.AutoTitle;
  FSession.Touch;
  FSession.Save;
end;

procedure TTUI.SelectSession(Id: string);
begin
  { Persist anything pending on the current session before swapping. }
  if (FSession <> nil) and (Length(FSession.Messages) > 0) then
    PersistSession;
  FSession.Free;
  if Id = '' then Id := NewSessionId;
  FSession := TSession.Create(Id);
  FChatScroll := 0;
  FInputBuf := '';
  Flash('session: ' + FSession.Meta.Id);
  RefreshSessions;
end;

procedure TTUI.StartNewSession;
begin
  SelectSession('');
end;

procedure TTUI.DeleteSelectedSession;
var
  Id: string;
begin
  if (FSelSessIdx < 0) or (FSelSessIdx >= Length(FSessions)) then Exit;
  Id := FSessions[FSelSessIdx].Id;
  if (FSession <> nil) and (FSession.Meta.Id = Id) then
  begin
    { Deleting the currently-loaded session: drop it, spawn a fresh
      one to fill the vacancy. Matches `pasclaw session delete` +
      `/new` semantics. }
    FSession.Free;
    FSession := nil;
  end;
  if DeleteSession(Id) then
  begin
    ClearSteering(Id);
    Flash('deleted ' + Id);
  end
  else
    Flash('delete failed: ' + Id);
  if FSession = nil then
  begin
    FSession := TSession.Create('');
    FInputBuf := '';
    FChatScroll := 0;
  end;
  RefreshSessions;
  FConfirmDelete := False;
end;

procedure TTUI.StartTurn(const UserText: string);
var
  Cfg: TToolLoopConfig;
  Worker: TRunToolLoopThread;
begin
  if (FProvider = nil) or (Trim(UserText) = '') then Exit;
  if FLoopThread <> nil then Exit;   { already in flight }

  { Append the user's turn to history BEFORE kicking off the loop so
    it shows up in the chat pane immediately (next redraw). }
  SetLength(FSession.Messages, Length(FSession.Messages) + 1);
  FSession.Messages[High(FSession.Messages)] := MakeMessage(mrUser, UserText);

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := FModel;
  Cfg.MaxIterations := 6;
  Cfg.Parallel      := True;
  Cfg.Options       := DefaultChatOptions;
  Cfg.Options.CacheEnabled := PromptCacheEnabled;
  Cfg.Options.CacheTTL     := PromptCacheTTL;
  if FSession <> nil then
  begin
    Cfg.Options.CacheKey := FSession.Meta.Id;
    Cfg.SteeringKey      := FSession.Meta.Id;
  end;
  Cfg.OnText        := nil;
  Cfg.OnToolCall    := nil;
  Cfg.OnToolResult  := nil;

  Worker := TRunToolLoopThread.Create(Cfg, FSession.Messages);
  Worker.Start;
  FLoopThread     := Worker;
  FLoopSessionId  := FSession.Meta.Id;
  FLoopStartedAt  := Now;
  FChatScroll     := 0;
end;

{ Apply a completed loop result back to its ORIGINATING session.
  When the originating session is still the currently-loaded one
  (FSession.Meta.Id matches), update FSession in place and persist.
  When the user has swapped sessions while the loop was in flight,
  open the originating session by id, append + persist, free —
  the currently-loaded FSession is never touched. Codex P1 on PR
  #122: without this gate a parallel turn would overwrite a fresh
  conversation with another session's history. }
procedure ApplyLoopResultTo(const SessionId: string; const Loop: TToolLoopResult;
                            CurrentSession: TSession);
var
  Target: TSession;
  i: Integer;
  OwnsTarget: Boolean;
begin
  if (CurrentSession <> nil) and (CurrentSession.Meta.Id = SessionId) then
  begin
    Target := CurrentSession;
    OwnsTarget := False;
  end
  else
  begin
    Target := TSession.Create(SessionId);
    OwnsTarget := True;
  end;
  try
    if Length(Loop.FinalMessages) > 0 then
    begin
      SetLength(Target.Messages, Length(Loop.FinalMessages) + 1);
      for i := 0 to High(Loop.FinalMessages) do
        Target.Messages[i] := Loop.FinalMessages[i];
      Target.Messages[High(Target.Messages)] :=
        MakeMessage(mrAssistant, Loop.Content);
    end
    else
    begin
      SetLength(Target.Messages, Length(Target.Messages) + 1);
      Target.Messages[High(Target.Messages)] :=
        MakeMessage(mrAssistant, Loop.Content);
    end;
    Target.AutoTitle;
    Target.Touch;
    Target.Save;
  finally
    if OwnsTarget then Target.Free;
  end;
end;

procedure AppendErrorTo(const SessionId: string; const ErrText: string;
                       CurrentSession: TSession);
var
  Target: TSession;
  OwnsTarget: Boolean;
begin
  if (CurrentSession <> nil) and (CurrentSession.Meta.Id = SessionId) then
  begin
    Target := CurrentSession;
    OwnsTarget := False;
  end
  else
  begin
    Target := TSession.Create(SessionId);
    OwnsTarget := True;
  end;
  try
    SetLength(Target.Messages, Length(Target.Messages) + 1);
    Target.Messages[High(Target.Messages)] := MakeMessage(mrAssistant, ErrText);
    Target.Touch;
    Target.Save;
  finally
    if OwnsTarget then Target.Free;
  end;
end;

procedure TTUI.PollLoopWorker;
var
  Worker: TRunToolLoopThread;
  Loop: TToolLoopResult;
  TimeoutSec: Integer;
  Elapsed: Integer;
begin
  if FLoopThread = nil then Exit;
  Worker := TRunToolLoopThread(FLoopThread);

  TimeoutSec := ResolveRequestTimeoutSeconds;
  Elapsed := SecondsBetween(Now, FLoopStartedAt);
  if (Elapsed >= TimeoutSec)
     and (Worker.DoneEvent.WaitFor(0) <> wrSignaled) then
  begin
    LogWarn('tui tool-loop timeout after %ds', [TimeoutSec]);
    Worker.Terminate;
    Worker.FreeOnTerminate := True;
    AppendErrorTo(FLoopSessionId,
      Format('(request timed out after %ds)', [TimeoutSec]),
      FSession);
    FLoopThread := nil;
    FLoopSessionId := '';
    Flash(Format('timed out after %ds', [TimeoutSec]));
    RefreshSessions;
    Exit;
  end;

  if Worker.DoneEvent.WaitFor(0) <> wrSignaled then Exit;
  Worker.WaitFor;

  if Worker.Ok then
  begin
    Loop := Worker.LoopResult;
    ApplyLoopResultTo(FLoopSessionId, Loop, FSession);
    if FLoopSessionId <> FSession.Meta.Id then
      Flash('result -> ' + FLoopSessionId);
    RefreshSessions;
  end
  else
  begin
    LogWarn('tui tool-loop failed: %s', [Worker.Err]);
    AppendErrorTo(FLoopSessionId, '(tool loop failed)', FSession);
    RefreshSessions;
  end;

  Worker.Free;
  FLoopThread := nil;
  FLoopSessionId := '';
end;

procedure TTUI.SubmitInput;
var
  Text: string;
begin
  Text := Trim(FInputBuf);
  if Text = '' then Exit;

  { Slash-command shortcuts — without these the model gets "/quit"
    as a literal user message because StartTurn doesn't filter. The
    new TUI exposes most of these as dedicated keys (Q for quit,
    N for new session) but users coming from `pasclaw agent` reach
    for the slashes by reflex. Common ones; others flash a hint. }
  if (Length(Text) > 0) and (Text[1] = '/') then
  begin
    if (Text = '/quit') or (Text = '/exit') or (Text = '/q') then
      FQuit := True
    else if Text = '/new' then
      StartNewSession
    else if Text = '/clear' then
    begin
      if FSession <> nil then
      begin
        SetLength(FSession.Messages, 0);
        PersistSession;
        Flash('history cleared');
      end;
    end
    else if Text = '/help' then
      Flash('keys: Tab swap pane | N new | D del | Q quit')
    else if (Text = '/tools') and (FRegistry <> nil) then
      Flash(Format('registered tools: %d', [FRegistry.Count]))
    else
      Flash('unknown: ' + Text);
    FInputBuf := '';
    Exit;
  end;

  { When a loop is already running, queue the input as steering so
    the running loop can pick it up at the top of its next iteration
    (PR #120 mechanism). Route to FLoopSessionId — the originating
    session — not FSession.Meta.Id, in case the user swapped panes
    while the loop was in flight. Same Codex P1 fix as PollLoopWorker. }
  if FLoopThread <> nil then
  begin
    if PushSteering(FLoopSessionId, Text) then
      Flash('steering queued')
    else
      Flash('steer push failed');
    FInputBuf := '';
    Exit;
  end;

  StartTurn(Text);
  FInputBuf := '';
end;

procedure TTUI.HandleSessionKey(Key: Integer);
begin
  { Delete-confirm mode short-circuits — Y deletes, anything else
    (including N from the [Y]es/[N]o footer hint) just dismisses
    the prompt. Without this gate, N would dismiss AND start a new
    session, which contradicts the advertised "N cancel" footer.
    Codex P2 on PR #122. }
  if FConfirmDelete then
  begin
    case Key of
      Ord('y'), Ord('Y'):
        DeleteSelectedSession;
    else
      FConfirmDelete := False;
    end;
    Exit;
  end;

  case Key of
    Ord('q'), Ord('Q'):
      { Q only quits from the session pane — chat-pane input must
        be able to contain the letter (Codex P1 on PR #122). }
      FQuit := True;
    KEY_UP:
      if FSelSessIdx > 0 then Dec(FSelSessIdx);
    KEY_DOWN:
      if FSelSessIdx < High(FSessions) then Inc(FSelSessIdx);
    KEY_ENTER:
      if (FSelSessIdx >= 0) and (FSelSessIdx <= High(FSessions)) then
        SelectSession(FSessions[FSelSessIdx].Id);
    Ord('n'), Ord('N'):
      StartNewSession;
    Ord('r'), Ord('R'):
      begin
        RefreshSessions;
        Flash('refreshed');
      end;
    Ord('d'), Ord('D'):
      begin
        FConfirmDelete := True;
        Flash('delete? y/n');
      end;
  end;
end;

procedure TTUI.HandleChatKey(Key: Integer);
var
  Ch: Char;
begin
  { Q with an empty input buffer quits — discoverability path so
    users coming from the session pane don't have to learn that
    Escape is the universal quit. With any input typed, Q falls
    through to the default-char branch so words like "question"
    work. Codex P1 on PR #122. }
  if ((Key = Ord('q')) or (Key = Ord('Q'))) and (FInputBuf = '') then
  begin
    FQuit := True;
    Exit;
  end;

  case Key of
    KEY_ENTER:
      SubmitInput;
    KEY_UP:
      { Arrow keys aren't useful in a single-line input buffer, so
        repurpose them as chat-scrollback paging. PgUp/PgDn aren't
        wired because DMVCFramework returns 33/34 for them on
        Windows, colliding with the printable '!' and '"' input
        bytes returned on Linux — no portable disambiguation. }
      Inc(FChatScroll, 5);
    KEY_DOWN:
      begin
        Dec(FChatScroll, 5);
        if FChatScroll < 0 then FChatScroll := 0;
      end;
    8, 127:   { Backspace — code differs by terminal; accept both }
      if Length(FInputBuf) > 0 then
        SetLength(FInputBuf, Length(FInputBuf) - 1);
  else
    { Printable ASCII / latin-1: append. We don't try to handle
      escape sequences or multi-byte UTF-8 here — DMVCFramework's
      GetKey on Linux returns the raw byte for printable chars, on
      Windows the VK_ codes for special keys; the printable range
      32..126 is safe everywhere. Higher bytes pass through and
      will render as their byte value on most terminals. }
    if (Key >= 32) and (Key < 256) then
    begin
      Ch := Chr(Key);
      FInputBuf := FInputBuf + Ch;
    end;
  end;
end;

procedure TTUI.HandleKey(Key: Integer);
const
  KEY_TAB = 9;
begin
  { Escape is the only global quit — Q/q reach the focused pane so
    the chat input can include the letter (typing "question" used
    to immediately quit the TUI). Codex P1 on PR #122. }
  if Key = KEY_ESCAPE then
  begin
    FQuit := True;
    Exit;
  end;
  if Key = KEY_TAB then
  begin
    if FFocus = foSessions then FFocus := foChat else FFocus := foSessions;
    FConfirmDelete := False;
    Exit;
  end;
  case FFocus of
    foSessions: HandleSessionKey(Key);
    foChat:     HandleChatKey(Key);
  end;
end;

procedure TTUI.DrawHeaderBar(W: Integer);
var
  Title, TimeStr, Line: string;
begin
  TimeStr := FormatDateTime('hh:nn:ss', Now);
  Title := ' PasClaw  ' + StatusLine(FProvider, FModel, FRegistry);
  Line := Title;
  if Length(Line) > W - Length(TimeStr) - 2 then
    Line := Copy(Line, 1, W - Length(TimeStr) - 2);
  while Length(Line) < W - Length(TimeStr) - 1 do
    Line := Line + ' ';
  Line := Line + TimeStr + ' ';
  if Length(Line) > W then Line := Copy(Line, 1, W);
  GotoXY(0, 0);
  WriteAnsiText(ConsoleTheme.HighlightText, Line);
end;

procedure TTUI.DrawFooterBar(Y, W: Integer);
var
  Hint, Status: string;
begin
  if FConfirmDelete then
    Hint := ' [Y]es delete  [N]o cancel  '
  else if FFocus = foSessions then
    Hint := ' [Tab] chat  [Up/Dn] nav  [Enter] open  [N]ew  [D]elete  [R]efresh  [Q]uit '
  else
    Hint := ' [Tab] sessions  [Enter] send  [Up/Dn] scroll  [Q]uit ';

  if Length(Hint) > W then Hint := Copy(Hint, 1, W);
  while Length(Hint) < W do Hint := Hint + ' ';
  GotoXY(0, Y);
  WriteAnsiText(ConsoleTheme.HighlightText, Hint);

  if (FStatusFlash <> '') and (CompareDateTime(Now, FStatusFlashUntil) <= 0) then
    Status := ' ' + FStatusFlash
  else
    Status := '';
  while Length(Status) < W do Status := Status + ' ';
  if Length(Status) > W then Status := Copy(Status, 1, W);
  GotoXY(0, Y + 1);
  WriteAnsiText(ConsoleTheme.Symbols, Status);
end;

procedure TTUI.DrawSessionPane(X, Y, W, H: Integer);
var
  i, Row, MaxRows: Integer;
  Header, Line, IdShort, Title: string;
  Sess: TSessionMeta;
  IsSelected: Boolean;
  Marker: string;
begin
  { Header row. }
  Header := ' Sessions';
  while Length(Header) < W do Header := Header + ' ';
  if Length(Header) > W then Header := Copy(Header, 1, W);
  GotoXY(X, Y);
  WriteAnsiText(ConsoleTheme.HighlightText, Header);

  { Reserve the last row for the count. Body rows = H - 2. }
  MaxRows := H - 2;
  if MaxRows < 1 then MaxRows := 1;

  { Auto-scroll so the selected item is visible. }
  if FSelSessIdx < FSessScroll then
    FSessScroll := FSelSessIdx
  else if FSelSessIdx >= FSessScroll + MaxRows then
    FSessScroll := FSelSessIdx - MaxRows + 1;
  if FSessScroll < 0 then FSessScroll := 0;

  for Row := 0 to MaxRows - 1 do
  begin
    i := FSessScroll + Row;
    GotoXY(X, Y + 1 + Row);
    if (i < 0) or (i > High(FSessions)) then
    begin
      WriteAnsiText(ConsoleTheme.Text, StringOfChar(' ', W));
      Continue;
    end;
    Sess := FSessions[i];
    IsSelected := (i = FSelSessIdx);

    { Compact id — yyyymmddTHHMMSS is 14 chars; show the date portion
      mm-dd plus the random tail. }
    IdShort := Copy(Sess.Id, 5, 4);
    if Length(IdShort) = 4 then
      IdShort := Copy(IdShort, 1, 2) + '-' + Copy(IdShort, 3, 2)
    else
      IdShort := Copy(Sess.Id, 1, 5);

    Title := Sess.Title;
    if Title = '' then Title := '(untitled)';

    if IsSelected and (FFocus = foSessions) then
      Marker := '>'
    else if IsSelected then
      Marker := '*'
    else
      Marker := ' ';

    Line := Format(' %s %s %s', [Marker, IdShort, Title]);
    if Length(Line) > W then Line := Copy(Line, 1, W);
    while Length(Line) < W do Line := Line + ' ';
    if IsSelected then
      WriteAnsiText(ConsoleTheme.Highlight, Line)
    else
      WriteAnsiText(ConsoleTheme.Text, Line);
  end;

  { Footer of session pane: count + provider hint. }
  Line := Format(' %d sessions', [Length(FSessions)]);
  if Length(Line) > W then Line := Copy(Line, 1, W);
  while Length(Line) < W do Line := Line + ' ';
  GotoXY(X, Y + H - 1);
  WriteAnsiText(ConsoleTheme.Symbols, Line);
end;

procedure RenderMsgLines(const Msg: TMessage; W: Integer; var Acc: TArray<string>);
var
  Header, Body, Line: string;
  Lines: TArray<string>;
  i: Integer;
begin
  case Msg.Role of
    mrUser:      Header := 'user';
    mrAssistant: Header := 'assistant';
    mrSystem:    Header := 'system';
    mrTool:      Header := 'tool';
  else
    Header := 'msg';
  end;
  if (Msg.Role = mrTool) and (Length(Msg.Name) > 0) then
    Header := Header + ' ' + Msg.Name;

  SetLength(Acc, Length(Acc) + 1);
  Acc[High(Acc)] := '__HDR__' + Header;

  Body := Msg.Content;
  if Trim(Body) = '' then
  begin
    if Length(Msg.ToolCalls) > 0 then
    begin
      for i := 0 to High(Msg.ToolCalls) do
      begin
        SetLength(Acc, Length(Acc) + 1);
        Acc[High(Acc)] := '  -> ' + Msg.ToolCalls[i].Func.Name + '(' +
                          Copy(Msg.ToolCalls[i].Func.Arguments, 1, W - 12) + ')';
      end;
    end;
  end
  else
  begin
    Lines := Body.Split([sLineBreak, #10, #13], TStringSplitOptions.None);
    for Line in Lines do
    begin
      if Length(Line) <= W - 2 then
      begin
        SetLength(Acc, Length(Acc) + 1);
        Acc[High(Acc)] := '  ' + Line;
      end
      else
      begin
        i := 1;
        while i <= Length(Line) do
        begin
          SetLength(Acc, Length(Acc) + 1);
          Acc[High(Acc)] := '  ' + Copy(Line, i, W - 2);
          Inc(i, W - 2);
        end;
      end;
    end;
  end;
  { Blank separator between messages. }
  SetLength(Acc, Length(Acc) + 1);
  Acc[High(Acc)] := '';
end;

procedure TTUI.DrawChatPane(X, Y, W, H: Integer);
const
  INPUT_ROWS = 2;   { divider + input }
var
  ChatTop, ChatH, ChatBottom: Integer;
  Lines: TArray<string>;
  i, Row, Pending: Integer;
  Line, RoleColor, InputLine, DividerLine: string;
  ShownFrom: Integer;
begin
  ChatTop := Y;
  ChatH := H - INPUT_ROWS;
  if ChatH < 1 then ChatH := 1;
  ChatBottom := ChatTop + ChatH - 1;

  { Render every message to a string list, then window into it. }
  SetLength(Lines, 0);
  if FSession <> nil then
    for i := 0 to High(FSession.Messages) do
      RenderMsgLines(FSession.Messages[i], W, Lines);

  { Clip scroll to valid range. }
  if FChatScroll < 0 then FChatScroll := 0;
  if FChatScroll > Length(Lines) - ChatH then
    FChatScroll := Length(Lines) - ChatH;
  if FChatScroll < 0 then FChatScroll := 0;

  if Length(Lines) > ChatH then
    ShownFrom := Length(Lines) - ChatH - FChatScroll
  else
    ShownFrom := 0;
  if ShownFrom < 0 then ShownFrom := 0;

  for Row := 0 to ChatH - 1 do
  begin
    i := ShownFrom + Row;
    GotoXY(X, ChatTop + Row);
    if (i < 0) or (i >= Length(Lines)) then
    begin
      WriteAnsiText(ConsoleTheme.Text, StringOfChar(' ', W));
      Continue;
    end;
    Line := Lines[i];
    if Pos('__HDR__', Line) = 1 then
    begin
      Line := Copy(Line, Length('__HDR__') + 1, MaxInt);
      if      Line = 'user'      then RoleColor := FORE_CYAN + STYLE_BRIGHT
      else if AnsiStartsStr('assistant', Line) then RoleColor := FORE_MAGENTA + STYLE_BRIGHT
      else if AnsiStartsStr('tool', Line)      then RoleColor := FORE_YELLOW
      else                                          RoleColor := FORE_GRAY;
      Line := ' ' + Line;
    end
    else
      RoleColor := ConsoleTheme.Text;
    if Length(Line) > W then Line := Copy(Line, 1, W);
    while Length(Line) < W do Line := Line + ' ';
    WriteAnsiText(RoleColor, Line);
  end;

  { Divider with steering counter + spinner + token meter. }
  if FSession <> nil then
    Pending := PendingSteeringCount(FSession.Meta.Id)
  else
    Pending := 0;
  DividerLine := Format(' steering: %d   %s ', [Pending, CurrentSpinnerChar]);
  while Length(DividerLine) < W do DividerLine := DividerLine + '-';
  if Length(DividerLine) > W then DividerLine := Copy(DividerLine, 1, W);
  GotoXY(X, ChatBottom + 1);
  WriteAnsiText(ConsoleTheme.Symbols, DividerLine);

  { Input line. Append a soft cursor when chat pane is focused. }
  if FFocus = foChat then
    InputLine := ' > ' + FInputBuf + '_'
  else
    InputLine := ' > ' + FInputBuf;
  if Length(InputLine) > W then
    InputLine := Copy(InputLine, Length(InputLine) - W + 1, W);
  while Length(InputLine) < W do InputLine := InputLine + ' ';
  GotoXY(X, ChatBottom + 2);
  WriteAnsiText(ConsoleTheme.Text, InputLine);
end;

procedure TTUI.DrawFrame;
var
  Size: TMVCConsoleSize;
  W, H, SessW, ChatX, ChatW, PaneH, ry: Integer;
  NarrowMsg: string;
begin
  Size := GetConsoleSize;
  W := Integer(Size.Columns);
  H := Integer(Size.Rows);

  { Detect resize → full ClrScr to drop any leftover characters. }
  if (W <> FLastResizeW) or (H <> FLastResizeH) then
  begin
    ClrScr;
    FLastResizeW := W;
    FLastResizeH := H;
  end;

  if (W < 60) or (H < 12) then
  begin
    GotoXY(0, 0);
    NarrowMsg := Format('(terminal too small: %dx%d; need 60x12+)', [W, H]);
    WriteAnsiText(ConsoleTheme.Symbols, NarrowMsg);
    Exit;
  end;

  SessW := 32;
  if W div 3 < SessW then SessW := W div 3;
  if SessW < 24 then SessW := 24;
  ChatX := SessW + 1;
  ChatW := W - ChatX;
  PaneH := H - 3;   { header row + 2 footer rows }
  if PaneH < 4 then PaneH := 4;

  DrawHeaderBar(W);
  DrawSessionPane(0, 1, SessW, PaneH);

  { Vertical divider between panes. }
  for ry := 1 to PaneH do
  begin
    GotoXY(SessW, ry);
    WriteAnsiText(ConsoleTheme.Symbols, '|');
  end;

  DrawChatPane(ChatX, 1, ChatW, PaneH);
  DrawFooterBar(H - 2, W);
end;

procedure TTUI.Run;
var
  Key: Integer;
begin
  EnableUTF8Console;
  EnableANSIColorConsole;
  SetConsoleTheme(ConsoleThemeNavy);
  HideCursor;
  ClrScr;

  FFocus := foChat;
  FQuit  := False;
  FInputBuf := '';
  FChatScroll := 0;
  FConfirmDelete := False;
  FStatusFlash := '';
  FLastResizeW := -1; FLastResizeH := -1;

  { Always allocate a session (PR #117 default-persist semantics).
    SessionId from --session is honoured: empty = fresh id; existing
    on disk = resume; missing on disk = pre-seed at that id. }
  FSession := TSession.Create(SessionId);
  RefreshSessions;

  Flash('session: ' + FSession.Meta.Id);

  try
    while not FQuit do
    begin
      PollLoopWorker;

      { Periodic ListSessions refresh so cron-side / parallel-CLI
        session changes show up without keystrokes. 3s cadence. }
      if SecondsBetween(Now, FLastSessRefresh) >= 3 then
        RefreshSessions;

      Inc(FSpinnerFrame);
      DrawFrame;

      if KeyPressed then
      begin
        Key := GetKey;
        HandleKey(Key);
      end
      else
        Sleep(50);
    end;
  finally
    ShowCursor;
    ClrScr;
    ResetConsole;
  end;
end;

{ The slash-command + Help/Tools surface from the old REPL stays
  available — but it's invoked from inside the input buffer now
  (typing "/help" + Enter) so users don't have to learn a new
  dispatch model. Empty stubs here keep the FPC-shared interface
  happy without re-implementing the legacy box renderer. }

procedure TTUI.DrawHeader;     begin end;
procedure TTUI.ShowHelp;       begin end;
procedure TTUI.ShowTools;      begin end;
procedure TTUI.HandleSlashCommand(const Cmd: string); begin end;
procedure TTUI.HandleUserInput(const Text: string);   begin end;

{$ELSE}
{ ============================= FPC (line-based) ============================ }

{$IFDEF UNIX}
const
  { TIOCGWINSZ encoding differs per OS. Linux picked a low number
    in the legacy unencoded range; Darwin/BSD use the IOCTL macro
    encoding _IOR('t', 104, struct winsize) = 0x40087468. Passing
    the wrong magic to ioctl() returns -1 and we silently fall
    back to the default 80-column width — which is what was
    happening on macOS before this gate landed. }
  {$IFDEF DARWIN}
  TIOCGWINSZ = $40087468;
  {$ELSE}
  TIOCGWINSZ = $5413;
  {$ENDIF}
type
  Twinsize = record
    ws_row, ws_col, ws_xpixel, ws_ypixel: Word;
  end;
function FpIoctl(fd: Integer; req: Cardinal; argp: Pointer): Integer; cdecl;
  external 'c' name 'ioctl';
{$ENDIF}

function TermWidth: Integer;
{$IFDEF UNIX}
var
  ws: Twinsize;
{$ENDIF}
begin
  Result := 80;
  {$IFDEF UNIX}
  FillChar(ws, SizeOf(ws), 0);
  if FpIoctl(1, TIOCGWINSZ, @ws) = 0 then
    if ws.ws_col > 0 then Result := ws.ws_col;
  {$ENDIF}
end;

procedure TTUI.DrawHeader;
var
  Left, Right: string;
  Pad, W: Integer;
begin
  Left  := Ansi.BoldBlue + 'PAS' + Ansi.BoldRed + 'CLAW' + Ansi.Reset;
  Right := Ansi.Dim + StatusLine(FProvider, FModel, FRegistry) + Ansi.Reset;
  W := TermWidth;
  Pad := W - 7 - Length(StatusLine(FProvider, FModel, FRegistry));
  if Pad < 2 then Pad := 2;
  WriteLn;
  WriteLn(Left, StringOfChar(' ', Pad), Right);
  WriteLn(Ansi.Dim, StringOfChar('-', TermWidth), Ansi.Reset);
end;

procedure TTUI.ShowHelp;
begin
  WriteLn(Ansi.Bold, 'TUI commands:', Ansi.Reset);
  WriteLn('  /help    show this');
  WriteLn('  /tools   list registered tools');
  WriteLn('  /clear   clear the screen');
  WriteLn('  /quit    exit');
end;

procedure TTUI.ShowTools;
var
  i: Integer;
  Names: TStringArray;
begin
  if FRegistry = nil then
  begin
    WriteLn(Ansi.Dim, '(no registry)', Ansi.Reset);
    Exit;
  end;
  Names := FRegistry.Names;
  WriteLn(Ansi.Bold, 'tools (', Length(Names), '):', Ansi.Reset);
  for i := 0 to High(Names) do WriteLn('  ', Names[i]);
end;

procedure TTUI.HandleSlashCommand(const Cmd: string);
begin
  if (Cmd = '/quit') or (Cmd = '/exit') or (Cmd = '/q') then begin FQuit := True; Exit; end;
  if Cmd = '/clear' then begin Write(#27'[2J', #27'[H'); DrawHeader; Exit; end;
  if Cmd = '/tools' then begin ShowTools; Exit; end;
  if Cmd = '/help'  then begin ShowHelp;  Exit; end;
  WriteLn(Ansi.Yellow, 'unknown command: ', Cmd, Ansi.Reset);
end;

procedure TTUI.HandleUserInput(const Text: string);
var
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  Cfg: TToolLoopConfig;
  W: TRunToolLoopThread;
  TimeoutSec: Integer;
  WaitRes: TWaitResult;
begin
  if FProvider = nil then
  begin
    WriteLn(Ansi.Yellow, 'pasclaw  > ', Ansi.Reset,
            '(offline - no provider configured)');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Text);

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := FModel;
  Cfg.MaxIterations := 6;
  Cfg.Parallel := True;
  Cfg.Options       := DefaultChatOptions;
  Cfg.Options.CacheEnabled := PromptCacheEnabled;
  Cfg.Options.CacheTTL     := PromptCacheTTL;
  Cfg.OnText        := nil;
  Cfg.OnToolCall    := nil;
  Cfg.OnToolResult  := nil;
  TimeoutSec        := ResolveRequestTimeoutSeconds;

  LogDebug('tool-loop start model=%s timeout=%ds', [FModel, TimeoutSec]);
  WriteLn(Ansi.Dim, '         [hint: press Ctrl+C to interrupt]', Ansi.Reset);
  W := TRunToolLoopThread.Create(Cfg, Msgs);
  W.Start;
  WaitRes := W.DoneEvent.WaitFor(TimeoutSec * 1000);
  if WaitRes = wrTimeout then
  begin
    LogWarn('tool-loop timeout after %ds (possible slow model response or deadlocked tool call)', [TimeoutSec]);
    WriteLn(Ansi.Red, 'pasclaw  > ', Ansi.Reset, Format('(request timed out after %ds)', [TimeoutSec]));
    W.Terminate;
    W.FreeOnTerminate := True;
    Exit;
  end;
  W.WaitFor;
  if not W.Ok then
  begin
    LogWarn('tool-loop failed: %s', [W.Err]);
    WriteLn(Ansi.Red, 'pasclaw  > ', Ansi.Reset, '(tool loop failed)');
    W.Free;
    Exit;
  end;
  Loop := W.LoopResult;
  W.Free;
  LogDebug('tool-loop end ok iters=%d', [Loop.Iterations]);
  Write(Ansi.BoldBlue, 'pasclaw', Ansi.Reset, '  > ');
  WriteLn(Loop.Content);
  if Loop.LastResp.Usage.InputTokens + Loop.LastResp.Usage.OutputTokens > 0 then
    WriteLn(Ansi.Dim, '         ',
      Format('[tokens in=%d out=%d, iters=%d]',
        [Loop.LastResp.Usage.InputTokens, Loop.LastResp.Usage.OutputTokens, Loop.Iterations]),
      Ansi.Reset);
end;

procedure TTUI.Run;
var
  Line: string;
begin
  Write(#27'[2J', #27'[H');
  DrawHeader;
  WriteLn(Ansi.Dim, '/help for commands, /quit to exit', Ansi.Reset);
  WriteLn;
  FQuit := False;
  while not FQuit do
  begin
    Write(Ansi.BoldBlue, 'you', Ansi.Reset, '      > ');
    if EOF then Break;
    ReadLn(Line);
    Line := Trim(Line);
    if Line = '' then Continue;
    if (Line[1] = '/') then
    begin
      HandleSlashCommand(Line);
      Continue;
    end;
    HandleUserInput(Line);
  end;
  WriteLn(Ansi.Dim, 'goodbye.', Ansi.Reset);
end;

{$ENDIF}

end.
