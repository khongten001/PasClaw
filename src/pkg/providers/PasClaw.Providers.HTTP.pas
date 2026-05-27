{
  PasClaw.Providers.HTTP - thin wrapper around TIdHTTP for JSON POSTs.
  Builds in both Delphi and FPC (Indy works in both). Under FPC the project
  vendors Indy via `make get-indy`; under Delphi it ships with RAD Studio.

  HTTPS support requires OpenSSL. On Linux: package "libssl-dev" / runtime
  "libssl.so.3"; on Windows: copy libeay32/ssleay32 next to the binary (Indy
  10.6+) or the modern libssl-1_1.dll pair. Indy's IdSSLOpenSSL is wired
  automatically when an "https://" URL is detected.
}
unit PasClaw.Providers.HTTP;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  IdHTTP, IdSSLOpenSSL, IdGlobal, IdExceptionCore, IdException;

type
  THTTPResult = record
    StatusCode: Integer;
    Body:       string;
    ErrorMsg:   string;
  end;

  THeaderPair = record
    Name, Value: string;
  end;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
function GetJSONURL(const URL: string;
                    const Headers: array of THeaderPair;
                    TimeoutSeconds: Integer): THTTPResult;
function MakeHeader(const Name, Value: string): THeaderPair;

implementation

function MakeHeader(const Name, Value: string): THeaderPair;
begin
  Result.Name  := Name;
  Result.Value := Value;
end;

function MakeHTTPS(URL: string): Boolean;
begin
  Result := (Length(URL) >= 8) and SameText(Copy(URL, 1, 8), 'https://');
end;

procedure ApplyHeaders(Http: TIdHTTP; const Headers: array of THeaderPair);
var
  i: Integer;
begin
  for i := 0 to High(Headers) do
    Http.Request.CustomHeaders.AddValue(Headers[i].Name, Headers[i].Value);
end;

function DoRequest(Http: TIdHTTP; const URL: string; const ReqBody: TStream;
                   IsPost: Boolean): THTTPResult;
var
  Resp: TStringStream;
begin
  Result.StatusCode := 0;
  Result.Body := '';
  Result.ErrorMsg := '';
  Resp := TStringStream.Create('');
  try
    try
      if IsPost then
        Http.Post(URL, ReqBody, Resp)
      else
        Http.Get(URL, Resp);
      Result.StatusCode := Http.ResponseCode;
      Result.Body := Resp.DataString;
    except
      on E: EIdHTTPProtocolException do
      begin
        Result.StatusCode := E.ErrorCode;
        Result.Body       := E.ErrorMessage;
        Result.ErrorMsg   := E.Message;
      end;
      on E: Exception do
      begin
        Result.StatusCode := Http.ResponseCode;
        Result.Body       := Resp.DataString;
        Result.ErrorMsg   := E.Message;
      end;
    end;
  finally
    Resp.Free;
  end;
end;

function NewClient(TimeoutSeconds: Integer; HTTPS: Boolean): TIdHTTP;
var
  SSL: TIdSSLIOHandlerSocketOpenSSL;
begin
  Result := TIdHTTP.Create(nil);
  Result.ConnectTimeout := TimeoutSeconds * 1000;
  Result.ReadTimeout    := TimeoutSeconds * 1000;
  Result.HandleRedirects := True;
  Result.Request.UserAgent := 'PasClaw/0.1 (+https://github.com/FMXExpress/PasClaw)';
  if HTTPS then
  begin
    SSL := TIdSSLIOHandlerSocketOpenSSL.Create(Result);
    SSL.SSLOptions.Method  := sslvTLSv1_2;
    SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
    Result.IOHandler := SSL;
  end;
end;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
  Req: TStringStream;
begin
  Http := NewClient(TimeoutSeconds, MakeHTTPS(URL));
  Req  := TStringStream.Create(JSON);
  try
    Http.Request.ContentType    := 'application/json';
    Http.Request.ContentEncoding := 'utf-8';
    Http.Request.Accept         := 'application/json';
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, Req, True);
  finally
    Req.Free;
    Http.Free;
  end;
end;

function GetJSONURL(const URL: string;
                    const Headers: array of THeaderPair;
                    TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
begin
  Http := NewClient(TimeoutSeconds, MakeHTTPS(URL));
  try
    Http.Request.Accept := 'application/json';
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, nil, False);
  finally
    Http.Free;
  end;
end;

end.
