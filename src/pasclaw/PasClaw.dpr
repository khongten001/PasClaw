{
  PasClaw - Ultra-lightweight personal AI agent (Delphi Object Pascal port of picoclaw)
  Inspired by and based on picoclaw: https://github.com/sipeed/picoclaw
  License: MIT

  Copyright (c) 2026 PasClaw contributors

  Build with Free Pascal:
    fpc -Fusrc/pkg/... -FEbuild src/pasclaw/PasClaw.dpr
  Or use the project Makefile from the repo root:
    make
}

program PasClaw;

{$MODE DELPHI}
{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}{$IFDEF UNIX}
  cthreads,            { FPC/Linux: pull in pthreads so Indy can use TThread }
  cmem,
  {$ENDIF}{$ENDIF}
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Cmd.Root;

var
  ExitCode_: Integer;
begin
  { Detect color support before any output so the banner respects NO_COLOR. }
  CliUI_Init(EarlyColorDisabled);

  PrintBanner;
  ApplyTimezoneFromEnv;

  ExitCode_ := RunRootCommand;
  if ExitCode_ <> 0 then
    Halt(ExitCode_);
end.
