(*
  SampleServer — minimal code-driven embedding of TPasClawServer.

  Hosts the same OpenAI-compatible HTTP API as `pasclaw serve` inside
  a standalone Delphi / FPC binary. Mirrors SampleSimple.dpr's style:
  pass the listen address straight to Create, register OOP tools as
  class instances, and let Run() do Start + WaitForStop in one call.

      Server := TPasClawServer.Create('0.0.0.0', 8088);
      try
        Server.RegisterTool(TWebSearchTool.Create);
        Server.Run;  // blocks until Stop() is called from another thread
      finally
        Server.Free;
      end;

  Ctrl-C handling is the embedder's problem — a console-mode SIGINT
  goes straight to the process. If you want clean shutdown on Ctrl-C
  install a TConsoleCtrlHandler / SignalHandler that calls
  Server.Stop from its callback. We deliberately don't install one
  in the component because most hosting apps already have their own
  signal-handling strategy and don't want a library to fight them
  for it.

  Build (FPC):
    cd samples/component-console
    make server

  Build (Delphi):
    cd samples/component-console
    msbuild SampleServer.dproj    # or open SampleServer.dproj in RAD Studio
    dcc32 SampleServer.dpr        # cmdline only — dcc32.cfg in this dir
                                  # carries the search paths

  Runtime:
    export ANTHROPIC_API_KEY=sk-ant-...
    ./build/SampleServer

  Then test from another shell:

    curl http://localhost:8088/v1/chat/completions \
      -H 'content-type: application/json' \
      -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hi"}]}'

  SetProvider is configured in code below — no ~/.pasclaw/config.json
  or `pasclaw onboard` required. Swap to "openai" / "gemini" / "groq"
  / "ollama" via the Kind argument; see PasClaw.Providers.Catalog
  for the full list.
*)
program SampleServer;

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF FPC}{$IFDEF UNIX}
  cthreads,  { TPasClawServer spawns a worker thread that creates a
               SyncObjs.TEvent; without cthreads the event Create
               raises ESyncObjectException on Linux. Mirrors what
               PasClaw.dpr does for the main binary. }
  {$ENDIF}{$ENDIF}
  SysUtils,
  PasClaw.Agent,
  PasClaw.Tools;

var
  Server: TPasClawServer;
  ApiKey: string;
begin
  ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
  if ApiKey = '' then
  begin
    WriteLn('ANTHROPIC_API_KEY not set — export it and re-run.');
    Halt(2);
  end;

  Server := TPasClawServer.Create('0.0.0.0', 8088);
  try
    Server.SetProvider('anthropic', ApiKey);
    Server.RegisterTool(TWebSearchTool.Create);
    Server.RegisterTool(TWebFetchTool.Create);
    Server.RegisterTool(TFileSystemTool.Create);
    WriteLn('listening on http://', Server.BindAddr, ':', Server.Port);
    WriteLn('press Ctrl-C to stop');
    try
      Server.Run;  { blocks until Stop is signalled from elsewhere }
    except
      on E: EPasClawRun do
        WriteLn('startup failed: ', E.Message);
    end;
  finally
    Server.Free;
  end;
end.
