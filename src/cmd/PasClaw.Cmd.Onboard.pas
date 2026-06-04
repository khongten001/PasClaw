(*
  Onboard — initialise config and workspace. Creates ~/.pasclaw, a
  starter config.json, and walks the user through picking a provider
  from the catalog (PasClaw.Providers.Catalog). Selection by number
  populates the saved TProviderConfig with the catalog's default base
  URL and default model; the user is prompted for the API key only when
  the provider's auth scheme requires one (skipped for local providers
  like Ollama and vLLM).
*)
unit PasClaw.Cmd.Onboard;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Onboard_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Catalog,
  PasClaw.MCP.Catalog;

function ReadLineEcho(const Prompt: string): string;
begin
  Write(Prompt);
  ReadLn(Result);
end;

procedure PrintCatalog(const Catalog: TProviderSpecArray);
var
  i: Integer;
begin
  WriteLn(Ansi.Bold, 'Choose a provider:', Ansi.Reset);
  for i := 0 to High(Catalog) do
    WriteLn(Format(' %2d. %-22s %s', [i + 1, Catalog[i].DisplayName, Catalog[i].Notes]));
end;

function PickFromCatalog(const Catalog: TProviderSpecArray;
                         const DefaultKind: string;
                         out Spec: TProviderSpec): Boolean;
var
  Input: string;
  Idx, DefaultIdx, i: Integer;
begin
  Result := False;
  DefaultIdx := -1;
  for i := 0 to High(Catalog) do
    if SameText(Catalog[i].Kind, DefaultKind) then
    begin
      DefaultIdx := i;
      Break;
    end;
  PrintCatalog(Catalog);
  if DefaultIdx >= 0 then
    Input := ReadLineEcho(Format('Pick [1-%d] (default %d=%s): ',
              [Length(Catalog), DefaultIdx + 1, Catalog[DefaultIdx].DisplayName]))
  else
    Input := ReadLineEcho(Format('Pick [1-%d]: ', [Length(Catalog)]));
  Input := Trim(Input);
  if (Input = '') and (DefaultIdx >= 0) then
  begin
    Spec := Catalog[DefaultIdx];
    Exit(True);
  end;
  if not TryStrToInt(Input, Idx) then Exit;
  if (Idx < 1) or (Idx > Length(Catalog)) then Exit;
  Spec := Catalog[Idx - 1];
  Result := True;
end;

procedure UpsertProvider(Cfg: TConfig; const Spec: TProviderSpec;
                         const Model, Key: string);
var
  i: Integer;
  Found: Boolean;
begin
  Found := False;
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Spec.Kind) then
    begin
      if Key <> '' then Cfg.Providers[i].APIKey := Key;
      if Model <> '' then Cfg.Providers[i].Model := Model;
      Cfg.Providers[i].Kind := Spec.Kind;
      if Cfg.Providers[i].APIBase = '' then
        Cfg.Providers[i].APIBase := Spec.DefaultBase;
      Found := True;
      Break;
    end;
  if Found then Exit;

  SetLength(Cfg.Providers, Length(Cfg.Providers) + 1);
  with Cfg.Providers[High(Cfg.Providers)] do
  begin
    Name    := Spec.Kind;
    Kind    := Spec.Kind;
    APIBase := Spec.DefaultBase;
    APIKey  := Key;
    if Model <> '' then
      Cfg.Providers[High(Cfg.Providers)].Model := Model
    else
      Cfg.Providers[High(Cfg.Providers)].Model := Spec.DefaultModel;
  end;
end;

function IsMCPInstalled(Cfg: TConfig; const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Cfg.MCPServers) do
    if SameText(Cfg.MCPServers[i].Name, Name) then Exit(True);
end;

procedure UpsertCatalogMCP(Cfg: TConfig; const Entry: TMCPCatalogEntry;
                           const HeaderVal: string);
var
  i: Integer;
