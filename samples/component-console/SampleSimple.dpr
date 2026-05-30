(*
  SampleSimple — minimal code-driven embedding of PasClaw.

  Pairs with SampleConsole.dpr (which shows the legacy
  property-driven API). This file shows the code-friendly API:

    1. Pass the model name directly to Create.
    2. Register tools as class instances rather than as records
       full of function pointers.
    3. Call Run(prompt): string and let it raise EPasClawRun on
       failure instead of unpacking a Boolean + out-parameter.

  Build (FPC):
    cd samples/component-console
    make simple

  Build (Delphi):
    cd samples/component-console
    msbuild SampleSimple.dproj    # or open SampleSimple.dproj in RAD Studio
    dcc32 SampleSimple.dpr        # cmdline only — dcc32.cfg in this dir
                                  # carries the search paths

  Runtime: the agent inherits config from ~/.pasclaw/config.json,
  so run `pasclaw onboard` and `pasclaw auth login <provider>` once
  first. PASCLAW_AUTH_PROVIDER / PASCLAW_AUTH_TOKEN env vars also
  work if you'd rather not write to disk.
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
begin
  Agent := TPasClawAgent.Create('claude-opus-4-7');
  try
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
