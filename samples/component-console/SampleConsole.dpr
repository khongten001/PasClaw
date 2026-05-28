(*
  SampleConsole - shows how to embed PasClaw inside a standalone
  Delphi / FPC console program via TPasClawAgent.

  Build (FPC):
    cd samples/component-console
    make

  The Makefile re-uses the same UNIT_DIRS the main PasClaw binary
  needs and points at the vendored Indy in ../../vendor/Indy. The
  previous one-line `fpc -Fu../../src/cmd -Fu../../src/pkg/...`
  instruction was wrong on two counts: the literal `...` is not an
  FPC wildcard (it tried to use `...` as a directory name and
  failed), and PasClaw.Component transitively pulls in every
  subdirectory under src/pkg, so a real build needs ~25 -Fu flags
  plus Indy's three. The Makefile spells them out.

  Build (Delphi):
    drop the .dpr into a console project that mirrors PasClaw.dproj's
    DCC_UnitSearchPath. The list lives in src/pasclaw/PasClaw.dproj
    near the top of the file — copy-paste it into the sample's
    project options Search Path, swap the leading `..\` for
    `..\..\src\`, and the sample compiles. (A dedicated sample
    .dproj is on the to-do list; until then the main project file
    is the source of truth.)

  Runtime: the agent inherits config from ~/.pasclaw/config.json,
  so run `pasclaw onboard` and `pasclaw auth login <provider>` once
  first. Execute() mirrors `pasclaw version`; Chat() round-trips a
  single prompt through the configured provider and prints the
  reply.
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
