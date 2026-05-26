{
  Agent — chat with the assistant. Two modes:
    pasclaw agent -m "single query"   -> one-shot
    pasclaw agent                     -> interactive
  Provider wiring lands in Phase 3; for now we accept input and echo back
  with the configured model so the CLI shape works end-to-end.
}
unit PasClaw.Cmd.Agent;
{$MODE DELPHI}
{$H+}

interface

function Cmd_Agent_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI, PasClaw.Logger;

function ParseMessage(const Argv: array of string; out Msg: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-m') or (Argv[i] = '--message') then
    begin
      if i = High(Argv) then Exit(False);
      Msg := Argv[i + 1];
      Exit(True);
    end;
    Inc(i);
  end;
end;

procedure RespondTo(const Cfg: TConfig; const Prompt: string);
begin
  { Phase 1 placeholder; Phase 3 replaces this with a real provider call. }
  WriteLn(Ansi.Cyan, 'assistant', Ansi.Reset, ' (', Cfg.DefaultProvider, '/', Cfg.DefaultModel, '): ');
  WriteLn('  (offline preview) You said: ', Prompt);
  WriteLn('  -> wire an API key with `pasclaw onboard` to enable live responses.');
end;

function Cmd_Agent_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Msg, Line: string;
begin
  Cfg := LoadConfig;
  try
    if ParseMessage(Argv, Msg) then
    begin
      RespondTo(Cfg, Msg);
      Exit(0);
    end;

    WriteLn(Ansi.Dim, 'PasClaw interactive chat. Type /quit to exit.', Ansi.Reset);
    while True do
    begin
      Write(Ansi.Bold, '> ', Ansi.Reset);
      if EOF then Break;
      ReadLn(Line);
      Line := Trim(Line);
      if (Line = '/quit') or (Line = '/exit') then Break;
      if Line = '' then Continue;
      RespondTo(Cfg, Line);
    end;
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
