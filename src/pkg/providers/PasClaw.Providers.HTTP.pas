{
  PasClaw.Providers.HTTP - thin wrapper around TIdHTTP for JSON POSTs.
  Builds in both Delphi and FPC (Indy works in both). Under FPC the project
  vendors Indy via `make get-indy`; under Delphi it ships with RAD Studio.

  HTTPS support requires OpenSSL. On Linux: package "libssl-dev" / runtime
  "libssl.so.3"; on Windows: copy libeay32.dll + ssleay32.dll next to the
  binary. We probe two search locations before the first HTTPS request:
    1. $PASCLAW_OPENSSL_DIR (if set)
    2. the directory holding pasclaw.exe
  If neither resolves a working OpenSSL pair we surface an actionable
  error message instead of Indy's cryptic 'Could not load SSL library.'.
}
unit PasClaw.Providers.HTTP;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  IdHTTP, IdSSLOpenSSL, IdSSLOpenSSLHeaders,
  IdGlobal, IdExceptionCore, IdException;

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

{ Binary HTTP GET into a caller-owned stream. Use this for zip
  downloads, embedding fetches, etc. — anything where TStringStream's
  UTF-8 decoding would corrupt the payload. Caller positions and
  sizes Stream however they need afterward.

  Returns a THTTPResult with StatusCode and ErrorMsg set; Body stays
  empty (the bytes went into Stream). HandleRedirects is on so a
  GitHub codeload 302 -> Amazon S3 URL works transparently. }
function GetURLToStream(const URL: string; Stream: TStream;
                        const Headers: array of THeaderPair;
                        TimeoutSeconds: Integer): THTTPResult;

function MakeHeader(const Name, Value: string): THeaderPair;

{ Returns True if Indy can load OpenSSL; otherwise False and ErrMsg
  contains an actionable message naming the DLLs and the override env
  var. Safe to call multiple times — probing happens once and caches. }
function EnsureOpenSSL(out ErrMsg: string): Boolean;

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
  { Force UTF-8 on the response stream. Under Delphi modern, TStringStream
    defaults to TEncoding.Default (the system codepage), which mangles
    non-ASCII bytes in JSON responses. Under FPC the encoding arg is
    accepted and behaves the same. }
  Resp := TStringStream.Create('', TEncoding.UTF8);
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

var
  GSSLProbed: Boolean = False;
  GSSLAvailable: Boolean = False;

procedure ProbeOpenSSL;
{ Steer Indy's loader at known-good locations before its first SSL call.
  Side-effecting at unit init was tempting but ParamStr(0) and
  GetEnvironmentVariable are friendlier inside a regular procedure
  invoked lazily on the first HTTPS request. }
var
  CustomDir: string;
begin
  if GSSLProbed then Exit;
  GSSLProbed := True;

  CustomDir := GetEnvironmentVariable('PASCLAW_OPENSSL_DIR');
  if CustomDir = '' then
    CustomDir := ExtractFilePath(ParamStr(0));
  if (CustomDir <> '') and DirectoryExists(CustomDir) then
    IdOpenSSLSetLibPath(CustomDir);

  GSSLAvailable := LoadOpenSSLLibrary;
end;

function OpenSSLHelpMessage: string;
begin
  Result :=
    'TLS support requires OpenSSL but the libraries could not be loaded.' + sLineBreak +
    'Indy reports: ' + WhichFailedToLoad + sLineBreak +
    {$IFDEF MSWINDOWS}
    'On Windows, place libeay32.dll and ssleay32.dll next to pasclaw.exe,' + sLineBreak +
    'or set PASCLAW_OPENSSL_DIR to a directory containing them.';
    {$ELSE}
    'On Linux/macOS, install OpenSSL (libssl + libcrypto) via your package' + sLineBreak +
    'manager, or set PASCLAW_OPENSSL_DIR to a directory containing them.';
    {$ENDIF}
end;

function EnsureOpenSSL(out ErrMsg: string): Boolean;
begin
  ProbeOpenSSL;
  Result := GSSLAvailable;
  if Result then ErrMsg := '' else ErrMsg := OpenSSLHelpMessage;
end;

function NewClient(TimeoutSeconds: Integer; HTTPS: Boolean;
                   out ErrMsg: string): TIdHTTP;
var
  SSL: TIdSSLIOHandlerSocketOpenSSL;
begin
  ErrMsg := '';
  Result := TIdHTTP.Create(nil);
  Result.ConnectTimeout := TimeoutSeconds * 1000;
  Result.ReadTimeout    := TimeoutSeconds * 1000;
  Result.HandleRedirects := True;
  Result.Request.UserAgent := 'PasClaw/0.1 (+https://github.com/FMXExpress/PasClaw)';
  if HTTPS then
  begin
    if not EnsureOpenSSL(ErrMsg) then Exit;
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
  SSLErr: string;
begin
  Http := NewClient(TimeoutSeconds, MakeHTTPS(URL), SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.Body       := '';
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  { UTF-8 encode the request body; default codepage would corrupt non-ASCII
    JSON values (user names, system prompts, content blocks). }
  Req  := TStringStream.Create(JSON, TEncoding.UTF8);
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
  SSLErr: string;
begin
  Http := NewClient(TimeoutSeconds, MakeHTTPS(URL), SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.Body       := '';
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  try
    Http.Request.Accept := 'application/json';
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, nil, False);
  finally
    Http.Free;
  end;
end;

function GetURLToStream(const URL: string; Stream: TStream;
                        const Headers: array of THeaderPair;
                        TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
  SSLErr: string;
begin
  Result.StatusCode := 0;
  Result.Body       := '';
  Result.ErrorMsg   := '';
  Http := NewClient(TimeoutSeconds, MakeHTTPS(URL), SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  try
    Http.Request.Accept := '*/*';
    ApplyHeaders(Http, Headers);
    try
      Http.Get(URL, Stream);
      Result.StatusCode := Http.ResponseCode;
    except
      on E: EIdHTTPProtocolException do
      begin
        Result.StatusCode := E.ErrorCode;
        Result.ErrorMsg   := E.Message;
      end;
      on E: Exception do
      begin
        Result.StatusCode := Http.ResponseCode;
        Result.ErrorMsg   := E.Message;
      end;
    end;
  finally
    Http.Free;
  end;
end;

end.
