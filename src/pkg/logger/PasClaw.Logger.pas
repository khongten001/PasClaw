{
  PasClaw.Logger - levelled logging that matches pkg/logger conventions.
  Levels: debug < info < warn < error. Default = info.
}
unit PasClaw.Logger;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError, llSilent);

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

implementation

uses
  PasClaw.CliUI;

var
  GLevel: TLogLevel = llInfo;

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

procedure Emit(Lvl: TLogLevel; const Tag, Color, Msg: string);
begin
  if Lvl < GLevel then Exit;
  WriteLn(ErrOutput, Color, '[', Tag, ']', Ansi.Reset, ' ', Msg);
end;

procedure LogDebug(const Msg: string); begin Emit(llDebug, 'debug', Ansi.Gray,   Msg); end;
procedure LogDebug(const Fmt: string; const Args: array of const); begin LogDebug(Format(Fmt, Args)); end;
procedure LogInfo (const Msg: string); begin Emit(llInfo,  'info',  Ansi.Cyan,   Msg); end;
procedure LogInfo (const Fmt: string; const Args: array of const); begin LogInfo (Format(Fmt, Args)); end;
procedure LogWarn (const Msg: string); begin Emit(llWarn,  'warn',  Ansi.Yellow, Msg); end;
procedure LogWarn (const Fmt: string; const Args: array of const); begin LogWarn (Format(Fmt, Args)); end;
procedure LogError(const Msg: string); begin Emit(llError, 'error', Ansi.Red,    Msg); end;
procedure LogError(const Fmt: string; const Args: array of const); begin LogError(Format(Fmt, Args)); end;

end.
