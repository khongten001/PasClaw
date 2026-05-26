{ Update — self-update placeholder; real flow uses GitHub releases (Phase 7). }
unit PasClaw.Cmd.Update;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Update_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config;

function Cmd_Update_Run(const Argv: array of string): Integer;
begin
  WriteLn('PasClaw ', FormatVersion);
  WriteLn('(self-update over GitHub releases will land in Phase 7)');
  Result := 0;
end;

end.
