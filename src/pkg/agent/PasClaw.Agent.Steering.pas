(*
  PasClaw.Agent.Steering — mid-loop interrupt queue.

  Today a user mid-conversation can't course-correct while a tool loop
  is running — their next message is processed AFTER the loop returns.
  picoclaw's pkg/agent/steering.go and nanobot's _inject_pending path
  both let the user push a follow-up into a queue that the loop drains
  between iterations and folds into the next LLM round-trip as a
  system note. This unit ports that mechanism.

  Storage: append-only JSONL files at
    $PASCLAW_HOME/workspace/steering/<key>.jsonl
  one line per pending message: {"at":<unix>,"text":"..."}

  Key choice: callers pass the SessionKey on TToolLoopConfig.SteeringKey.
  Cmd.Agent uses Session.Meta.Id (always present since PR #117);
  channels can pass their own stable per-conversation key (Telegram
  chat id, Slack channel, etc.) when they wire concurrent polling
  (currently CLI-only — see README for the per-channel follow-up).

  Concurrency model: pushes are atomic per-line POSIX appends (a
  PIPE_BUF-sized write to an O_APPEND fd is atomic). Drains rename
  the queue file to <key>.jsonl.draining, then read and delete — so
  a concurrent push during drain lands in a freshly-created
  <key>.jsonl that the NEXT drain picks up. No message lost, no
  message returned twice.

  Cap: caller decides via MaxPerTurn (RunToolLoop passes a small
  fixed cap so a runaway pusher can't grow Hist unbounded). Drained
  messages beyond the cap are logged + dropped — picoclaw's
  MaxInjections behaves the same.
*)
unit PasClaw.Agent.Steering;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TSteeringMessage = record
    PostedAt: Int64;     { unix seconds, UTC }
    Text:     string;
  end;
  TSteeringMessageArray = array of TSteeringMessage;

{ Push a steering message to the queue keyed by SessionKey. Returns
  True on success, False when the key is unsafe (rejected for the
  same reasons PasClaw.Session.Store.IsSafeSessionId rejects: path
  traversal, NULs, leading dot, length cap) or write fails. }
function PushSteering(const SessionKey, Text: string): Boolean;

{ Drain up to MaxMessages from the queue (rest are LOST — caller
  picked the cap). Empty array when no messages or unsafe key.
  Atomic across concurrent drains via rename. }
function DrainSteering(const SessionKey: string; MaxMessages: Integer): TSteeringMessageArray;

{ Erase the queue entirely. Called by /reset, /new, session delete. }
procedure ClearSteering(const SessionKey: string);

{ Inspect without consuming — list / show / debug. }
function PendingSteeringCount(const SessionKey: string): Integer;

{ Absolute path of the on-disk queue file (or '' for an unsafe key).
  Exposed so the CLI `pasclaw steer` can print where the message
  landed and so cmd/session show can include it. }
function SteeringPath(const SessionKey: string): string;

implementation

uses
  Classes, DateUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Session.Store,
  PasClaw.JSON,
  PasClaw.Logger;

function SteeringDir: string;
begin
  Result := JoinPath(GetHome, 'workspace/steering');
end;

function SteeringPath(const SessionKey: string): string;
begin
  if not IsSafeSessionId(SessionKey) then Exit('');
  Result := JoinPath(SteeringDir, SessionKey + '.jsonl');
end;

procedure EnsureSteeringDir;
begin
  if not DirectoryExists(SteeringDir) then
    ForceDirectories(SteeringDir);
end;

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

function EncodeLine(PostedAt: Int64; const Text: string): string;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutInt('at',   PostedAt);
    Obj.PutStr('text', Text);
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function DecodeLine(const Line: string; out Msg: TSteeringMessage): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  if Trim(Line) = '' then Exit;
  Obj := TJsonObject.Parse(Line);
  if Obj = nil then Exit;
  try
    Msg.PostedAt := Obj.GetInt('at',   0);
    Msg.Text     := Obj.GetStr('text', '');
  finally
    Obj.Free;
  end;
  Result := Msg.Text <> '';
end;

function PushSteering(const SessionKey, Text: string): Boolean;
var
  Path: string;
  Stream: TFileStream;
  Line: UTF8String;
  TrimmedText: string;
begin
  Result := False;
  TrimmedText := Trim(Text);
  if TrimmedText = '' then Exit;
  Path := SteeringPath(SessionKey);
  if Path = '' then Exit;
  EnsureSteeringDir;
  if FileExists(Path) then
    Stream := TFileStream.Create(Path, fmOpenWrite or fmShareDenyNone)
  else
    Stream := TFileStream.Create(Path, fmCreate);
  try
    Stream.Seek(0, soEnd);
    Line := UTF8String(EncodeLine(NowUnix, TrimmedText) + #10);
    Stream.WriteBuffer(Pointer(Line)^, Length(Line));
    Result := True;
  finally
    Stream.Free;
  end;
end;

function DrainSteering(const SessionKey: string; MaxMessages: Integer): TSteeringMessageArray;
var
  Path, DrainPath: string;
  S: TStringList;
  i, Kept: Integer;
  Msg: TSteeringMessage;
begin
  SetLength(Result, 0);
  Path := SteeringPath(SessionKey);
  if (Path = '') or (not FileExists(Path)) then Exit;
  DrainPath := Path + '.draining';
  { Rename first so a concurrent push lands in a fresh file. Any
    push between the rename and the read is preserved; any push
    after the rename targets a new <key>.jsonl which the NEXT
    drain handles. }
  if FileExists(DrainPath) then SysUtils.DeleteFile(DrainPath);
  if not RenameFile(Path, DrainPath) then Exit;
  S := TStringList.Create;
  try
    try
      S.LoadFromFile(DrainPath);
    except
      on E: Exception do
      begin
        LogWarn('steering: drain read failed (%s); discarding queue', [E.Message]);
        SysUtils.DeleteFile(DrainPath);
        Exit;
      end;
    end;
    Kept := 0;
    for i := 0 to S.Count - 1 do
    begin
      if Kept >= MaxMessages then
      begin
        LogWarn('steering[%s]: %d pending exceeded cap of %d — dropping rest',
                [SessionKey, S.Count - Kept, MaxMessages]);
        Break;
      end;
      if DecodeLine(S[i], Msg) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Msg;
        Inc(Kept);
      end;
    end;
  finally
    S.Free;
    SysUtils.DeleteFile(DrainPath);
  end;
end;

procedure ClearSteering(const SessionKey: string);
var
  Path: string;
begin
  Path := SteeringPath(SessionKey);
  if (Path = '') or (not FileExists(Path)) then Exit;
  SysUtils.DeleteFile(Path);
end;

function PendingSteeringCount(const SessionKey: string): Integer;
var
  Path: string;
  S: TStringList;
begin
  Result := 0;
  Path := SteeringPath(SessionKey);
  if (Path = '') or (not FileExists(Path)) then Exit;
  S := TStringList.Create;
  try
    try
      S.LoadFromFile(Path);
    except
      Exit;
    end;
    Result := S.Count;
  finally
    S.Free;
  end;
end;

end.
