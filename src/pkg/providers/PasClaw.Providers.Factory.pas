{
  PasClaw.Providers.Factory - resolves the default provider from config
  and constructs the appropriate ILLMProvider implementation.
  Mirrors pkg/providers/factory.go (light subset).
}
unit PasClaw.Providers.Factory;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Intf;

function NewProviderFromConfig(Cfg: TConfig; const ProviderName: string;
                               out Provider: ILLMProvider; out ErrMsg: string): Boolean;
function NewDefaultProvider(Cfg: TConfig; out Provider: ILLMProvider; out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Providers.Anthropic,
  PasClaw.Providers.OpenAI;

function FindProvider(Cfg: TConfig; const Name: string; out Idx: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Name) then
    begin
      Idx := i;
      Exit(True);
    end;
  Idx := -1;
  Result := False;
end;

function NewProviderFromConfig(Cfg: TConfig; const ProviderName: string;
                               out Provider: ILLMProvider; out ErrMsg: string): Boolean;
var
  Idx: Integer;
  Kind: string;
begin
  Provider := nil;
  ErrMsg := '';
  if not FindProvider(Cfg, ProviderName, Idx) then
  begin
    ErrMsg := 'no provider entry for "' + ProviderName + '" — run `pasclaw onboard` or `pasclaw auth login ' + ProviderName + '`';
    Exit(False);
  end;
  if Cfg.Providers[Idx].APIKey = '' then
  begin
    ErrMsg := 'provider "' + ProviderName + '" has no API key — run `pasclaw auth login ' + ProviderName + '`';
    Exit(False);
  end;
  Kind := LowerCase(Cfg.Providers[Idx].Kind);
  if Kind = '' then Kind := LowerCase(Cfg.Providers[Idx].Name);

  if Kind = 'anthropic' then
    Provider := TAnthropicProvider.Create(
      Cfg.Providers[Idx].APIKey,
      Cfg.Providers[Idx].APIBase,
      Cfg.Providers[Idx].Model)
  else if (Kind = 'openai') or (Kind = 'openai-compat') or (Kind = 'groq') or (Kind = 'together') or (Kind = 'ollama') then
    Provider := TOpenAIProvider.Create(
      Cfg.Providers[Idx].APIKey,
      Cfg.Providers[Idx].APIBase,
      Cfg.Providers[Idx].Model)
  else
  begin
    ErrMsg := 'unsupported provider kind "' + Cfg.Providers[Idx].Kind + '" (supported: anthropic, openai)';
    Exit(False);
  end;
  Result := True;
end;

function NewDefaultProvider(Cfg: TConfig; out Provider: ILLMProvider; out ErrMsg: string): Boolean;
begin
  if Cfg.DefaultProvider = '' then
  begin
    ErrMsg := 'no default provider configured — run `pasclaw onboard`';
    Provider := nil;
    Exit(False);
  end;
  Result := NewProviderFromConfig(Cfg, Cfg.DefaultProvider, Provider, ErrMsg);
end;

end.
