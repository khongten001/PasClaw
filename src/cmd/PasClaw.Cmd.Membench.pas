(*
  Membench - benchmark the memory log subsystem.

    pasclaw membench [--records N] [--content N] [--keep] [--out DIR]
*)
unit PasClaw.Cmd.Membench;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Membench_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Membench.Runner;

procedure Help;
begin
  PrintLn('Usage: pasclaw membench [--records N] [--content N] [--keep] [--out DIR]');
  PrintLn('  --records N    number of log entries to write (default 1000)');
  PrintLn('  --content N    payload bytes per entry (default 128)');
  PrintLn('  --keep         keep the generated NDJSON file');
  PrintLn('  --out DIR      output directory (default $TMPDIR)');
end;

function ParseArgs(const Argv: array of string; var Opts: TMembenchOpts): Boolean;
var
  i: Integer;
begin
  Result := True;
  Opts := DefaultMembenchOpts;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--records' then
      begin if i = High(Argv) then Exit(False);
            Opts.Records := StrToIntDef(Argv[i + 1], Opts.Records); Inc(i, 2); Continue; end;
    if Argv[i] = '--content' then
      begin if i = High(Argv) then Exit(False);
            Opts.ContentSize := StrToIntDef(Argv[i + 1], Opts.ContentSize); Inc(i, 2); Continue; end;
    if Argv[i] = '--keep' then
      begin Opts.KeepFile := True; Inc(i); Continue; end;
    if Argv[i] = '--out' then
      begin if i = High(Argv) then Exit(False);
            Opts.OutDir := Argv[i + 1]; Inc(i, 2); Continue; end;
    if (Argv[i] = '-h') or (Argv[i] = '--help') then
      begin Help; Exit(False); end;
    Inc(i);
  end;
end;

function Cmd_Membench_Run(const Argv: array of string): Integer;
var
  Opts: TMembenchOpts;
  Res: TMembenchResult;
  WriteRate, LoadRate, MBs: Double;
begin
  if not ParseArgs(Argv, Opts) then Exit(1);

  PrintLn(Ansi.Bold + 'PasClaw membench' + Ansi.Reset);
  PrintLn(Format('  records: %d', [Opts.Records]));
  PrintLn(Format('  content: %d bytes/record', [Opts.ContentSize]));
  PrintLn('  running...');

  Res := RunMembench(Opts);

  if Res.WriteSeconds <= 0 then WriteRate := 0
  else WriteRate := Res.RecordsWritten / Res.WriteSeconds;
  if Res.LoadSeconds <= 0 then LoadRate := 0
  else LoadRate := Res.RecordsLoaded / Res.LoadSeconds;
  if Res.WriteSeconds <= 0 then MBs := 0
  else MBs := (Res.BytesOnDisk / 1048576.0) / Res.WriteSeconds;

  PrintLn;
  PrintLn(Ansi.Bold + 'results' + Ansi.Reset);
  PrintLn(Format('  write: %d records in %.3fs  -> %.0f rec/s, %.2f MiB/s',
    [Res.RecordsWritten, Res.WriteSeconds, WriteRate, MBs]));
  PrintLn(Format('  load:  %d records in %.3fs  -> %.0f rec/s',
    [Res.RecordsLoaded, Res.LoadSeconds, LoadRate]));
  PrintLn(Format('  size:  %d bytes on disk', [Res.BytesOnDisk]));
  if Opts.KeepFile then
    PrintLn('  path:  ' + Res.Path);

  Result := 0;
end;

end.
