(*
  SampleSimple — minimal code-driven embedding of PasClaw.

  Pairs with SampleConsole.dpr (which shows the legacy
  property-driven API). This file shows the code-friendly API:

    1. Pass the model name directly to Create.
    2. Configure the provider in code with SetProvider — no
       ~/.pasclaw/config.json or `pasclaw onboard` required.
       The API key is read from an env var so the binary doesn't
       carry secrets.
    3. Register tools as class instances rather than as records
       full of function pointers.
    4. Call Run(prompt): string and let it raise EPasClawRun on
       failure instead of unpacking a Boolean + out-parameter.

  Build (FPC):
    cd samples/component-console
    make simple

  Build (Delphi):
    cd samples/component-console
    msbuild SampleSimple.dproj    # or open SampleSimple.dproj in RAD Studio
    dcc32 SampleSimple.dpr        # cmdline only — dcc32.cfg in this dir
                                  # carries the search paths

  Runtime:
    export ANTHROPIC_API_KEY=sk-ant-...
    ./build/SampleSimple

  Switch providers by changing the SetProvider() Kind argument —
  "openai", "gemini", "groq", "ollama" are all in
  PasClaw.Providers.Catalog. Each has its own default base URL and
  expected env var name; the catalog one-liner below covers the
  Anthropic case end-to-end. If ~/.pasclaw/config.json IS present,
  the SetProvider call overrides whatever provider entry it had
  for "anthropic".
*)
program SampleSimple;

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Agent,
  PasClaw.Tools;

var
  Agent: TPasClawAgent;
  ApiKey: string;
begin
  ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
  if ApiKey = '' then
  begin
    WriteLn('ANTHROPIC_API_KEY not set — export it and re-run.');
    Halt(2);
  end;

  Agent := TPasClawAgent.Create('claude-opus-4-7');
  try
    Agent.SetProvider('anthropic', ApiKey);
    Agent.RegisterTool(TWebSearchTool.Create);
    Agent.RegisterTool(TWebFetchTool.Create);
    Agent.RegisterTool(TFileSystemTool.Create);
    try
      WriteLn(Agent.Run('Summarize the latest Delphi release notes in three bullets.'));
    except
      on E: EPasClawRun do
        WriteLn('agent error: ', E.Message);
    end;
  finally
    Agent.Free;
  end;
end.
