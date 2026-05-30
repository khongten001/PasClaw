{
  PasClaw.Logger - levelled logging that matches pkg/logger conventions.
  Levels: debug < info < warn < error. Default = info.
}
unit PasClaw.Logger;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError, llSilent);

  (* Subscriber callback for live log streaming. Fires from inside
     Emit on whatever thread the log call ran on. Subscribers must
     NOT block — Indy listener threads or the cron scheduler thread
     own that call stack. The web UI's /v1/logs SSE handler is the
     primary consumer; it buffers locally and ships to the browser
     on its own writer thread. *)
  TLogListener = procedure(const Tag, Msg: string) of object;

procedure SetLogLevel(L: TLogLevel);
procedure SetLogLevelFromString(const S: string);
function  CurrentLogLevel: TLogLevel;

procedure LogDebug(const Msg: string); overload;
procedure LogDebug(const Fmt: string; const Args: array of const); overload;
procedure LogInfo(const Msg: string); overload;
procedure LogInfo(const Fmt: string; const Args: array of const); overload;
procedure LogWarn(const Msg: string); overload;
procedure LogWarn(const Fmt: string; const Args: array of const); overload;
procedure LogError(const Msg: string); overload;
procedure LogError(const Fmt: string; const Args: array of const); overload;

(* Ring-buffered tail of the most recent log lines. Each entry is
   "<tag>\t<message>". Caller owns the returned TStringList and
   must Free it. Buffer caps at 1000 entries; older lines fall off
   the front. *)
function LogBufferSnapshot: TStringList;

(* Subscribe / unsubscribe a live listener. SubscribeLog returns a
   token used to identify the subscription on Unsubscribe (the
   /v1/logs SSE handler keeps it across the request lifetime). *)
function SubscribeLog(Listener: TLogListener): Integer;
procedure UnsubscribeLog(Token: Integer);

implementation

uses
  SyncObjs,
  PasClaw.CliUI;

const
  BUFFER_CAP = 1000;

type
  TListenerSlot = record
    Token:    Integer;
    Listener: TLogListener;
  end;

var
  GLevel: TLogLevel = llInfo;
  GBufferLock: TCriticalSection = nil;
  GBuffer: TStringList = nil;
  GListeners: array of TListenerSlot;
  GNextToken: Integer = 1;

procedure SetLogLevel(L: TLogLevel);
begin
  GLevel := L;
end;

procedure SetLogLevelFromString(const S: string);
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if (L = 'debug') or (L = 'trace') then SetLogLevel(llDebug)
  else if L = 'info'  then SetLogLevel(llInfo)
  else if (L = 'warn') or (L = 'warning') then SetLogLevel(llWarn)
  else if (L = 'error') or (L = 'err') then SetLogLevel(llError)
  else if (L = 'silent') or (L = 'off') or (L = 'none') then SetLogLevel(llSilent);
end;

function CurrentLogLevel: TLogLevel;
begin
  Result := GLevel;
end;

procedure FanoutListeners(const Tag, Msg: string);
var
  Snapshot: array of TListenerSlot;
  i: Integer;
begin
  { Copy under the lock so the dispatch happens unlocked — a slow
    listener (HTTP-write blocking on a slow client) doesn't pin
    the buffer mutex and serialise every subsequent log call. }
  GBufferLock.Acquire;
  try
    SetLength(Snapshot, Length(GListeners));
    for i := 0 to High(GListeners) do Snapshot[i] := GListeners[i];
  finally
    GBufferLock.Release;
  end;
  for i := 0 to High(Snapshot) do
  begin
    if not Assigned(Snapshot[i].Listener) then Continue;
    try
      Snapshot[i].Listener(Tag, Msg);
    except
      { Swallow — a misbehaving listener must NOT abort the log. }
    end;
  end;
end;

procedure Emit(Lvl: TLogLevel; const Tag, Color, Msg: string);
begin
  if Lvl < GLevel then Exit;
  WriteLn(ErrOutput, Color, '[', Tag, ']', Ansi.Reset, ' ', Msg);

  { Ring buffer + listener fanout. Both gate on the same critical
    section. Tags are short (debug/info/warn/error), Msg is the
    formatted body; the tab separator matches the snapshot wire
    format. }
  if GBuffer <> nil then
  begin
    GBufferLock.Acquire;
    try
      GBuffer.Add(Tag + #9 + Msg);
      while GBuffer.Count > BUFFER_CAP do GBuffer.Delete(0);
    finally
      GBufferLock.Release;
    end;
  end;
  FanoutListeners(Tag, Msg);
end;

function LogBufferSnapshot: TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  if GBuffer = nil then Exit;
  GBufferLock.Acquire;
  try
    for i := 0 to GBuffer.Count - 1 do
      Result.Add(GBuffer[i]);
  finally
    GBufferLock.Release;
  end;
end;

function SubscribeLog(Listener: TLogListener): Integer;
begin
  Result := 0;
  if not Assigned(Listener) then Exit;
  GBufferLock.Acquire;
  try
    Result := GNextToken;
    Inc(GNextToken);
    SetLength(GListeners, Length(GListeners) + 1);
    GListeners[High(GListeners)].Token := Result;
    GListeners[High(GListeners)].Listener := Listener;
  finally
    GBufferLock.Release;
  end;
end;

procedure UnsubscribeLog(Token: Integer);
var
  i, j: Integer;
begin
  if Token <= 0 then Exit;
  GBufferLock.Acquire;
  try
    for i := 0 to High(GListeners) do
      if GListeners[i].Token = Token then
      begin
        for j := i to High(GListeners) - 1 do
          GListeners[j] := GListeners[j + 1];
        SetLength(GListeners, Length(GListeners) - 1);
        Break;
      end;
  finally
    GBufferLock.Release;
  end;
end;

procedure LogDebug(const Msg: string); begin Emit(llDebug, 'debug', Ansi.Gray,   Msg); end;
procedure LogDebug(const Fmt: string; const Args: array of const); begin LogDebug(Format(Fmt, Args)); end;
procedure LogInfo (const Msg: string); begin Emit(llInfo,  'info',  Ansi.Cyan,   Msg); end;
procedure LogInfo (const Fmt: string; const Args: array of const); begin LogInfo (Format(Fmt, Args)); end;
procedure LogWarn (const Msg: string); begin Emit(llWarn,  'warn',  Ansi.Yellow, Msg); end;
procedure LogWarn (const Fmt: string; const Args: array of const); begin LogWarn (Format(Fmt, Args)); end;
procedure LogError(const Msg: string); begin Emit(llError, 'error', Ansi.Red,    Msg); end;
procedure LogError(const Fmt: string; const Args: array of const); begin LogError(Format(Fmt, Args)); end;

initialization
  GBufferLock := TCriticalSection.Create;
  GBuffer := TStringList.Create;

finalization
  try GBuffer.Free; except end;
  try GBufferLock.Free; except end;

end.
