(*
  SampleConsole - shows how to embed PasClaw inside a standalone Delphi
  / FPC console program via TPasClawAgent. Build either compiler:

    Delphi:  drop the .dpr into a console project that has the PasClaw
             unit search path (..\..\src\cmd, ..\..\src\pkg\*) wired in.
    FPC:     fpc -Fu../../src/cmd -Fu../../src/pkg/... SampleConsole.dpr

  The agent inherits config from ~/.pasclaw/config.json (same as the CLI),
  so set up `pasclaw auth login` once first. The Execute() call mirrors
  `pasclaw version`; Chat() round-trips a single prompt through the
  configured provider and prints the assistant's reply.
*)
program SampleConsole;

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Component;

var
  PC:        TPasClawAgent;
  Reply, Err: string;
begin
  PC := TPasClawAgent.Create(nil);
  try
    WriteLn('--- pasclaw version ---');
    PC.Execute('version', []);

    WriteLn;
    WriteLn('--- chat ---');
    if PC.Chat('Say hi in three words.', Reply, Err) then
      WriteLn('reply: ', Reply)
    else
      WriteLn('error: ', Err);
  finally
    PC.Free;
  end;
end.
