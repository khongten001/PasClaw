(*
  PasClaw.Tools.Shell - shell_exec tool. Runs a command via /bin/sh -c
  (or cmd.exe on Windows) and captures stdout+stderr.

  Safety: PasClaw.Tools.Sandbox.ShellAllowed enforces a token + substring
  denylist (sudo, rm, chmod, chown, kill family, mkfs, dd if=,
  command substitution, package installs, device writes, etc.) and,
  when sandbox.restrict_to_workspace is set, refuses commands that
  reference absolute paths outside the workspace. Both checks are
  configured from TConfig.Sandbox at command startup. This is the
  Phase-4-promised "workspace-restricted variant" the original
  comment kept pointing at.
*)
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
  PasClaw.Platform,
  PasClaw.Tools.Sandbox;

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

function RunShell(const Cmd: string; out ExitCode: Integer): string;
begin
  ExitCode := RunOneShot(Cmd, Result);
end;

function Tool_Shell(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cmd, Reason: string;
  ExitCode: Integer;
  Out_: string;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'command', Cmd) then
  begin
    ErrMsg := 'missing required argument: command';
    Exit('');
  end;
  if not ShellAllowed(Cmd, Reason) then
  begin
    ErrMsg := Reason;
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
