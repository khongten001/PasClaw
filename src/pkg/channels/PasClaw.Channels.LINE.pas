(*
  PasClaw.Channels.LINE - LINE Messaging API push sender.

  Outbound push only — sends a text message to a known LINE userId,
  groupId, or roomId via the LINE Messaging API push endpoint. The
  receive-side (webhook receiver + reply token + signature verify) is a
  Wave 2 follow-up alongside the WhatsApp Cloud receiver, since both
  need a publicly-reachable endpoint mounted on the gateway HTTP
  server.

  Auth uses a Channel Access Token (long-lived or stateless),
  configured per channel:
    - PASCLAW_LINE_TOKEN env var, or
    - the `token` field of a config.json channel entry with kind=line.

  Endpoint: POST https://api.line.me/v2/bot/message/push
  Body:    {"to": "<id>", "messages": [{"type":"text","text":"<text>"}]}
  Headers: Authorization: Bearer <token>
           Content-Type:  application/json

  The LINE push API has rate limits (Free plan: 500 messages/month);
  failures are surfaced via the boolean return and the log warning
  rather than retried — the caller decides what to do.

  Docs: https://developers.line.biz/en/reference/messaging-api/#send-push-message
*)
unit PasClaw.Channels.LINE;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TLinePush = class
  private
    FToken: string;
  public
    constructor Create(const ChannelAccessToken: string);
    function Push(const ToId, Text: string): Boolean;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

const
  LINE_PUSH_URL = 'https://api.line.me/v2/bot/message/push';

constructor TLinePush.Create(const ChannelAccessToken: string);
begin
  inherited Create;
  FToken := ChannelAccessToken;
end;

function TLinePush.Push(const ToId, Text: string): Boolean;
var
  Root, Msg: TJsonObject;
  Msgs: TJsonArray;
  Body: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  if FToken = '' then
  begin
    LogWarn('line push: no channel access token configured', []);
    Exit(False);
  end;
  if Trim(ToId) = '' then
  begin
    LogWarn('line push: empty target id', []);
    Exit(False);
  end;

  Root := TJsonObject.Create;
  try
    Root.PutStr('to', ToId);
    Msgs := TJsonArray.Create;
    Msg  := TJsonObject.Create;
    Msg.PutStr('type', 'text');
    Msg.PutStr('text', Text);
    Msgs.AddObject(Msg);
    Root.PutArray('messages', Msgs);
    Body := Root.ToJSON;
  finally
    Root.Free;
  end;

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FToken);
  Resp := PostJSON(LINE_PUSH_URL, Body, Headers, 30);

  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('line push: status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

end.
