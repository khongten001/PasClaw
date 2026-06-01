(*
  PasClaw.Cmd.Session — list / show / delete / export persistent
  conversation sessions stored under
  $PASCLAW_HOME/workspace/sessions/.

  See PasClaw.Session.Store for the on-disk format. The top-level
  `pasclaw resume <id>` shortcut is wired in Cmd.Root and rewrites
  Argv to `agent --session <id>` so the resume path goes through
  the same RunInteractive loop as a fresh chat.
*)
unit PasClaw.Cmd.Session;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Session_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Providers.Types,   { TMsgRole = (mrSystem, mrUser, mrAssistant, mrTool) }
  PasClaw.Session.Store,
  PasClaw.Agent.Steering;

procedure PrintHelp;
begin
  WriteLn('Usage: pasclaw session <list|show|delete|export> [args]');
  WriteLn('  list                list every saved session (id, title, msgs, last used)');
  WriteLn('  show <id>           show one session: metadata + last N messages');
  WriteLn('  delete <id>         remove the session file from disk');
  WriteLn('  export <id>         print the raw session JSON to stdout');
end;

function FormatAge(Now_, Then_: Int64): string;
var
  Delta: Int64;
begin
  Delta := Now_ - Then_;
  if Delta < 60 then Result := IntToStr(Delta) + 's ago'
  else if Delta < 3600 then Result := IntToStr(Delta div 60) + 'm ago'
  else if Delta < 86400 then Result := IntToStr(Delta div 3600) + 'h ago'
  else Result := IntToStr(Delta div 86400) + 'd ago';
end;

function DoList: Integer;
var
  Sessions: TSessionMetaArray;
  i: Integer;
  Now_: Int64;
  Title: string;
begin
  Sessions := ListSessions;
  if Length(Sessions) = 0 then
  begin
    WriteLn(Ansi.Dim, '(no saved sessions)', Ansi.Reset);
    Exit(0);
  end;
  Now_ := DateTimeToUnix(Now, False);
  WriteLn(Ansi.Bold, 'session id':28, '  ':2, 'updated':12, '  ':2, 'msgs':5, '  title', Ansi.Reset);
  for i := 0 to High(Sessions) do
  begin
    Title := Sessions[i].Title;
    if Title = '' then Title := Ansi.Dim + '(untitled)' + Ansi.Reset;
    WriteLn(Sessions[i].Id:28, '  ',
            FormatAge(Now_, Sessions[i].UpdatedAt):12, '  ',
            '':5,
            '  ', Title);
  end;
  Result := 0;
end;

function DoShow(const Id: string): Integer;
const
  TailCount = 8;   { last N messages, head trimmed for brevity }
var
  Sess: TSession;
  i, Start: Integer;
  Role, Preview: string;
begin
  Sess := TSession.Create(Id);
  try
    if not Sess.MetaExists then
    begin
      WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'no session named ', Id);
      Exit(1);
    end;
    WriteLn(Ansi.Bold, 'id:        ', Ansi.Reset, Sess.Meta.Id);
    WriteLn(Ansi.Bold, 'title:     ', Ansi.Reset, Sess.Meta.Title);
    WriteLn(Ansi.Bold, 'model:     ', Ansi.Reset, Sess.Meta.Model);
    WriteLn(Ansi.Bold, 'provider:  ', Ansi.Reset, Sess.Meta.Provider);
    WriteLn(Ansi.Bold, 'messages:  ', Ansi.Reset, Length(Sess.Messages));
    if Sess.Meta.SystemPromptOverride <> '' then
      WriteLn(Ansi.Bold, 'compacted: ', Ansi.Reset, Ansi.Dim, 'yes', Ansi.Reset);
    WriteLn;
    Start := Length(Sess.Messages) - TailCount;
    if Start < 0 then Start := 0
    else if Start > 0 then
      WriteLn(Ansi.Dim, '... (', Start, ' earlier messages elided; use `export` for full JSON)', Ansi.Reset);
    for i := Start to High(Sess.Messages) do
    begin
      case Sess.Messages[i].Role of
        mrSystem:    Role := Ansi.Yellow  + 'system'    + Ansi.Reset;
        mrUser:      Role := Ansi.Bold    + 'user'      + Ansi.Reset;
        mrAssistant: Role := Ansi.Cyan    + 'assistant' + Ansi.Reset;
        mrTool:      Role := Ansi.Magenta + 'tool'      + Ansi.Reset;
      else
        Role := '?';
      end;
      Preview := Sess.Messages[i].Content;
      if Length(Preview) > 200 then Preview := Copy(Preview, 1, 200) + '…';
      WriteLn(Role, ': ', Preview);
    end;
    Result := 0;
  finally
    Sess.Free;
  end;
end;

function DoDelete(const Id: string): Integer;
begin
  if DeleteSession(Id) then
  begin
    { Stray steering messages for the just-deleted session would
      otherwise sit on disk forever — clear them too. }
    ClearSteering(Id);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'deleted session ', Id);
    Result := 0;
  end
  else
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'no session named ', Id);
    Result := 1;
  end;
end;

function DoExport(const Id: string): Integer;
var
  Path: string;
  S: TStringList;
begin
  Path := SessionPath(Id);
  if (Path = '') or (not FileExists(Path)) then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'no session named ', Id);
    Exit(1);
  end;
  S := TStringList.Create;
  try
    S.LoadFromFile(Path);
    Write(S.Text);   { raw JSON to stdout; pipe through jq for pretty-print }
    Result := 0;
  finally
    S.Free;
  end;
end;

function Cmd_Session_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin PrintHelp; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'   then Result := DoList
  else if Sub = 'show'   then begin if Length(Argv) < 2 then begin PrintHelp; Exit(1); end; Result := DoShow  (Argv[1]); end
  else if Sub = 'delete' then begin if Length(Argv) < 2 then begin PrintHelp; Exit(1); end; Result := DoDelete(Argv[1]); end
  else if Sub = 'export' then begin if Length(Argv) < 2 then begin PrintHelp; Exit(1); end; Result := DoExport(Argv[1]); end
  else                        begin PrintHelp; Result := 1; end;
end;

end.
