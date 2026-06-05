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

function WriteBodyToFile(const Path, Body: string; out ErrMsg: string): Boolean;
{ Write the UTF-8 bytes of Body to Path, creating parent dirs as needed.
  Returns False with ErrMsg on any failure. Direct TFileStream avoids
  TStringList.SaveToFile's TEncoding.Default codepage trap on Delphi/
  Windows — content with non-ASCII bytes would otherwise be mangled
  on the way to disk. }
var
  Dir: string;
  Bytes: TBytes;
  FS: TFileStream;
begin
  Result := False;
  ErrMsg := '';
  Dir := ExtractFilePath(Path);
  if (Dir <> '') and not DirectoryExists(Dir) then
    if not ForceDirectories(Dir) then
    begin
      ErrMsg := 'web_fetch: cannot create parent directory: ' + Dir;
      Exit;
    end;
  try
    FS := TFileStream.Create(Path, fmCreate);
    try
      Bytes := TEncoding.UTF8.GetBytes(Body);
      if Length(Bytes) > 0 then
        FS.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      FS.Free;
    end;
    Result := True;
  except
    on E: Exception do
      ErrMsg := 'web_fetch: write failed: ' + E.Message;
  end;
end;

function Tool_WebFetch(const ArgsJSON: string; out ErrMsg: string): string;
var
  URL, SaveTo, SandboxReason, Preview: string;
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

  { Optional curl -o: when save_to is set, the full response body is
    written to disk and the tool result becomes a small receipt
    instead of the inlined content. The model then uses fs_read /
    fs_grep on the saved file. This skips the max_chars cap entirely
    so the model can pull down arbitrarily large pages / API dumps
    without blowing the context window. }
  ParseStringArg(ArgsJSON, 'save_to', SaveTo);
  if SaveTo <> '' then
  begin
    if not CanWritePath(SaveTo, SandboxReason) then
    begin
      ErrMsg := 'web_fetch: save_to refused: ' + SandboxReason;
      Exit;
    end;
  end;

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

  { save_to path: write full body to disk regardless of content-type
    (operator already allowed the path via the sandbox), return only
    a short receipt with a preview. }
  if SaveTo <> '' then
  begin
    if not WriteBodyToFile(SaveTo, Resp.Body, ErrMsg) then Exit;
    Preview := Copy(Resp.Body, 1, 200);
    Result := Format('web_fetch: saved %d bytes to %s (status %d, content-type %s)',
                     [Length(Resp.Body), SaveTo, Resp.StatusCode, Resp.ContentType]);
    if Trim(Preview) <> '' then
      Result := Result + sLineBreak + 'preview: ' + Preview;
    LogDebug('web_fetch url=%s bytes_in=%d saved_to=%s',
             [URL, Length(Resp.Body), SaveTo]);
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
    ErrMsg := Format('web_fetch: unsupported content-type %s (try save_to to download as-is)',
                     [Resp.ContentType]);
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
    'Fetch the contents of an HTTP/HTTPS URL. By default returns ' +
    'readable plain text (strips HTML tags, decodes entities) capped at ' +
    'max_chars (default 50000). Pass save_to to write the full body to a ' +
    'file under the workspace instead — useful for large pages, binary ' +
    'downloads, or anything that would blow the model''s context. When ' +
    'save_to is set, the tool result is a short receipt + preview, and ' +
    'the model uses fs_read / fs_grep on the saved file.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"url":{"type":"string","description":"http:// or https:// URL."},' +
    '"max_chars":{"type":"integer","minimum":100,"maximum":200000,"description":"Inline output char cap (default 50000). Ignored when save_to is set."},' +
    '"save_to":{"type":"string","description":"Optional workspace-relative path. When set, the full response body is written there and the tool returns a receipt only."}' +
    '},"required":["url"]}';
  T.Handler     := Tool_WebFetch;
  T.IsCore      := True;
  T.Category    := tcReadOnly;  { HTTP GET only, no shared state }
  R.Register(T);
end;

end.
