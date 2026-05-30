(*
  PasClaw.Search.Factory - resolves the configured ISearchProvider
  from TConfig + env vars.

  Resolution order:
    1. cfg.WebSearch.Provider explicitly set: use that adapter, fail
       fast if a key is required but missing.
    2. Empty / unset: fall back to DuckDuckGo (no key needed).

  Env overrides win over cfg fields, matching how `pasclaw post` and
  the channel bots read $PASCLAW_* — keeps secrets out of
  config.json for users who'd rather not commit them.

  Wave-1 providers: duckduckgo, brave, tavily.
  Wave 2: searxng, perplexity.
  Wave 3 (deferred): gemini, glm, baidu, sogou.
*)
unit PasClaw.Search.Factory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Search.Types;

function NewSearchProvider(const Cfg: TConfig; out ErrMsg: string): ISearchProvider;

implementation

uses
  PasClaw.Logger,
  PasClaw.Search.DuckDuckGo,
  PasClaw.Search.Brave,
  PasClaw.Search.Tavily;

function PickKey(const FromCfg, EnvName: string): string;
var
  Env: string;
begin
  Env := GetEnvironmentVariable(EnvName);
  if Env <> '' then Result := Env
  else              Result := FromCfg;
end;

function NewSearchProvider(const Cfg: TConfig; out ErrMsg: string): ISearchProvider;
var
  Kind, Key: string;
begin
  ErrMsg := '';
  Kind := LowerCase(Trim(Cfg.WebSearch.Provider));

  if (Kind = '') or (Kind = 'duckduckgo') or (Kind = 'ddg') then
  begin
    Result := NewDuckDuckGoProvider;
    Exit;
  end;

  if Kind = 'brave' then
  begin
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_BRAVE_API_KEY');
    if Key = '' then
    begin
      ErrMsg := 'brave: api key missing (set $PASCLAW_BRAVE_API_KEY)';
      Result := nil;
      Exit;
    end;
    Result := NewBraveProvider(Key);
    Exit;
  end;

  if Kind = 'tavily' then
  begin
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_TAVILY_API_KEY');
    if Key = '' then
    begin
      ErrMsg := 'tavily: api key missing (set $PASCLAW_TAVILY_API_KEY)';
      Result := nil;
      Exit;
    end;
    Result := NewTavilyProvider(Key);
    Exit;
  end;

  LogWarn('search.factory: unknown provider %s — falling back to duckduckgo', [Kind]);
  Result := NewDuckDuckGoProvider;
end;

end.
