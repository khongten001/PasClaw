{
  Onboard — initialise config and workspace. Mirrors
  cmd/picoclaw/internal/onboard. Creates ~/.pasclaw, a starter config.json,
  and prompts for the default provider's API key.
}
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
  PasClaw.Logger;

function ReadLineEcho(const Prompt: string): string;
begin
  Write(Prompt);
  ReadLn(Result);
end;

function Cmd_Onboard_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Home, CfgPath: string;
  Key, Prov, Model: string;
  i: Integer;
  Found: Boolean;
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
    Prov := ReadLineEcho('Default provider [anthropic]: ');
    if Trim(Prov) = '' then Prov := 'anthropic';
    Model := ReadLineEcho('Default model [claude-opus-4-7]: ');
    if Trim(Model) = '' then Model := 'claude-opus-4-7';
    Key := ReadLineEcho(Prov + ' API key (leave blank to skip): ');

    Cfg.DefaultProvider := Prov;
    Cfg.DefaultModel    := Model;

    Found := False;
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, Prov) then
      begin
        if Key <> '' then Cfg.Providers[i].APIKey := Key;
        Cfg.Providers[i].Model := Model;
        Found := True;
        Break;
      end;
    if not Found then
    begin
      SetLength(Cfg.Providers, Length(Cfg.Providers) + 1);
      with Cfg.Providers[High(Cfg.Providers)] do
      begin
        Name    := Prov;
        Kind    := Prov;
        Model   := Model;
        APIKey  := Key;
        if      Prov = 'anthropic' then APIBase := 'https://api.anthropic.com'
        else if Prov = 'openai'    then APIBase := 'https://api.openai.com';
      end;
    end;

    SaveConfig(Cfg);
    WriteLn;
    WriteLn(Ansi.Green, '✓', Ansi.Reset, ' wrote ', CfgPath);
    WriteLn('Next: ', Ansi.Bold, 'pasclaw agent -m "hello"', Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
