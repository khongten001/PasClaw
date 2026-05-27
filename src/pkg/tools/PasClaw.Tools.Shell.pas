{
  PasClaw.Tools.Shell - shell_exec tool. Runs a command via /bin/sh -c (or
  cmd.exe on Windows) and captures stdout+stderr.

  Safety: a small denylist guards against the most catastrophic operations
  (rm -rf, mkfs, dd if=, format). It is NOT a sandbox; users should still
  audit prompts. The gateway in Phase 4 will install a workspace-restricted
  variant for use in untrusted channels.
}
unit PasClaw.Tools.Shell;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterShellTool(R: TToolRegistry);

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Platform;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if not Obj.Has(Field) then Exit;
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function IsDangerous(const Cmd: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Cmd);
  Result :=
    (Pos('rm -rf /',  L) > 0) or
    (Pos('rm -fr /',  L) > 0) or
    (Pos('mkfs',      L) > 0) or
    (Pos('dd if=',    L) > 0) or
    (Pos(':(){:|',    L) > 0) or  { fork bomb }
    (Pos('shutdown -h', L) > 0);
end;

function RunShell(const Cmd: string; out ExitCode: Integer): string;
begin
  ExitCode := RunOneShot(Cmd, Result);
end;

function Tool_Shell(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cmd: string;
  ExitCode: Integer;
  Out_: string;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'command', Cmd) then
  begin
    ErrMsg := 'missing required argument: command';
    Exit('');
  end;
  if IsDangerous(Cmd) then
  begin
    ErrMsg := 'refused: command matches built-in denylist (rm -rf /, mkfs, dd if=, fork bomb, shutdown)';
    Exit('');
  end;
  LogDebug('shell exec: %s', [Cmd]);
  Out_ := RunShell(Cmd, ExitCode);
  Result := Format('exit=%d'#10'%s', [ExitCode, Out_]);
end;

procedure RegisterShellTool(R: TToolRegistry);
var
  T: TTool;
begin
  T.Name        := 'shell_exec';
  T.Description := 'Run a shell command via /bin/sh -c (or cmd.exe on Windows). Captures stdout+stderr, caps output at 1 MiB.';
  T.Schema      := '{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute."}},"required":["command"]}';
  T.Handler     := Tool_Shell;
  T.IsCore      := True;
  R.Register(T);
end;

end.
