unit PasClaw.Cmd.Version;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Version_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI;

function Cmd_Version_Run(const Argv: array of string): Integer;
begin
  PrintLn('PasClaw ' + FormatVersion);
  PrintLn(FormatBuildInfo);
  Result := 0;
end;

end.
