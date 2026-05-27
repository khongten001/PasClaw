{
  PasClaw.Config - build-time version constants, on-disk config struct,
  and helpers for resolving the PasClaw home directory.
  Mirrors pkg/config in picoclaw.
}
unit PasClaw.Config;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes;

const
  { Build-time version: set the PASCLAW_VERSION environment variable before
    invoking fpc to override (the Makefile does this from `git describe`). }
  VersionRaw = {$I %PASCLAW_VERSION%};
  VersionFallback = '0.1.0-dev';

  EnvHome   = 'PASCLAW_HOME';
  EnvConfig = 'PASCLAW_CONFIG';

type
  TGatewayConfig = record
    LogLevel: string;
    BindAddr: string;
    Port:     Integer;
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
    Id:       string;
    Spec:     string;   { cron expression }
    Skill:    string;
    Args:     string;
    Enabled:  Boolean;
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
  fpjson, jsonparser;

constructor TConfig.Create;
begin
  inherited Create;
  DefaultProvider := 'anthropic';
  DefaultModel    := 'claude-opus-4-7';
  Gateway.LogLevel := 'info';
  Gateway.BindAddr := '127.0.0.1';
  Gateway.Port     := 8088;
end;

function ProviderToJSON(const P: TProviderConfig): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name',     P.Name);
  Result.Add('kind',     P.Kind);
  Result.Add('api_base', P.APIBase);
  Result.Add('api_key',  P.APIKey);
  Result.Add('model',    P.Model);
end;

function MCPToJSON(const M: TMCPServer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name',    M.Name);
  Result.Add('cmd',     M.Cmd);
  Result.Add('args',    M.Args);
  Result.Add('env',     M.Env);
  Result.Add('enabled', M.Enabled);
end;

function CronToJSON(const C: TCronEntry): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('id',      C.Id);
  Result.Add('spec',    C.Spec);
  Result.Add('skill',   C.Skill);
  Result.Add('args',    C.Args);
  Result.Add('enabled', C.Enabled);
end;

function SkillToJSON(const S: TSkillEntry): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name',    S.Name);
  Result.Add('source',  S.Source);
  Result.Add('enabled', S.Enabled);
end;

function TConfig.ToJSON: string;
var
  Root, Gw: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('default_provider', DefaultProvider);
    Root.Add('default_model',    DefaultModel);

    Gw := TJSONObject.Create;
    Gw.Add('log_level', Gateway.LogLevel);
    Gw.Add('bind_addr', Gateway.BindAddr);
    Gw.Add('port',      Gateway.Port);
    Root.Add('gateway', Gw);

    Arr := TJSONArray.Create;
    for i := 0 to High(Providers) do Arr.Add(ProviderToJSON(Providers[i]));
    Root.Add('providers', Arr);

    Arr := TJSONArray.Create;
    for i := 0 to High(MCPServers) do Arr.Add(MCPToJSON(MCPServers[i]));
    Root.Add('mcp_servers', Arr);

    Arr := TJSONArray.Create;
    for i := 0 to High(Crons) do Arr.Add(CronToJSON(Crons[i]));
    Root.Add('crons', Arr);

    Arr := TJSONArray.Create;
    for i := 0 to High(Skills) do Arr.Add(SkillToJSON(Skills[i]));
    Root.Add('skills', Arr);

    Result := Root.FormatJSON;
  finally
    Root.Free;
  end;
end;

procedure ReadProviders(Arr: TJSONArray; var Dest: array of TProviderConfig); forward;

procedure TConfig.FromJSON(const S: string);
var
  Root: TJSONObject;
  Obj: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  Data: TJSONData;
begin
  if Trim(S) = '' then Exit;
  Data := GetJSON(S);
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    Exit;
  end;
  Root := TJSONObject(Data);
  try
    DefaultProvider := Root.Get('default_provider', DefaultProvider);
    DefaultModel    := Root.Get('default_model',    DefaultModel);

    if Root.IndexOfName('gateway') >= 0 then
    begin
      Obj := Root.Objects['gateway'];
      Gateway.LogLevel := Obj.Get('log_level', Gateway.LogLevel);
      Gateway.BindAddr := Obj.Get('bind_addr', Gateway.BindAddr);
      Gateway.Port     := Obj.Get('port',      Gateway.Port);
    end;

    if Root.IndexOfName('providers') >= 0 then
    begin
      Arr := Root.Arrays['providers'];
      SetLength(Providers, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Obj := TJSONObject(Arr[i]);
        Providers[i].Name    := Obj.Get('name',     '');
        Providers[i].Kind    := Obj.Get('kind',     '');
        Providers[i].APIBase := Obj.Get('api_base', '');
        Providers[i].APIKey  := Obj.Get('api_key',  '');
        Providers[i].Model   := Obj.Get('model',    '');
      end;
    end;

    if Root.IndexOfName('mcp_servers') >= 0 then
    begin
      Arr := Root.Arrays['mcp_servers'];
      SetLength(MCPServers, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Obj := TJSONObject(Arr[i]);
        MCPServers[i].Name    := Obj.Get('name',    '');
        MCPServers[i].Cmd     := Obj.Get('cmd',     '');
        MCPServers[i].Args    := Obj.Get('args',    '');
        MCPServers[i].Env     := Obj.Get('env',     '');
        MCPServers[i].Enabled := Obj.Get('enabled', True);
      end;
    end;

    if Root.IndexOfName('crons') >= 0 then
    begin
      Arr := Root.Arrays['crons'];
      SetLength(Crons, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Obj := TJSONObject(Arr[i]);
        Crons[i].Id      := Obj.Get('id',      '');
        Crons[i].Spec    := Obj.Get('spec',    '');
        Crons[i].Skill   := Obj.Get('skill',   '');
        Crons[i].Args    := Obj.Get('args',    '');
        Crons[i].Enabled := Obj.Get('enabled', True);
      end;
    end;

    if Root.IndexOfName('skills') >= 0 then
    begin
      Arr := Root.Arrays['skills'];
      SetLength(Skills, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Obj := TJSONObject(Arr[i]);
        Skills[i].Name    := Obj.Get('name',    '');
        Skills[i].Source  := Obj.Get('source',  '');
        Skills[i].Enabled := Obj.Get('enabled', True);
      end;
    end;
  finally
    Root.Free;
  end;
end;

procedure ReadProviders(Arr: TJSONArray; var Dest: array of TProviderConfig);
begin
  { stub helper retained for forward decl; logic inlined above }
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
begin
  Result := Format('pasclaw %s (fpc %s %s/%s)',
    [FormatVersion, {$I %FPCVERSION%}, {$I %FPCTARGETOS%}, {$I %FPCTARGETCPU%}]);
end;

end.
