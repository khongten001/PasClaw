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
  PasClaw.Providers.Catalog;

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
      Model := ReadLineEcho('Default model (provider does not advertise one — required): ');
    if Trim(Model) = '' then Model := Spec.DefaultModel;

    case Spec.Auth.Kind of
      asNone:
        Key := '';
    else
      Key := ReadLineEcho(Spec.DisplayName + ' API key (leave blank to skip): ');
    end;

    Cfg.DefaultProvider := Spec.Kind;
    if Model <> '' then Cfg.DefaultModel := Model;

    UpsertProvider(Cfg, Spec, Model, Key);

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
