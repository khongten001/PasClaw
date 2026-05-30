(*
  PasClaw.Tools.WebFetch - registers the web_fetch tool.

  Fetches an arbitrary HTTP/HTTPS URL with TIdHTTP, follows redirects
  (capped at 5), and converts the response body to plain text via
  PasClaw.Search.HTMLText. Default text cap is 50 KB to keep one
  page from blowing the model's context; an explicit `max_chars`
  argument can raise or lower it.

  Schema:
    {
      "url":       "<string, required>",
      "max_chars": <integer, optional, default 50000>
    }

  Safety: refuses non-http/https schemes (no file://, ftp://,
  data://) so a misbehaving model can't read local files via this
  path — it would have to go through fs_read which is sandbox-
  governed.

  Out of scope for Wave 1 (deferred to a later PR):
    - SSRF protection (block requests to RFC1918 / loopback /
      link-local) — picoclaw does this; PasClaw will when somebody
      actually deploys a public-facing agent.
    - Markdown conversion. The current strip-tags output is enough
      for the model to read.
    - User-Agent overrides per-request.
*)
unit PasClaw.Tools.WebFetch;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterWebFetchTool(R: TToolRegistry);

implementation

uses
  Classes,
  IdHTTP, IdSSLOpenSSL,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Search.HTMLText;

const
  DEFAULT_MAX_CHARS = 50000;
  HARD_MAX_CHARS    = 200000;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseIntArg(const ArgsJSON, Field: string; Default: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetInt(Field, Default);
    finally
      Obj.Free;
    end;
  except
    Result := Default;
  end;
end;

function LowerStartsWith(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
            SameText(Copy(S, 1, Length(Prefix)), Prefix);
end;

function Tool_WebFetch(const ArgsJSON: string; out ErrMsg: string): string;
var
  URL: string;
  MaxChars: Integer;
  HTTP: TIdHTTP;
  SSLHandler: TIdSSLIOHandlerSocketOpenSSL;
  Body: string;
  ContentType: string;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'url', URL) then
  begin
    ErrMsg := 'missing required argument: url';
    Exit;
  end;
  if not (LowerStartsWith(URL, 'http://') or LowerStartsWith(URL, 'https://')) then
  begin
    ErrMsg := 'web_fetch only supports http:// and https:// URLs';
    Exit;
  end;

  MaxChars := ParseIntArg(ArgsJSON, 'max_chars', DEFAULT_MAX_CHARS);
  if MaxChars < 100           then MaxChars := 100;
  if MaxChars > HARD_MAX_CHARS then MaxChars := HARD_MAX_CHARS;

  HTTP := TIdHTTP.Create(nil);
  SSLHandler := nil;
  try
    HTTP.HandleRedirects   := True;
    HTTP.RedirectMaximum   := 5;
    HTTP.ConnectTimeout    := 20000;
    HTTP.ReadTimeout       := 30000;
    HTTP.Request.UserAgent := 'Mozilla/5.0 (PasClaw web_fetch)';
    HTTP.Request.Accept    := 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5';

    if LowerStartsWith(URL, 'https://') then
    begin
      SSLHandler := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
      SSLHandler.SSLOptions.SSLVersions := [sslvTLSv1_2];
      HTTP.IOHandler := SSLHandler;
    end;

    try
      Body := HTTP.Get(URL);
    except
      on E: Exception do
      begin
        ErrMsg := 'web_fetch: HTTP error: ' + E.Message;
        Exit;
      end;
    end;

    ContentType := LowerCase(HTTP.Response.ContentType);
    if (Pos('text/html',             ContentType) > 0) or
       (Pos('application/xhtml+xml', ContentType) > 0) or
       (ContentType = '') then
      Result := HTMLToText(Body, MaxChars)
    else if Pos('text/', ContentType) = 1 then
    begin
      Result := Body;
      if Length(Result) > MaxChars then
        Result := Copy(Result, 1, MaxChars) + #10 + '…(truncated)';
    end
    else
    begin
      ErrMsg := Format('web_fetch: unsupported content-type %s', [ContentType]);
      Exit;
    end;
  finally
    HTTP.Free;
    if SSLHandler <> nil then SSLHandler.Free;
  end;

  LogDebug('web_fetch url=%s bytes_in=%d chars_out=%d',
           [URL, Length(Body), Length(Result)]);
end;

procedure RegisterWebFetchTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'web_fetch';
  T.Description :=
    'Fetch the contents of an HTTP/HTTPS URL and return readable plain text. ' +
    'Strips HTML tags, decodes entities, collapses whitespace. Useful after ' +
    'web_search to read a specific result page. Caps the output at 50 KB ' +
    'by default; pass max_chars to override (range 100–200000).';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"url":{"type":"string","description":"http:// or https:// URL."},' +
    '"max_chars":{"type":"integer","minimum":100,"maximum":200000,"description":"Output char cap (default 50000)."}' +
    '},"required":["url"]}';
  T.Handler     := Tool_WebFetch;
  T.IsCore      := True;
  R.Register(T);
end;

end.
