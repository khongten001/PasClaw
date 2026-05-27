(*
  Post - send a message to a configured channel from the command line.
  Useful for cron jobs and skills.

    pasclaw post discord <webhook-url-or-name> "<content>"
    pasclaw post slack   <webhook-url-or-name> "<content>"

  Webhook URLs may be passed directly or referenced by a name stored in
  ~/.pasclaw/config.json under `channels: [{ name, kind, url, ... }]`.
*)
unit PasClaw.Cmd.Post;

{$MODE DELPHI}
{$H+}

interface

function Cmd_Post_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Channels.Discord,
  PasClaw.Channels.Slack;

procedure Help;
begin
  WriteLn('Usage: pasclaw post <discord|slack> <webhook-url> "<content>"');
end;

function DoDiscord(const URL, Content: string): Integer;
var
  W: TDiscordWebhook;
begin
  W := TDiscordWebhook.Create(URL);
  try
    if W.Post(Content) then
    begin
      WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'posted to discord');
      Result := 0;
    end
    else
    begin
      WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'discord post failed');
      Result := 1;
    end;
  finally
    W.Free;
  end;
end;

function DoSlack(const URL, Content: string): Integer;
var
  W: TSlackWebhook;
begin
  W := TSlackWebhook.Create(URL);
  try
    if W.Post(Content) then
    begin
      WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'posted to slack');
      Result := 0;
    end
    else
    begin
      WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'slack post failed');
      Result := 1;
    end;
  finally
    W.Free;
  end;
end;

function Cmd_Post_Run(const Argv: array of string): Integer;
begin
  if Length(Argv) < 3 then begin Help; Exit(1); end;
  if      Argv[0] = 'discord' then Result := DoDiscord(Argv[1], Argv[2])
  else if Argv[0] = 'slack'   then Result := DoSlack(Argv[1], Argv[2])
  else begin Help; Result := 1; end;
end;

end.
