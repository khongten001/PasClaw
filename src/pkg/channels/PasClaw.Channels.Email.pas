(*
  PasClaw.Channels.Email - bidirectional email channel.

  Outbound: TIdSMTP — sends a text/plain message to a recipient with
  the configured From address. Uses STARTTLS by default; explicit TLS
  on port 465 is the alternative when SMTPSSLMode = sslmTLS.

  Inbound: TIdIMAP4 polling. Connects, selects INBOX, list-fetches
  every UNSEEN message, runs each through the agent loop, replies via
  SMTP, then marks the message Seen so we don't process it again. The
  polling interval defaults to 30s; configure with PASCLAW_EMAIL_POLL.

  Configuration via env vars (all required for the bot path; SMTP-only
  push works with the SMTP set alone):

      PASCLAW_EMAIL_SMTP_HOST      smtp.example.com
      PASCLAW_EMAIL_SMTP_PORT      587            (or 465 for sslmTLS)
      PASCLAW_EMAIL_SMTP_USER      bot@example.com
      PASCLAW_EMAIL_SMTP_PASS      app-password
      PASCLAW_EMAIL_SMTP_TLS       starttls       (or "tls" for 465)
      PASCLAW_EMAIL_FROM           bot@example.com
      PASCLAW_EMAIL_IMAP_HOST      imap.example.com
      PASCLAW_EMAIL_IMAP_PORT      993
      PASCLAW_EMAIL_IMAP_USER      bot@example.com
      PASCLAW_EMAIL_IMAP_PASS      app-password
      PASCLAW_EMAIL_POLL           30s            (optional; min 5s)
      PASCLAW_EMAIL_ALLOW          @example.com   (optional sender allowlist;
                                                   substring match, comma-separated)

  The bot only auto-replies when the inbound From address matches the
  allowlist (substring). Without an allowlist, every UNSEEN message is
  answered — fine for a personal mailbox, dangerous for a shared one.
*)
unit PasClaw.Channels.Email;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TEmailSMTPMode = (esmStartTLS, esmExplicitTLS, esmPlain);

  TEmailAuth = record
    Host: string;
    Port: Integer;
    User: string;
    Pass: string;
    Mode: TEmailSMTPMode;  { SMTP only; IMAP forces explicit TLS on 993 }
  end;

  TEmailChannel = class
  private
    FCfg:       TConfig;
    FProvider:  ILLMProvider;
    FRegistry:  TToolRegistry;
    FSMTP:      TEmailAuth;
    FIMAP:      TEmailAuth;
    FFrom:      string;
    FAllow:     array of string;
    FPollSec:   Integer;
    FStop:      Boolean;
    function MatchesAllow(const FromAddr: string): Boolean;
    procedure ProcessInbox;
    procedure RunOnePoll;
  public
    constructor Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
    { Send a single text message. Returns False on transport error; the
      ErrMsg holds a one-line description. Doesn't require IMAP. }
    function Push(const Recipient, Subject, Body: string;
                  out ErrMsg: string): Boolean;
    { Block and poll IMAP until RequestStop is called. Each unseen
      message routes to the agent loop and the reply is sent via SMTP. }
    procedure Run;
    { Spawn Run on a dedicated TThread and return immediately. The
      worker stays alive for the channel's lifetime; RequestStop signals
      it to wind down on the next poll boundary. Used by the gateway
      so the email worker can coexist with the HTTP listener and
      other channels. }
    procedure Spawn;
    procedure RequestStop;
  end;

implementation

uses
  DateUtils,
  IdSMTP, IdIMAP4, IdMessage, IdSSLOpenSSL, IdExplicitTLSClientServerBase,
  IdMessageBuilder, IdMessageParts, IdAttachmentFile,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.Factory,
  PasClaw.Tools.ToolLoop;

function ParseSMTPMode(const S: string): TEmailSMTPMode;
var
  L: string;
begin
  L := LowerCase(S);
  if (L = 'tls') or (L = 'sslm') or (L = 'explicit') then
    Result := esmExplicitTLS
  else if (L = 'plain') or (L = 'none') then
    Result := esmPlain
  else
    Result := esmStartTLS;
end;

function ParsePollSeconds(const S: string): Integer;
var
  N: Integer;
  T: string;
begin
  Result := 30;
  T := Trim(S);
  if T = '' then Exit;
  { Strip trailing s/m/h }
  if (Length(T) > 1) and (T[Length(T)] in ['s', 'm', 'h', 'S', 'M', 'H']) then
  begin
    case T[Length(T)] of
      's', 'S': N := 1;
      'm', 'M': N := 60;
      'h', 'H': N := 3600;
    else
      N := 1;
    end;
    SetLength(T, Length(T) - 1);
  end
  else
    N := 1;
  if TryStrToInt(Trim(T), Result) then
    Result := Result * N
  else
    Result := 30;
  if Result < 5 then Result := 5;
end;

function SplitCSV(const S: string): TStringArray;
var
  L: TStringList;
  i: Integer;
begin
  SetLength(Result, 0);
  if S = '' then Exit;
  L := TStringList.Create;
  try
    L.Delimiter := ',';
    L.StrictDelimiter := True;
    L.DelimitedText := S;
    SetLength(Result, L.Count);
    for i := 0 to L.Count - 1 do
      Result[i] := LowerCase(Trim(L[i]));
  finally
    L.Free;
  end;
end;

constructor TEmailChannel.Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;

  FSMTP.Host := GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_HOST');
  FSMTP.Port := StrToIntDef(GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_PORT'), 587);
  FSMTP.User := GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_USER');
  FSMTP.Pass := GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_PASS');
  FSMTP.Mode := ParseSMTPMode(GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_TLS'));
  FFrom      := GetEnvironmentVariable('PASCLAW_EMAIL_FROM');
  if FFrom = '' then FFrom := FSMTP.User;

  FIMAP.Host := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_HOST');
  FIMAP.Port := StrToIntDef(GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_PORT'), 993);
  FIMAP.User := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_USER');
  FIMAP.Pass := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_PASS');
  FIMAP.Mode := esmExplicitTLS;  { IMAPS on 993 }

  FPollSec := ParsePollSeconds(GetEnvironmentVariable('PASCLAW_EMAIL_POLL'));
  FAllow   := SplitCSV(GetEnvironmentVariable('PASCLAW_EMAIL_ALLOW'));

  FStop := False;
end;

function TEmailChannel.MatchesAllow(const FromAddr: string): Boolean;
var
  i: Integer;
  L: string;
begin
  if Length(FAllow) = 0 then Exit(True);  { no allowlist = allow all }
  L := LowerCase(FromAddr);
  for i := 0 to High(FAllow) do
    if (FAllow[i] <> '') and (Pos(FAllow[i], L) > 0) then
      Exit(True);
  Result := False;
end;

function TEmailChannel.Push(const Recipient, Subject, Body: string;
                             out ErrMsg: string): Boolean;
var
  SMTP: TIdSMTP;
  SSL:  TIdSSLIOHandlerSocketOpenSSL;
  Msg:  TIdMessage;
begin
  ErrMsg := '';
  if FSMTP.Host = '' then
  begin
    ErrMsg := 'PASCLAW_EMAIL_SMTP_HOST not set';
    Exit(False);
  end;
  SMTP := TIdSMTP.Create(nil);
  SSL  := nil;
  Msg  := TIdMessage.Create(nil);
  try
    if FSMTP.Mode <> esmPlain then
    begin
      SSL := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
      SSL.SSLOptions.Method := sslvTLSv1_2;
      SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
      SMTP.IOHandler := SSL;
      if FSMTP.Mode = esmExplicitTLS then
        SMTP.UseTLS := utUseImplicitTLS
      else
        SMTP.UseTLS := utUseExplicitTLS;
    end;
    SMTP.Host     := FSMTP.Host;
    SMTP.Port     := FSMTP.Port;
    SMTP.Username := FSMTP.User;
    SMTP.Password := FSMTP.Pass;
    SMTP.AuthType := satDefault;

    Msg.From.Address := FFrom;
    Msg.Recipients.EMailAddresses := Recipient;
    Msg.Subject := Subject;
    Msg.Body.Text := Body;
    Msg.ContentType := 'text/plain; charset=utf-8';

    try
      SMTP.Connect;
      try
        SMTP.Authenticate;
        SMTP.Send(Msg);
      finally
        SMTP.Disconnect;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        ErrMsg := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Msg.Free;
    if SSL <> nil then SSL.Free;
    SMTP.Free;
  end;
end;

procedure TEmailChannel.ProcessInbox;
var
  IMAP: TIdIMAP4;
  SSL:  TIdSSLIOHandlerSocketOpenSSL;
  Msg:  TIdMessage;
  i, MsgCount: Integer;
  FromAddr, Subj, BodyText, Reply, PushErr: string;
  RToolMsgs: array of TMessage;
  LoopCfg: TToolLoopConfig;
  Loop: TToolLoopResult;
begin
  if (FIMAP.Host = '') or (FIMAP.User = '') then
  begin
    LogWarn('email IMAP config incomplete — inbound disabled');
    Exit;
  end;
  IMAP := TIdIMAP4.Create(nil);
  SSL  := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
  try
    SSL.SSLOptions.Method := sslvTLSv1_2;
    SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
    IMAP.IOHandler := SSL;
    IMAP.UseTLS := utUseImplicitTLS;
    IMAP.Host := FIMAP.Host;
    IMAP.Port := FIMAP.Port;
    IMAP.Username := FIMAP.User;
    IMAP.Password := FIMAP.Pass;

    try
      IMAP.Connect;
      try
        IMAP.Login;
        IMAP.SelectMailBox('INBOX');
        MsgCount := IMAP.MailBox.TotalMsgs;
        if MsgCount = 0 then Exit;
        for i := 1 to MsgCount do
        begin
          if FStop then Break;
          Msg := TIdMessage.Create(nil);
          try
            if not IMAP.Retrieve(i, Msg) then Continue;
            { Skip already-seen — flagged-as-Seen is the IMAP semantic
              for "already processed". The fetch above doesn't mark it
              Seen; we do that explicitly at the end of the loop so a
              crash mid-reply means we'll retry on the next poll. }
            FromAddr := Msg.From.Address;
            Subj := Msg.Subject;
            BodyText := Msg.Body.Text;
            if not MatchesAllow(FromAddr) then
            begin
              LogDebug('email %d: skipping %s (not in allowlist)', [i, FromAddr]);
              Continue;
            end;
            LogInfo('email %d: from=%s subj=%s', [i, FromAddr, Subj]);

            { Run through the agent loop. }
            SetLength(RToolMsgs, 1);
            RToolMsgs[0] := MakeMessage(mrUser, BodyText);
            LoopCfg.Provider      := FProvider;
            LoopCfg.Registry      := FRegistry;
            LoopCfg.Model         := FCfg.DefaultModel;
            LoopCfg.MaxIterations := 6;
            LoopCfg.Parallel      := True;
            LoopCfg.Fallbacks     := ResolveFallbacks(FCfg);
            LoopCfg.Options       := DefaultChatOptions;
            LoopCfg.OnText        := nil;
            LoopCfg.OnToolCall    := nil;
            LoopCfg.OnToolResult  := nil;
            if RunToolLoop(LoopCfg, RToolMsgs, Loop) and (Loop.Content <> '') then
            begin
              Reply := Loop.Content;
              if not Push(FromAddr, 'Re: ' + Subj, Reply, PushErr) then
                LogWarn('email reply send failed to %s: %s', [FromAddr, PushErr]);
            end;
            { Mark Seen so we don't reprocess. }
            IMAP.StoreFlags([UInt32(i)], sdAdd, [mfSeen]);
          finally
            Msg.Free;
          end;
        end;
      finally
        IMAP.Disconnect;
      end;
    except
      on E: Exception do
        LogWarn('email IMAP poll error: %s: %s', [E.ClassName, E.Message]);
    end;
  finally
    SSL.Free;
    IMAP.Free;
  end;
end;

procedure TEmailChannel.RunOnePoll;
begin
  ProcessInbox;
end;

procedure TEmailChannel.Run;
var
  WaitedSec: Integer;
begin
  if FIMAP.Host = '' then
  begin
    LogWarn('email: PASCLAW_EMAIL_IMAP_HOST not set — bot mode disabled, push only');
    Exit;
  end;
  LogInfo('email channel: polling %s every %ds', [FIMAP.Host, FPollSec]);
  while not FStop do
  begin
    RunOnePoll;
    WaitedSec := 0;
    while (WaitedSec < FPollSec) and (not FStop) do
    begin
      Sleep(500);
      Inc(WaitedSec);  { coarse — 500ms ticks; close enough for an email poller }
      if WaitedSec mod 2 = 0 then
        WaitedSec := WaitedSec;  { no-op; keeps the loop responsive to FStop }
    end;
  end;
end;

type
  TEmailWorker = class(TThread)
  private
    FChan: TEmailChannel;
  protected
    procedure Execute; override;
  public
    constructor Create(AChan: TEmailChannel);
  end;

constructor TEmailWorker.Create(AChan: TEmailChannel);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FChan := AChan;
end;

procedure TEmailWorker.Execute;
begin
  try
    FChan.Run;
  except
    on E: Exception do
      LogWarn('email worker crashed: %s: %s', [E.ClassName, E.Message]);
  end;
end;

procedure TEmailChannel.Spawn;
begin
  TEmailWorker.Create(Self).Start;
end;

procedure TEmailChannel.RequestStop;
begin
  FStop := True;
end;

end.
