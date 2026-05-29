{
  PasClaw.Config - build-time version constants, on-disk config struct,
  and helpers for resolving the PasClaw home directory.
  Mirrors pkg/config in picoclaw.
}
unit PasClaw.Config;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  (* Single source of truth for the product version is VersionFallback below;
     it gets bumped at release time and both compilers see the same value.
     FPC additionally honors a PASCLAW_VERSION environment variable at
     compile time (used by `make` to inject the short git SHA into
     development builds) — if set it overrides VersionFallback at runtime;
     if empty the fallback wins. Delphi has no env-var equivalent, so
     Delphi builds always report VersionFallback. *)
  {$IFDEF FPC}
  VersionRaw = {$I %PASCLAW_VERSION%};
  {$ELSE}
  VersionRaw = '';
  {$ENDIF}
  VersionFallback = '0.1.0-dev';

  EnvHome   = 'PASCLAW_HOME';
  EnvConfig = 'PASCLAW_CONFIG';

type
  TGatewayConfig = record
    LogLevel: string;
    BindAddr: string;
    Port:     Integer;
  end;

  (*  TSandboxPolicy - opt-in workspace + shell hardening.

      RestrictToWorkspace
        When True, fs_read / fs_write / fs_list / fs_edit_hashline /
        fs_grep operations refuse paths outside Workspace, and the
        shell tool refuses commands whose absolute-path references
        leave Workspace. AllowReadOutsideWorkspace softens the read
        side (handy for letting an agent pull dependencies from
        /usr/include while still locking down writes).

      Workspace
        Absolute path of the directory the model may operate inside.
        Empty string means "use the current working directory at the
        time tools are configured" — handy for invoking
        `pasclaw agent` from a project root.

      AllowReadPaths / AllowWritePaths
        Glob-style patterns (NOT full regex, just '*' and '?')
        listing extra paths the model may touch beyond Workspace.
        Picoclaw uses regex; we use globs to avoid pulling in a
        regex dependency and because globs cover the common cases
        (/tmp/*, ~/.cache/agent/*, /usr/share/* ).

      CustomShellDeny
        Substrings appended to the built-in shell denylist. Each
        match is checked case-insensitively against the command
        string. Use this to block project-specific commands the
        built-in list misses.

      ShellDenyEnabled
        Master switch for the shell denylist. Default True. Set
        False only for trusted automation; doing so re-enables
        `sudo`, `rm -rf`, `dd`, `mkfs`, command-substitution,
        `curl | sh`, and every other pattern in the list.    *)
  TSandboxPolicy = record
    RestrictToWorkspace:       Boolean;
    AllowReadOutsideWorkspace: Boolean;
    Workspace:                 string;
    AllowReadPaths:            array of string;
    AllowWritePaths:           array of string;
    CustomShellDeny:           array of string;
    ShellDenyEnabled:          Boolean;
  end;

  TProviderConfig = record
    Name:    string;   { e.g. "anthropic", "openai" }
    Kind:    string;   { provider type id }
    APIBase: string;
    APIKey:  string;
    Model:   string;
  end;

  TMCPServer = record
    Name:    string;
    Cmd:     string;
    Args:    string;
    Env:     string;
    Enabled: Boolean;
  end;

  TCronEntry = record
    Id:            string;
    Spec:          string;   { cron expression }
    Skill:         string;
    Args:          string;
    Enabled:       Boolean;
    ChannelKind:   string;   { 'discord' | 'slack' | 'teams' | 'webhook' | 'line' | 'whatsapp' | '' }
    ChannelTarget: string;   { webhook URL, LINE userId, WhatsApp phone, etc. }
  end;

  TSkillEntry = record
    Name:    string;
    Source:  string;   { builtin | path | url }
    Enabled: Boolean;
  end;

  TConfig = class
  public
    DefaultProvider: string;
    DefaultModel:    string;
    Gateway:    TGatewayConfig;
    Sandbox:    TSandboxPolicy;
    Providers:  array of TProviderConfig;
    MCPServers: array of TMCPServer;
    Crons:      array of TCronEntry;
    Skills:     array of TSkillEntry;
    constructor Create;
    function  ToJSON: string;
    procedure FromJSON(const S: string);
  end;

function GetHome: string;
function GetConfigPath: string;
function LoadConfig: TConfig;
procedure SaveConfig(C: TConfig);
function FormatVersion: string;
function FormatBuildInfo: string;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON;

constructor TConfig.Create;
begin
  inherited Create;
  DefaultProvider := 'anthropic';
  DefaultModel    := 'claude-opus-4-7';
  Gateway.LogLevel := 'info';
  Gateway.BindAddr := '127.0.0.1';
  Gateway.Port     := 8088;
  { Sandbox defaults: workspace boundary OFF for backwards compat
    (existing configs do not have a sandbox section), shell denylist
    ON because it's a strict safety upgrade over the previous
    six-substring check and no legitimate use ever passed it. Flip
    RestrictToWorkspace to True in config.json to lock the FS tools
    down to a chosen directory. }
  Sandbox.RestrictToWorkspace       := False;
  Sandbox.AllowReadOutsideWorkspace := False;
  Sandbox.Workspace                 := '';
  Sandbox.ShellDenyEnabled          := True;
end;

function ProviderToJSON(const P: TProviderConfig): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('name',     P.Name);
  Result.PutStr('kind',     P.Kind);
  Result.PutStr('api_base', P.APIBase);
  Result.PutStr('api_key',  P.APIKey);
  Result.PutStr('model',    P.Model);
end;

function MCPToJSON(const M: TMCPServer): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('name',    M.Name);
  Result.PutStr ('cmd',     M.Cmd);
  Result.PutStr ('args',    M.Args);
  Result.PutStr ('env',     M.Env);
  Result.PutBool('enabled', M.Enabled);
end;

function CronToJSON(const C: TCronEntry): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('id',      C.Id);
  Result.PutStr ('spec',    C.Spec);
  Result.PutStr ('skill',   C.Skill);
  Result.PutStr ('args',    C.Args);
  Result.PutBool('enabled', C.Enabled);
  if C.ChannelKind   <> '' then Result.PutStr('channel_kind',   C.ChannelKind);
  if C.ChannelTarget <> '' then Result.PutStr('channel_target', C.ChannelTarget);
end;

function SkillToJSON(const S: TSkillEntry): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('name',    S.Name);
  Result.PutStr ('source',  S.Source);
  Result.PutBool('enabled', S.Enabled);
end;

function TConfig.ToJSON: string;
var
  Root, Gw, Tmp: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('default_provider', DefaultProvider);
    Root.PutStr('default_model',    DefaultModel);

    Gw := TJsonObject.Create;
    Gw.PutStr ('log_level', Gateway.LogLevel);
    Gw.PutStr ('bind_addr', Gateway.BindAddr);
    Gw.PutInt ('port',      Gateway.Port);
    Root.PutObject('gateway', Gw);

    Tmp := TJsonObject.Create;
    Tmp.PutBool('restrict_to_workspace',        Sandbox.RestrictToWorkspace);
    Tmp.PutBool('allow_read_outside_workspace', Sandbox.AllowReadOutsideWorkspace);
    Tmp.PutStr ('workspace',                    Sandbox.Workspace);
    Tmp.PutBool('shell_deny_enabled',           Sandbox.ShellDenyEnabled);
    Arr := TJsonArray.Create;
    for i := 0 to High(Sandbox.AllowReadPaths)  do Arr.AddStr(Sandbox.AllowReadPaths[i]);
    Tmp.PutArray('allow_read_paths',  Arr);
    Arr := TJsonArray.Create;
    for i := 0 to High(Sandbox.AllowWritePaths) do Arr.AddStr(Sandbox.AllowWritePaths[i]);
    Tmp.PutArray('allow_write_paths', Arr);
    Arr := TJsonArray.Create;
    for i := 0 to High(Sandbox.CustomShellDeny) do Arr.AddStr(Sandbox.CustomShellDeny[i]);
    Tmp.PutArray('custom_shell_deny', Arr);
    Root.PutObject('sandbox', Tmp);

    Arr := TJsonArray.Create;
    for i := 0 to High(Providers) do
    begin
      Tmp := ProviderToJSON(Providers[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('providers', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(MCPServers) do
    begin
      Tmp := MCPToJSON(MCPServers[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('mcp_servers', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(Crons) do
    begin
      Tmp := CronToJSON(Crons[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('crons', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(Skills) do
    begin
      Tmp := SkillToJSON(Skills[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('skills', Arr);

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure TConfig.FromJSON(const S: string);
var
  Root, Obj, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  if Trim(S) = '' then Exit;
  Root := TJsonObject.Parse(S);
  if Root = nil then Exit;
  try
    DefaultProvider := Root.GetStr('default_provider', DefaultProvider);
    DefaultModel    := Root.GetStr('default_model',    DefaultModel);

    Obj := Root.ChildObject('gateway');
    if Obj <> nil then
    try
      Gateway.LogLevel := Obj.GetStr('log_level', Gateway.LogLevel);
      Gateway.BindAddr := Obj.GetStr('bind_addr', Gateway.BindAddr);
      Gateway.Port     := Obj.GetInt('port',      Gateway.Port);
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('sandbox');
    if Obj <> nil then
    try
      Sandbox.RestrictToWorkspace       := Obj.GetBool('restrict_to_workspace',        Sandbox.RestrictToWorkspace);
      Sandbox.AllowReadOutsideWorkspace := Obj.GetBool('allow_read_outside_workspace', Sandbox.AllowReadOutsideWorkspace);
      Sandbox.Workspace                 := Obj.GetStr ('workspace',                    Sandbox.Workspace);
      Sandbox.ShellDenyEnabled          := Obj.GetBool('shell_deny_enabled',           Sandbox.ShellDenyEnabled);
      Arr := Obj.ChildArray('allow_read_paths');
      if Arr <> nil then
      try
        SetLength(Sandbox.AllowReadPaths, Arr.Count);
        for i := 0 to Arr.Count - 1 do Sandbox.AllowReadPaths[i] := Arr.ItemStr(i, '');
      finally
        Arr.Free;
      end;
      Arr := Obj.ChildArray('allow_write_paths');
      if Arr <> nil then
      try
        SetLength(Sandbox.AllowWritePaths, Arr.Count);
        for i := 0 to Arr.Count - 1 do Sandbox.AllowWritePaths[i] := Arr.ItemStr(i, '');
      finally
        Arr.Free;
      end;
      Arr := Obj.ChildArray('custom_shell_deny');
      if Arr <> nil then
      try
        SetLength(Sandbox.CustomShellDeny, Arr.Count);
        for i := 0 to Arr.Count - 1 do Sandbox.CustomShellDeny[i] := Arr.ItemStr(i, '');
      finally
        Arr.Free;
      end;
    finally
      Obj.Free;
    end;

    Arr := Root.ChildArray('providers');
    if Arr <> nil then
    try
      SetLength(Providers, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Providers[i].Name    := Item.GetStr('name',     '');
          Providers[i].Kind    := Item.GetStr('kind',     '');
          Providers[i].APIBase := Item.GetStr('api_base', '');
          Providers[i].APIKey  := Item.GetStr('api_key',  '');
          Providers[i].Model   := Item.GetStr('model',    '');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('mcp_servers');
    if Arr <> nil then
    try
      SetLength(MCPServers, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          MCPServers[i].Name    := Item.GetStr ('name',    '');
          MCPServers[i].Cmd     := Item.GetStr ('cmd',     '');
          MCPServers[i].Args    := Item.GetStr ('args',    '');
          MCPServers[i].Env     := Item.GetStr ('env',     '');
          MCPServers[i].Enabled := Item.GetBool('enabled', True);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('crons');
    if Arr <> nil then
    try
      SetLength(Crons, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Crons[i].Id            := Item.GetStr ('id',             '');
          Crons[i].Spec          := Item.GetStr ('spec',           '');
          Crons[i].Skill         := Item.GetStr ('skill',          '');
          Crons[i].Args          := Item.GetStr ('args',           '');
          Crons[i].Enabled       := Item.GetBool('enabled',        True);
          Crons[i].ChannelKind   := Item.GetStr ('channel_kind',   '');
          Crons[i].ChannelTarget := Item.GetStr ('channel_target', '');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('skills');
    if Arr <> nil then
    try
      SetLength(Skills, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Skills[i].Name    := Item.GetStr ('name',    '');
          Skills[i].Source  := Item.GetStr ('source',  '');
          Skills[i].Enabled := Item.GetBool('enabled', True);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

function GetHome: string;
var
  H: string;
begin
  H := GetEnvironmentVariable(EnvHome);
  if H <> '' then Exit(H);
  Result := JoinPath(HomeDir, '.pasclaw');
end;

function GetConfigPath: string;
var
  Override_: string;
begin
  Override_ := GetEnvironmentVariable(EnvConfig);
  if Override_ <> '' then Exit(Override_);
  Result := JoinPath(GetHome, 'config.json');
end;

function LoadConfig: TConfig;
var
  Path, S: string;
begin
  Result := TConfig.Create;
  Path := GetConfigPath;
  if not FileExists(Path) then Exit;
  S := ReadFileText(Path);
  try
    Result.FromJSON(S);
  except
    on E: Exception do
      { Bad config: keep defaults rather than aborting CLI startup. }
      ;
  end;
end;

procedure SaveConfig(C: TConfig);
begin
  WriteFileText(GetConfigPath, C.ToJSON);
end;

function FormatVersion: string;
begin
  if VersionRaw = '' then Result := VersionFallback else Result := VersionRaw;
end;

function FormatBuildInfo: string;
{$IFDEF FPC}
const
  FpcVer   = {$I %FPCVERSION%};
  FpcOS    = {$I %FPCTARGETOS%};
  FpcCPU   = {$I %FPCTARGETCPU%};
begin
  Result := Format('pasclaw %s (fpc %s %s/%s)', [FormatVersion, FpcVer, FpcOS, FpcCPU]);
end;
{$ELSE}
begin
  Result := Format('pasclaw %s (delphi)', [FormatVersion]);
end;
{$ENDIF}

end.
