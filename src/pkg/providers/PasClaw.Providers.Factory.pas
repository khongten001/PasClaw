{
  PasClaw.Providers.Factory - resolves the default provider from config
  and constructs the appropriate ILLMProvider implementation.
  Mirrors pkg/providers/factory.go (light subset).
}
unit PasClaw.Providers.Factory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Intf;

{ TLLMProviderArray moved to PasClaw.Providers.Intf so both this unit
  and PasClaw.Tools.ToolLoop reference the same named type — dcc64
  rejects cross-unit assignments between inline `array of ILLMProvider`
  declarations even when structurally identical. }

function NewProviderFromConfig(Cfg: TConfig; const ProviderName: string;
                               out Provider: ILLMProvider; out ErrMsg: string): Boolean;
function NewDefaultProvider(Cfg: TConfig; out Provider: ILLMProvider; out ErrMsg: string): Boolean;

(* Resolve TConfig.Fallbacks into a runtime array of ILLMProvider, ready
   to drop into TToolLoopConfig.Fallbacks. Each Name in Cfg.Fallbacks
   is looked up via NewProviderFromConfig; unresolvable names are
   silently skipped (a logged warning is the only feedback) so a typo
   in config.json doesn't break the loop. Returns an empty array when
   Cfg.Fallbacks is empty. *)
function ResolveFallbacks(Cfg: TConfig): TLLMProviderArray;

implementation

uses
  PasClaw.Logger,
  PasClaw.Providers.Anthropic,
  PasClaw.Providers.OpenAI,
  PasClaw.Providers.Gemini,
  PasClaw.Providers.Catalog;

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

function FirstNonEmpty(const A, B: string): string; inline;
begin
  if A <> '' then Result := A else Result := B;
end;

function NormalizeProviderKind(const Kind: string): string;
begin
  Result := LowerCase(Trim(Kind));
  if Result = 'openai-compat' then
    Result := 'openai';
end;

function NewProviderFromConfig(Cfg: TConfig; const ProviderName: string;
                               out Provider: ILLMProvider; out ErrMsg: string): Boolean;
var
  Idx: Integer;
  Kind: string;
  Spec: TProviderSpec;
  Base, Model, APIKey: string;
  RequiresKey: Boolean;
  ServerTools: TAnthropicServerTools;
  OAIServerTools: TOpenAIServerTools;
begin
  Provider := nil;
  ErrMsg := '';
  if not FindProvider(Cfg, ProviderName, Idx) then
  begin
    ErrMsg := 'no provider entry for "' + ProviderName + '" — run `pasclaw onboard` or `pasclaw auth login ' + ProviderName + '`';
    Exit(False);
  end;
  Kind := NormalizeProviderKind(Cfg.Providers[Idx].Kind);
  if Kind = '' then Kind := NormalizeProviderKind(Cfg.Providers[Idx].Name);

  if not LookupProvider(Kind, Spec) then
  begin
    ErrMsg := 'unsupported provider kind "' + Cfg.Providers[Idx].Kind +
              '" — see `pasclaw onboard` or pkg/providers/PasClaw.Providers.Catalog.pas';
    Exit(False);
  end;

  APIKey := Cfg.Providers[Idx].APIKey;
  RequiresKey := Spec.Auth.Kind <> asNone;
  if RequiresKey and (APIKey = '') then
  begin
    ErrMsg := 'provider "' + ProviderName + '" has no API key — run `pasclaw auth login ' + ProviderName + '`';
    Exit(False);
  end;

  { Effective base / model fall back to the catalog's defaults when the
    config entry left them blank. Lets a freshly-onboarded provider work
    immediately with no extra fields to fill in. }
  Base  := FirstNonEmpty(Cfg.Providers[Idx].APIBase, Spec.DefaultBase);
  Model := FirstNonEmpty(Cfg.Providers[Idx].Model,   Spec.DefaultModel);

  case Spec.Family of
    pfAnthropic:
      begin
        { Translate the operator's Anthropic server-tool toggles into
          the provider's local record. Picked up in BuildRequest. }
        ServerTools.WebSearch        := Cfg.AnthropicServerTools.WebSearch;
        ServerTools.WebSearchMaxUses := Cfg.AnthropicServerTools.WebSearchMaxUses;
        ServerTools.WebFetch         := Cfg.AnthropicServerTools.WebFetch;
        ServerTools.WebFetchMaxUses  := Cfg.AnthropicServerTools.WebFetchMaxUses;
        Provider := TAnthropicProvider.Create(APIKey, Base, Model, ServerTools);
      end;
    pfOpenAI:
      begin
        OAIServerTools.WebSearch := Cfg.OpenAIServerTools.WebSearch;
        Provider := TOpenAIProvider.Create(APIKey, Base, Model, Kind, Spec.Auth,
                                            OAIServerTools);
      end;
    pfGemini:
      Provider := TGeminiProvider.Create(APIKey, Base, Model);
    pfPlaceholder:
      begin
        ErrMsg := 'provider "' + Spec.DisplayName + '" is in the catalog but ' +
                  'its protocol implementation is not yet bundled in this build';
        Exit(False);
      end;
  else
    ErrMsg := 'provider "' + Spec.DisplayName + '" has no protocol family wired up';
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

function ResolveFallbacks(Cfg: TConfig): TLLMProviderArray;
var
  i, Out_: Integer;
  P: ILLMProvider;
  Err: string;
begin
  SetLength(Result, Length(Cfg.Fallbacks));
  Out_ := 0;
  for i := 0 to High(Cfg.Fallbacks) do
  begin
    if Cfg.Fallbacks[i] = '' then Continue;
    if not NewProviderFromConfig(Cfg, Cfg.Fallbacks[i], P, Err) then
    begin
      { Don't propagate — let the caller still build the loop with
        the providers that did resolve. The fallback chain is
        defensive; missing an entry only weakens it, never breaks
        the primary path. }
      LogWarn('fallback provider %s unresolvable: %s', [Cfg.Fallbacks[i], Err]);
      Continue;
    end;
    Result[Out_] := P;
    Inc(Out_);
  end;
  SetLength(Result, Out_);
end;

end.
