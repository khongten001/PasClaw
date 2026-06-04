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
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.Search.HTMLText,
  PasClaw.Net.SSRF,
  PasClaw.Tools.Sandbox;

type
  (* Redirect guard hooked into PasClaw.Providers.HTTP. Runs URLIsLocal
     on every 3xx target so a public→private redirect can't smuggle a
     request past the pre-check. Setting Allow := False aborts the
     redirect chain — the wrapper raises with Reason, and the outer
     try/except in Tool_WebFetch surfaces it as the same "SSRF
     blocked" string a direct hit would produce. *)
  TWebFetchRedirectGuard = class
    procedure OnRedirect(var Dest: string;
                          var Allow: Boolean;
                          var Reason: string);
  end;

function IsAbsoluteHttpURL(const S: string): Boolean;
{ True iff S has an http:// or https:// scheme. Anything else is
  either path-relative ("/login", "next.html") or protocol-relative
  ("//cdn.example.com/a"). The wrapper hands OnRedirect whatever the
  server's Location header said — which is frequently a bare path,
  NOT a full URL. Codex PR #85 P2 caught that we were rejecting
  "/login" as malformed. }
begin
  Result := (Length(S) >= 7) and
            (SameText(Copy(S, 1, 7),  'http://')  or
             (Length(S) >= 8) and SameText(Copy(S, 1, 8), 'https://'));
end;

procedure TWebFetchRedirectGuard.OnRedirect(var Dest: string;
                                              var Allow: Boolean;
                                              var Reason: string);
var
  Why: string;
begin
  Allow := True;
  if not NetworkBlockingActive then Exit;

  { Same-origin redirects retain the host that already passed the
    pre-check. Two flavours:
      "/path/next"     — path-relative; same scheme, host, port.
      "next.html"      — path-relative without leading slash; same.
    A protocol-relative URL ("//cdn.example.com/a") DOES change
    host so we still pass it through URLIsLocal — ExtractHost
    handles those since "//" parses as an authority without a
    scheme, and a bare authority is enough to read the host. }
  if not IsAbsoluteHttpURL(Dest) then
  begin
    if (Length(Dest) >= 2) and (Dest[1] = '/') and (Dest[2] = '/') then
    begin
      { Protocol-relative. Synthesise an http:// prefix purely for
        the parse — the underlying client will re-prefix with the
        current URL's scheme before connecting. }
      if URLIsLocal('http:' + Dest, Why) then
      begin
        Allow := False;
        Reason := Format(
          'SSRF: protocol-relative redirect to %s refused (%s; ' +
          'flip sandbox.block_private_networks=false in config.json to allow)',
          [Dest, Why]);
      end;
      Exit;
    end;
    { Path-relative — same host as the request that just passed
      the check. Let the request proceed. }
    Exit;
  end;

  if URLIsLocal(Dest, Why) then
  begin
    Allow := False;
    Reason := Format('SSRF: redirect to %s refused (%s; ' +
      'flip sandbox.block_private_networks=false in config.json to allow)',
      [Dest, Why]);
  end;
end;

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
  RedirectGuard: TWebFetchRedirectGuard;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
begin
  ErrMsg := '';
  Result := '';
  SetLength(Headers, 0);

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

  { SSRF pre-check on the initial URL. The redirect guard covers
    subsequent hops; both layers must pass for the request to land. }
  if NetworkBlockingActive then
  begin
    if URLIsLocal(URL, ErrMsg) then
    begin
      ErrMsg := 'web_fetch: SSRF: ' + URL + ' refused (' + ErrMsg +
        '; flip sandbox.block_private_networks=false in config.json to allow)';
      Exit;
    end;
    ErrMsg := '';
  end;

  RedirectGuard := TWebFetchRedirectGuard.Create;
  try
    Resp := GetURL(URL, Headers, 30,
                   'Mozilla/5.0 (PasClaw web_fetch)',
                   'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
                   RedirectGuard.OnRedirect);
  finally
    RedirectGuard.Free;
  end;

  if Resp.ErrorMsg <> '' then
  begin
    ErrMsg := 'web_fetch: HTTP error: ' + Resp.ErrorMsg;
    Exit;
  end;

  if (Pos('text/html',             Resp.ContentType) > 0) or
     (Pos('application/xhtml+xml', Resp.ContentType) > 0) or
     (Resp.ContentType = '') then
    Result := HTMLToText(Resp.Body, MaxChars)
  else if Pos('text/', Resp.ContentType) = 1 then
  begin
    Result := Resp.Body;
    if Length(Result) > MaxChars then
      Result := Copy(Result, 1, MaxChars) + #10 + '…(truncated)';
  end
  else
  begin
    ErrMsg := Format('web_fetch: unsupported content-type %s', [Resp.ContentType]);
    Exit;
  end;

  LogDebug('web_fetch url=%s bytes_in=%d chars_out=%d',
           [URL, Length(Resp.Body), Length(Result)]);
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
  T.Category    := tcReadOnly;  { HTTP GET only, no shared state }
  R.Register(T);
end;

end.
