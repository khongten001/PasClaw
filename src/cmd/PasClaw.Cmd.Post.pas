(*
  Post - send a message to a configured channel from the command line.
  Useful for cron jobs and skills.

    pasclaw post discord <webhook-url-or-name> "<content>"
    pasclaw post slack   <webhook-url-or-name> "<content>"
    pasclaw post teams   <webhook-url>         "<content>"
    pasclaw post webhook <url>                 "<content>"
    pasclaw post line    <userId|groupId>      "<content>"

  Webhook URLs may be passed directly or referenced by a name stored in
  ~/.pasclaw/config.json under `channels: [{ name, kind, url, ... }]`.

  `line` reads the channel access token from $PASCLAW_LINE_TOKEN.
  `webhook` optionally reads an Authorization header value from
  $PASCLAW_WEBHOOK_AUTH (e.g. "Bearer xyz") so cron jobs don't have to
  put tokens on the command line.
*)
unit PasClaw.Cmd.Post;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Post_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Channels.Discord,
  PasClaw.Channels.Slack,
  PasClaw.Channels.Teams,
  PasClaw.Channels.Webhook,
  PasClaw.Channels.LINE;

procedure Help;
begin
  WriteLn('Usage: pasclaw post <discord|slack|teams|webhook|line> <target> "<content>"');
  WriteLn('  discord  <webhook-url> "<text>"');
  WriteLn('  slack    <webhook-url> "<text>"');
  WriteLn('  teams    <webhook-url> "<text>"');
  WriteLn('  webhook  <url> "<text>"           (auth via $PASCLAW_WEBHOOK_AUTH)');
  WriteLn('  line     <userId|groupId|roomId> "<text>"');
  WriteLn('                                    (token via $PASCLAW_LINE_TOKEN)');
end;

function ReportResult(Success: Boolean; const ChannelName: string): Integer;
begin
  if Success then
  begin
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'posted to ', ChannelName);
    Result := 0;
  end
  else
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, ChannelName, ' post failed');
    Result := 1;
  end;
end;

function DoDiscord(const URL, Content: string): Integer;
var
  W: TDiscordWebhook;
begin
  W := TDiscordWebhook.Create(URL);
  try Result := ReportResult(W.Post(Content), 'discord');
  finally W.Free; end;
end;

function DoSlack(const URL, Content: string): Integer;
var
  W: TSlackWebhook;
begin
  W := TSlackWebhook.Create(URL);
  try Result := ReportResult(W.Post(Content), 'slack');
  finally W.Free; end;
end;

function DoTeams(const URL, Content: string): Integer;
var
  W: TTeamsWebhook;
begin
  W := TTeamsWebhook.Create(URL);
  try Result := ReportResult(W.Post(Content), 'teams');
  finally W.Free; end;
end;

function DoWebhook(const URL, Content: string): Integer;
var
  W: TGenericWebhook;
  Auth: string;
begin
  Auth := GetEnvironmentVariable('PASCLAW_WEBHOOK_AUTH');
  W := TGenericWebhook.Create(URL, Auth);
  try Result := ReportResult(W.Post(Content), 'webhook');
  finally W.Free; end;
end;

function DoLine(const ToId, Content: string): Integer;
var
  L: TLinePush;
  Token: string;
begin
  Token := GetEnvironmentVariable('PASCLAW_LINE_TOKEN');
  if Token = '' then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'line: set PASCLAW_LINE_TOKEN to a channel access token');
    Exit(1);
  end;
  L := TLinePush.Create(Token);
  try Result := ReportResult(L.Push(ToId, Content), 'line');
  finally L.Free; end;
end;

function Cmd_Post_Run(const Argv: array of string): Integer;
begin
  if Length(Argv) < 3 then begin Help; Exit(1); end;
  if      Argv[0] = 'discord' then Result := DoDiscord(Argv[1], Argv[2])
  else if Argv[0] = 'slack'   then Result := DoSlack  (Argv[1], Argv[2])
  else if Argv[0] = 'teams'   then Result := DoTeams  (Argv[1], Argv[2])
  else if Argv[0] = 'webhook' then Result := DoWebhook(Argv[1], Argv[2])
  else if Argv[0] = 'line'    then Result := DoLine   (Argv[1], Argv[2])
  else begin Help; Result := 1; end;
end;

end.
