(*
  PasClaw.Providers.Stream - Server-Sent Events parser shared by both
  OpenAI's and Anthropic's streaming endpoints.

  SSE framing:
    data: <chunk>\n
    data: <chunk>\n
    \n               <- blank line ends an event
    event: <name>\n  <- optional, present in Anthropic stream
    ...

  We don't use TIdEventStream because we need fine-grained per-chunk callbacks
  and the Indy version of EventStream is not present in older Indy builds.
  Instead we POST with stream=true and read the response off TIdHTTP.IOHandler
  line by line.
*)
unit PasClaw.Providers.Stream;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  IdHTTP, IdSSLOpenSSL, IdGlobal, IdExceptionCore,
  PasClaw.Providers.Types,
  PasClaw.Providers.HTTP;

type
  TSSECallback = procedure(const Event, Data: string) of object;
  TSSECallbackProc = procedure(const Event, Data: string);

function PostStreaming(const URL, JSON: string;
                       const Headers: array of THeaderPair;
                       TimeoutSeconds: Integer;
                       OnLine: TSSECallbackProc;
                       out StatusCode: Integer;
                       out ErrMsg: string): Boolean;

implementation

function PostStreaming(const URL, JSON: string;
                       const Headers: array of THeaderPair;
                       TimeoutSeconds: Integer;
                       OnLine: TSSECallbackProc;
                       out StatusCode: Integer;
                       out ErrMsg: string): Boolean;
var
  Http: TIdHTTP;
  SSL:  TIdSSLIOHandlerSocketOpenSSL;
  Req:  TStringStream;
  Resp: TStringStream;
  Body: TStringList;
  i: Integer;
  EventName, DataAccum, Line: string;

  procedure Flush;
  begin
    if (EventName <> '') or (DataAccum <> '') then
    begin
      if Assigned(OnLine) then OnLine(EventName, DataAccum);
      EventName := '';
      DataAccum := '';
    end;
  end;

begin
  Result := False;
  ErrMsg := '';
  StatusCode := 0;

  Http := TIdHTTP.Create(nil);
  { Explicit UTF-8 — Delphi's TStringStream defaults to ANSI which would
    mangle the SSE response body and the JSON request body. }
  Req  := TStringStream.Create(JSON, TEncoding.UTF8);
  Resp := TStringStream.Create('', TEncoding.UTF8);
  SSL  := nil;
  try
    Http.ConnectTimeout := TimeoutSeconds * 1000;
    Http.ReadTimeout    := TimeoutSeconds * 1000;
    Http.Request.UserAgent   := 'PasClaw/0.1';
    Http.Request.ContentType := 'application/json';
    Http.Request.Accept      := 'text/event-stream';
    for i := 0 to High(Headers) do
      Http.Request.CustomHeaders.AddValue(Headers[i].Name, Headers[i].Value);
    if (Length(URL) >= 8) and SameText(Copy(URL, 1, 8), 'https://') then
    begin
      SSL := TIdSSLIOHandlerSocketOpenSSL.Create(Http);
      SSL.SSLOptions.Method := sslvTLSv1_2;
      SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
      Http.IOHandler := SSL;
    end;
    try
      Http.Post(URL, Req, Resp);
      StatusCode := Http.ResponseCode;
    except
      on E: Exception do
      begin
        StatusCode := Http.ResponseCode;
        ErrMsg     := E.Message;
        { fall through and try to parse what we got }
      end;
    end;

    { Indy's TIdHTTP buffers the full response into Resp. For true real-time
      streaming the caller can switch to a custom IOHandler hook; here we
      parse the buffered body, which still drives per-event callbacks. }
    Body := TStringList.Create;
    try
      Body.Text := Resp.DataString;
      EventName := '';
      DataAccum := '';
      for i := 0 to Body.Count - 1 do
      begin
        Line := Body[i];
        if Line = '' then
        begin
          Flush;
          Continue;
        end;
        if Copy(Line, 1, 6) = 'event:' then
          EventName := Trim(Copy(Line, 7, MaxInt))
        else if Copy(Line, 1, 5) = 'data:' then
        begin
          if DataAccum <> '' then DataAccum := DataAccum + #10;
          DataAccum := DataAccum + Trim(Copy(Line, 6, MaxInt));
        end;
      end;
      Flush;
    finally
      Body.Free;
    end;

    Result := (StatusCode >= 200) and (StatusCode < 300);
  finally
    Resp.Free;
    Req.Free;
    Http.Free;
  end;
end;

end.