begin
  { Mirrors Cmd.MCP.DoInstall's upsert — if an entry for this catalog
    name already exists, refresh URL/auth/enabled in place rather than
    duplicating. The MCP Cmd field stores the URL (HTTP MCP transport
    uses it directly); Args stores the literal Authorization header
    value the client puts on every request. }
  for i := 0 to High(Cfg.MCPServers) do
    if SameText(Cfg.MCPServers[i].Name, Entry.Name) then
    begin
      Cfg.MCPServers[i].Cmd     := Entry.URL;
      Cfg.MCPServers[i].Args    := HeaderVal;
      Cfg.MCPServers[i].Enabled := True;
      Exit;
    end;
  SetLength(Cfg.MCPServers, Length(Cfg.MCPServers) + 1);
  with Cfg.MCPServers[High(Cfg.MCPServers)] do
  begin
    Name    := Entry.Name;
    Cmd     := Entry.URL;
    Args    := HeaderVal;
    Env     := '';
    Enabled := True;
  end;
end;

procedure PromptVaultTools(Cfg: TConfig);
{ Opt-in toggle for the agent-callable vault_search / vault_get
  tools. Default YES because pressing Enter through onboarding
  should land a useful agent, and the vault tools are read-only
  HTTP GETs against a curated registry — no execution path. User
  can flip back later by editing config.json or re-running
  onboard. }
var
  Choice: string;
begin
  WriteLn;
  WriteLn(Ansi.Bold, 'Code Vault tools', Ansi.Reset);
  WriteLn(Ansi.Dim,
    'vault_search / vault_get let the agent discover Object Pascal source code',
    Ansi.Reset);
  WriteLn(Ansi.Dim,
    '(samples, components, libraries) on pasclaw.dev — read-only HTTP GETs.',
    Ansi.Reset);
  WriteLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable vault tools for the agent [Y/n]: ')));
  if (Choice = '') or (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.VaultToolsEnabled := True;
    WriteLn('  ', Ansi.Green, '✓', Ansi.Reset, ' vault_search / vault_get enabled');
  end
  else
  begin
    Cfg.VaultToolsEnabled := False;
    WriteLn('  ', Ansi.Dim, '(skipped — flip vault_tools_enabled in config.json to enable later)', Ansi.Reset);
  end;
end;

procedure PromptMCPInstalls(Cfg: TConfig);
var
  Entries: TMCPCatalogEntryArray;
  Entry: TMCPCatalogEntry;
  i: Integer;
  Choice, Token, HeaderVal, EnvTok: string;
  AlreadyInstalled: Boolean;
begin
  Entries := KnownMCPServers;
  if Length(Entries) = 0 then Exit;

  WriteLn;
  WriteLn(Ansi.Bold, 'Optional: enable built-in MCP servers', Ansi.Reset);
  WriteLn(Ansi.Dim,
    'These give the agent extra capabilities via the MCP protocol.',
    Ansi.Reset);
  WriteLn(Ansi.Dim,
    'Skip what you don''t want — you can install later with ',
    Ansi.Reset, '`pasclaw mcp install <name>`', Ansi.Dim, '.', Ansi.Reset);
  WriteLn;

  for i := 0 to High(Entries) do
  begin
    Entry := Entries[i];
    AlreadyInstalled := IsMCPInstalled(Cfg, Entry.Name);

    WriteLn(Ansi.Bold, '  ', Entry.Name, Ansi.Reset);
    WriteLn('  ', Ansi.Dim, Entry.Desc, Ansi.Reset);
    if Entry.Docs <> '' then
      WriteLn('  ', Ansi.Dim, Entry.Docs, Ansi.Reset);
    if AlreadyInstalled then
    begin
      WriteLn('  ', Ansi.Green, '(already installed — skipping)', Ansi.Reset);
      WriteLn;
      Continue;
    end;

    Choice := Trim(LowerCase(ReadLineEcho('  Enable [y/N]: ')));
    if (Choice <> 'y') and (Choice <> 'yes') then
    begin
      WriteLn;
      Continue;
    end;

    { Auth-less entries (runpod-docs today) install with no token. }
    if Entry.EnvVar = '' then
    begin
      UpsertCatalogMCP(Cfg, Entry, '');
      WriteLn('  ', Ansi.Green, '✓', Ansi.Reset, ' installed ',
              Entry.Name, ' ', Ansi.Dim, '(no auth)', Ansi.Reset);
      WriteLn;
      Continue;
    end;

    { Prefer the env var when it's already set — same path
      pasclaw mcp install takes today. }
    EnvTok := GetEnvironmentVariable(Entry.EnvVar);
    if EnvTok <> '' then
    begin
      WriteLn('  ', Ansi.Dim, 'using ', Entry.EnvVar,
              ' from environment', Ansi.Reset);
      HeaderVal := FormatAuthHeaderFromToken(Entry, EnvTok);
    end
    else
    begin
      { No-echo input — pasted tokens stay out of terminal scrollback
        and any screen recordings / shared sessions. Codex P2 on
        PR #126. }
      Token := Trim(ReadSecretLine('  ' + Entry.EnvVar + ' (paste, or blank to skip auth): '));
      HeaderVal := FormatAuthHeaderFromToken(Entry, Token);
      if HeaderVal = '' then
        WriteLn('  ', Ansi.Yellow, '!', Ansi.Reset,
                ' installing with no auth header — set ', Entry.EnvVar,
                ' and re-run `pasclaw mcp install ', Entry.Name,
                '` later to refresh.');
    end;

    UpsertCatalogMCP(Cfg, Entry, HeaderVal);
    WriteLn('  ', Ansi.Green, '✓', Ansi.Reset, ' installed ', Entry.Name);
    WriteLn;
  end;
end;

function Cmd_Onboard_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Home, CfgPath: string;
  Key, Model: string;
  Catalog: TProviderSpecArray;
  Spec: TProviderSpec;
begin
  Home    := GetHome;
  CfgPath := GetConfigPath;

  WriteLn(Ansi.Bold, 'Onboarding PasClaw', Ansi.Reset);
  WriteLn('  home:   ', Home);
  WriteLn('  config: ', CfgPath);
  WriteLn;

  if not EnsureDir(Home) then
  begin
    LogError('failed to create home dir: %s', [Home]);
    Exit(1);
  end;
  EnsureDir(JoinPath(Home, 'workspace'));
  EnsureDir(JoinPath(Home, 'workspace/memory'));
  EnsureDir(JoinPath(Home, 'workspace/skills'));
  EnsureDir(JoinPath(Home, 'logs'));

  if FileExists(CfgPath) then
  begin
    Cfg := LoadConfig;
    WriteLn('Existing config detected; updating in place.');
  end
  else
    Cfg := TConfig.Create;

  try
    Catalog := AllProviderSpecs;
    if not PickFromCatalog(Catalog, 'anthropic', Spec) then
    begin
      WriteLn(Ansi.Yellow, 'no valid selection — config not changed', Ansi.Reset);
      Exit(1);
    end;

    if Spec.DefaultModel <> '' then
      Model := ReadLineEcho(Format('Default model [%s]: ', [Spec.DefaultModel]))
    else
      repeat
        Model := ReadLineEcho('Default model (provider does not advertise one — required): ');
      until Trim(Model) <> '';
    if Trim(Model) = '' then Model := Spec.DefaultModel;

    case Spec.Auth.Kind of
      asNone:
        Key := '';
    else
      { No-echo for the same reason as the MCP token path below —
        Codex P2 on PR #126 was scoped to MCP but the provider-key
        prompt has the identical exposure (pasted credential lands
        in terminal scrollback / screen recordings). }
      Key := ReadSecretLine(Spec.DisplayName + ' API key (leave blank to skip): ');
    end;

    Cfg.DefaultProvider := Spec.Kind;
    if Model <> '' then Cfg.DefaultModel := Model;

    UpsertProvider(Cfg, Spec, Model, Key);

    { Built-in MCP catalog — opt-in per entry. Picoclaw's rule is
      "never preloaded"; we keep the same default-off prompt so a
      user pressing Enter through onboarding doesn't install
      anything they didn't explicitly say yes to. Auth tokens
      captured here land in config.json as a literal Authorization
      header value (same shape pasclaw mcp install writes when an
      env var is set). }
    PromptMCPInstalls(Cfg);
    PromptVaultTools(Cfg);

    SaveConfig(Cfg);
    WriteLn;
    WriteLn(Ansi.Green, '✓', Ansi.Reset, ' wrote ', CfgPath);
    WriteLn('Next: ', Ansi.Bold, 'pasclaw agent "hello"', Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
