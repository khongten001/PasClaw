(*
  PasClaw.Agent - drop-in TComponent wrappers for embedding PasClaw
  inside other Delphi/FPC applications without shelling out to the CLI.

  Two surfaces on TPasClawAgent:

    Code-driven (one-liner):
      Agent := TPasClawAgent.Create('claude-opus-4-7');
      try
        Agent.RegisterTool(TWebSearchTool.Create);
        Agent.RegisterTool(TFileSystemTool.Create);
        WriteLn(Agent.Run('Summarize the latest Delphi release notes.'));
      finally
        Agent.Free;
      end;

    Form-designer / property-driven (back-compat):
      PC := TPasClawAgent.Create(nil);
      PC.Model := 'claude-opus-4-7';
      PC.UseTools := True;
      if PC.Chat('hi', Reply, Err) then WriteLn(Reply);

  Both styles share the same instance — RegisterTool / Run / Chat /
  ChatHistory / Execute can be mixed freely. Tools registered via
  RegisterTool are added to the same TToolRegistry the built-ins
  populate, so they're visible to the agent loop alongside web_search,
  fs_*, shell, etc.

  TPasClawServer hosts the same HTTP API as `pasclaw serve` inside
  the calling process. Start/Stop manage a background listener
  thread; OnStarted/OnStopped/OnError fire on lifecycle transitions.

  Both compose the same building blocks the CLI uses (LoadConfig,
  NewProviderFromConfig, TToolRegistry, RegisterFSTools/Shell, MCP
  bridge, TGatewayServer, RunToolLoop) — no business logic is
  duplicated, only adapted to TComponent property/event idioms.

  Single-instance contract: PasClaw.MCP.Bridge and PasClaw.Skills.Loader
  hold their state in compile-time fixed module-level arrays, so only
  one live TPasClawAgent and one live TPasClawServer are supported per
  process. Constructing a second instance of either while the first is
  still alive raises EPasClawInstance; freeing the first then creating
  another works. Lifting that restriction is a larger refactor of those
  two units' handler-slot tables.

  Register installs both components onto the `PasClaw` palette tab when
  this unit is included in a design-time package.

  The legacy unit name PasClaw.Component still works — it is a 5-line
  shim that re-exports everything from here, so existing code that
  uses PasClaw.Component compiles unchanged.
*)
unit PasClaw.Agent;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, Contnrs, SyncObjs,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Obj,
  PasClaw.Gateway.Server,
  PasClaw.MCP.Bridge;

type
  EPasClawInstance = class(Exception);
  EPasClawRun      = class(Exception);

  TPasClawTextEvent       = procedure(Sender: TObject; const Text: string) of object;
  TPasClawToolEvent       = procedure(Sender: TObject; const Name, ArgsJSON: string) of object;
  TPasClawToolResultEvent = procedure(Sender: TObject; const Name, ResultText, Err: string) of object;
  TPasClawErrorEvent      = procedure(Sender: TObject; const Msg: string) of object;

  TPasClawAgent = class(TComponent)
  private
    FConfig:         TConfig;
    FProvider:       ILLMProvider;
    FRegistry:       TToolRegistry;
    FMCPClients:     TMCPClientList;
    FOwnedTools:     TObjectList;    { TPasClawTool instances registered via RegisterTool }
    FProviderName:   string;
    FModel:          string;
    FSystemPrompt:   string;
    FMaxIterations:  Integer;
    FUseTools:       Boolean;
    FUseMCP:         Boolean;
    FUseHashline:    Boolean;
    FBuiltinsInstalled: Boolean;  { tracks built-in tool / skill / MCP
                                    install separately from FRegistry's
                                    existence — RegisterTool can create
                                    the registry early without skipping
                                    the lazy built-in install on first
                                    Chat. }
    FOnText:         TPasClawTextEvent;
    FOnToolCall:     TPasClawToolEvent;
    FOnToolResult:   TPasClawToolResultEvent;
    FOnError:        TPasClawErrorEvent;
    procedure EnsureConfig;
    procedure EnsureProvider;
    procedure EnsureRegistry;
    procedure ForwardText      (const S: string);
    procedure ForwardToolCall  (const Name, ArgsJSON: string);
    procedure ForwardToolResult(const Name, ResultText, Err: string);
    procedure RaiseError(const Msg: string);
  public
    constructor Create(AOwner: TComponent); overload; override;
    { Code-driven convenience constructor. Equivalent to
        Create(nil); Self.Model := AModel;
      so the model name is set before EnsureProvider runs. Free as usual. }
    constructor Create(const AModel: string); reintroduce; overload;
    destructor  Destroy; override;

    { Code-driven Run: returns the reply directly, raises EPasClawRun
      on failure. Internally calls Chat() and re-throws the ErrMsg as
      an exception. Use Chat() when you need Boolean+out-param error
      handling without exceptions. }
    function Run(const Prompt: string): string;

    { Code-driven tool registration. Agent takes ownership of ATool
      and frees it in Destroy. Tools registered this way appear in
      the same registry as the built-ins, so they're visible to the
      agent loop on the next Chat/Run call. Safe to call before or
      after the first Chat — the registry is built lazily but
      RegisterTool ensures it exists. }
    procedure RegisterTool(ATool: TPasClawTool);

    function Chat(const Prompt: string; out Reply, ErrMsg: string): Boolean;
    function ChatHistory(const History: array of TMessage;
                         out Reply, ErrMsg: string): Boolean;
    function Execute(const Command: string; const Args: array of string): Integer;
    property Provider: ILLMProvider  read FProvider;
    property Registry: TToolRegistry read FRegistry;
    property Config:   TConfig       read FConfig;
  published
    property ProviderName:  string  read FProviderName  write FProviderName;
    property Model:         string  read FModel         write FModel;
    property SystemPrompt:  string  read FSystemPrompt  write FSystemPrompt;
    property MaxIterations: Integer read FMaxIterations write FMaxIterations default 8;
    property UseTools:      Boolean read FUseTools      write FUseTools      default True;
    property UseMCP:        Boolean read FUseMCP        write FUseMCP        default True;
    property UseHashline:   Boolean read FUseHashline   write FUseHashline   default True;
    property OnText:        TPasClawTextEvent       read FOnText       write FOnText;
    property OnToolCall:    TPasClawToolEvent       read FOnToolCall   write FOnToolCall;
    property OnToolResult:  TPasClawToolResultEvent read FOnToolResult write FOnToolResult;
    property OnError:       TPasClawErrorEvent      read FOnError      write FOnError;
  end;

  TPasClawServer = class(TComponent)
  private
    FConfig:         TConfig;
    FProvider:       ILLMProvider;
    FRegistry:       TToolRegistry;
    FMCPClients:     TMCPClientList;
    FOwnedTools:     TObjectList;     { TPasClawTool instances handed in via RegisterTool }
    FServer:         TGatewayServer;
    FThread:         TThread;
    FStopSignal:     TEvent;          { lives as long as TPasClawServer itself; WaitForStop
                                        waits on this, not on FServer's internal stop flag,
                                        so Stop can safely free FServer while another
                                        thread is unwinding from WaitForStop. }
    FBindAddr:       string;
    FPort:           Integer;
    FMaxIter:        Integer;
    FDebug:          Boolean;
    FEnableTools:    Boolean;
    FEnableMCP:      Boolean;
    FEnableHashline: Boolean;
    FProviderName:   string;
    FModel:          string;
    FOnStarted:      TNotifyEvent;
    FOnStopped:      TNotifyEvent;
    FOnError:        TPasClawErrorEvent;
    FLastError:      string;
    procedure RaiseError(const Msg: string);
  public
    constructor Create(AOwner: TComponent); overload; override;
    { Code-driven convenience constructor. Equivalent to
        Create(nil); BindAddr := AAddr; Port := APort;
      so the listener address and port are set before Start binds. }
    constructor Create(const AAddr: string; APort: Integer); reintroduce; overload;
    destructor  Destroy; override;
    function  Start: Boolean;
    procedure Stop;
    function  IsRunning: Boolean;
    { Block until the server stops accepting connections — either because
      another thread (or signal handler) called Stop, or because the
      listening socket failed mid-run. No-op when IsRunning is False. }
    procedure WaitForStop;
    { Start + WaitForStop in one call. Raises EPasClawRun on startup
      failure (the same message that would appear in LastError);
      otherwise blocks until Stop is signalled, then returns
      normally. Use Start + WaitForStop separately if you need to
      do something between binding the socket and entering the wait. }
    procedure Run;
    { Custom tool registration, mirrors TPasClawAgent.RegisterTool.
      Must be called BEFORE Start — the registry is built once at
      Start time. The server takes ownership of ATool and frees it
      in Destroy. Tools registered this way layer on top of the
      built-ins; name conflicts go to the custom tool. With
      EnableTools := False the server still installs OOP tools the
      caller hands us, so a custom-only registry is achievable. }
    procedure RegisterTool(ATool: TPasClawTool);
    property Server: TGatewayServer read FServer;
    property LastError: string read FLastError;
  published
    property BindAddr:       string  read FBindAddr       write FBindAddr;
    property Port:           Integer read FPort           write FPort           default 8088;
    property MaxIter:        Integer read FMaxIter        write FMaxIter        default 25;
    property Debug:          Boolean read FDebug          write FDebug          default False;
    property EnableTools:    Boolean read FEnableTools    write FEnableTools    default True;
    property EnableMCP:      Boolean read FEnableMCP      write FEnableMCP      default True;
    property EnableHashline: Boolean read FEnableHashline write FEnableHashline default True;
    property ProviderName:   string  read FProviderName   write FProviderName;
    property Model:          string  read FModel          write FModel;
    property OnStarted:      TNotifyEvent       read FOnStarted write FOnStarted;
    property OnStopped:      TNotifyEvent       read FOnStopped write FOnStopped;
    property OnError:        TPasClawErrorEvent read FOnError   write FOnError;
  end;

procedure Register;

implementation

uses
  PasClaw.Cmd.Root,
  PasClaw.Providers.Factory,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.Memory,
  PasClaw.Tools.WebSearch,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.Sandbox,
  PasClaw.Skills.Loader,
  PasClaw.Agent.Prompt,
  PasClaw.Tools.ToolLoop;

var
  { Tracks the live instance of each component class. Set in the
    constructor, cleared in the destructor. A second create attempt
    while one is live raises EPasClawInstance — see unit-header comment
    on the MCP/Skills global-state limitation. }
  GAgentInstance:  TPasClawAgent  = nil;
  GServerInstance: TPasClawServer = nil;

{ ============================== TPasClawAgent ============================== }

constructor TPasClawAgent.Create(AOwner: TComponent);
begin
  if GAgentInstance <> nil then
    raise EPasClawInstance.Create(
      'Only one TPasClawAgent can be live per process — PasClaw.MCP.Bridge ' +
      'and PasClaw.Skills.Loader hold their state in module-level arrays. ' +
      'Free the existing instance before creating another.');
  inherited Create(AOwner);
  FMaxIterations := 8;
  FUseTools      := True;
  FUseMCP        := True;
  FUseHashline   := True;
  FOwnedTools    := TObjectList.Create(True);  { owns + frees its items }
  GAgentInstance := Self;
end;

constructor TPasClawAgent.Create(const AModel: string);
begin
  Create(TComponent(nil));
  FModel := AModel;
end;

destructor TPasClawAgent.Destroy;
begin
  FreeMCPClients(FMCPClients);
  FreeAndNil(FRegistry);
  FProvider := nil;
  FreeAndNil(FConfig);
  FreeAndNil(FOwnedTools);  { frees every TPasClawTool we accepted }
  if GAgentInstance = Self then GAgentInstance := nil;
  inherited Destroy;
end;

procedure TPasClawAgent.EnsureConfig;
begin
  if FConfig = nil then
  begin
    FConfig := LoadConfig;
    { Apply the sandbox policy to the shared module-level state.
      The component sits next to the CLI in one process so this is
      the same global state Cmd.Agent / Cmd.Serve seed at startup. }
    ConfigureSandbox(FConfig.Sandbox, '');
  end;
end;

procedure TPasClawAgent.EnsureProvider;
var
  Name, Err: string;
begin
  if FProvider <> nil then Exit;
  EnsureConfig;
  if FProviderName <> '' then Name := FProviderName else Name := FConfig.DefaultProvider;
  if Name = '' then
  begin
    RaiseError('no provider configured (run `pasclaw onboard` or set ProviderName)');
    Exit;
  end;
  if not NewProviderFromConfig(FConfig, Name, FProvider, Err) then
  begin
    FProvider := nil;
    RaiseError('provider unavailable: ' + Err);
  end;
end;

procedure TPasClawAgent.EnsureRegistry;
var
  Skills: TSkillSpecArray;
  i: Integer;
begin
  { Track the built-in install with its own flag, NOT with
    `FRegistry <> nil` — RegisterTool can create FRegistry early
    (before the first Chat) to hold user-supplied OOP tools, and
    we still need to lazily layer the built-ins, skills, and MCP
    servers on first Chat in that case. }
  if FBuiltinsInstalled then Exit;
  if not FUseTools then Exit;
  EnsureConfig;
  if FRegistry = nil then
    FRegistry := TToolRegistry.Create;
  RegisterFSTools(FRegistry, FUseHashline);
  RegisterShellTool(FRegistry);
  RegisterMemoryTools(FRegistry);
  RegisterWebSearchTool(FRegistry);
  RegisterWebFetchTool(FRegistry);
  Skills := LoadSkillManifests(GetHome);
  RegisterSkills(FRegistry, Skills);
  if FUseMCP then
    FMCPClients := ConnectMCPServers(FConfig, FRegistry);
  FBuiltinsInstalled := True;
  { Re-install OOP tools that were registered before this point so
    user names override the built-ins on conflict. TToolRegistry.
    Register replaces same-named entries, so re-installing in
    FOwnedTools order puts the user tools on top. Tools registered
    AFTER this call go straight to FRegistry via RegisterTool below
    and skip this re-pass. }
  for i := 0 to FOwnedTools.Count - 1 do
    TPasClawTool(FOwnedTools[i]).Install(FRegistry);
end;

procedure TPasClawAgent.RegisterTool(ATool: TPasClawTool);
begin
  if ATool = nil then Exit;
  { RegisterTool can run at any point in the lifecycle:

    * Before the first Chat — FRegistry may not exist yet; create
      a bare one and install into it. EnsureRegistry will layer
      the built-ins on first Chat, then re-install every entry in
      FOwnedTools so user overrides win.

    * After the first Chat — built-ins are already in FRegistry;
      install on top so the new tool is visible immediately.

    * With FUseTools := False — EnsureRegistry will skip the
      built-ins entirely; this RegisterTool call still creates
      the registry, populated only with OOP tools the caller
      hands us. }
  EnsureConfig;
  if FRegistry = nil then
    FRegistry := TToolRegistry.Create;
  FOwnedTools.Add(ATool);
  ATool.Install(FRegistry);
end;

procedure TPasClawAgent.ForwardText(const S: string);
begin
  if Assigned(FOnText) then FOnText(Self, S);
end;

procedure TPasClawAgent.ForwardToolCall(const Name, ArgsJSON: string);
begin
  if Assigned(FOnToolCall) then FOnToolCall(Self, Name, ArgsJSON);
end;

procedure TPasClawAgent.ForwardToolResult(const Name, ResultText, Err: string);
begin
  if Assigned(FOnToolResult) then FOnToolResult(Self, Name, ResultText, Err);
end;

procedure TPasClawAgent.RaiseError(const Msg: string);
begin
  if Assigned(FOnError) then FOnError(Self, Msg);
end;

function TPasClawAgent.Run(const Prompt: string): string;
var
  Reply, Err: string;
begin
  if not Chat(Prompt, Reply, Err) then
    raise EPasClawRun.Create(Err);
  Result := Reply;
end;

function TPasClawAgent.Chat(const Prompt: string; out Reply, ErrMsg: string): Boolean;
var
  Msgs: array of TMessage;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Prompt);
  Result := ChatHistory(Msgs, Reply, ErrMsg);
end;

function TPasClawAgent.ChatHistory(const History: array of TMessage;
                                    out Reply, ErrMsg: string): Boolean;
var
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
  i: Integer;
  ModelName: string;
begin
  Reply  := '';
  ErrMsg := '';
  EnsureConfig;
  EnsureProvider;
  if FProvider = nil then
  begin
    ErrMsg := 'provider unavailable';
    Result := False;
    Exit;
  end;
  EnsureRegistry;

  SetLength(Msgs, Length(History));
  for i := 0 to High(History) do Msgs[i] := History[i];

  if FModel <> '' then ModelName := FModel else ModelName := FConfig.DefaultModel;

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := ModelName;
  Cfg.MaxIterations := FMaxIterations;
  Cfg.Options       := DefaultChatOptions;
  { Derive ToolsEnabled from the registry we are about to hand to
    RunToolLoop, NOT from FUseTools. EnsureRegistry caches FRegistry
    across calls and only checks FUseTools when the registry is
    nil — so a component used with UseTools=True, then flipped to
    UseTools=False, would otherwise send the model a "No tools in
    this session" prompt while RunToolLoop still received the cached
    registry. The single source of truth is Cfg.Registry. }
  Cfg.Options.SystemPrompt := BuildSystemPrompt(FConfig, FSystemPrompt,
                                                Cfg.Registry <> nil);
  Cfg.OnText        := ForwardText;
  Cfg.OnToolCall    := ForwardToolCall;
  Cfg.OnToolResult  := ForwardToolResult;

  try
    Result := RunToolLoop(Cfg, Msgs, Loop);
    if Result then
      Reply := Loop.Content
    else
      ErrMsg := 'tool loop failed';
  except
    on E: Exception do
    begin
      Result := False;
      ErrMsg := E.ClassName + ': ' + E.Message;
      RaiseError(ErrMsg);
    end;
  end;
end;

function TPasClawAgent.Execute(const Command: string;
                                const Args: array of string): Integer;
begin
  Result := DispatchCommand(Command, Args);
end;

{ ============================== TPasClawServer ============================= }

type
  TServerWorker = class(TThread)
  private
    FServer: TGatewayServer;
    FAddr:   string;
    FPort:   Integer;
    FErr:    string;
    FStartupDone: TEvent;
    FStartupOK:   Boolean;
    FStartupErr:  string;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TGatewayServer; const AAddr: string; APort: Integer);
    destructor Destroy; override;
    function WaitForStartup(TimeoutMS: Cardinal): Boolean;
    property StartupOK: Boolean read FStartupOK;
    property StartupErr: string read FStartupErr;
    property Err: string read FErr;
  end;

constructor TServerWorker.Create(AServer: TGatewayServer; const AAddr: string; APort: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
  FAddr   := AAddr;
  FPort   := APort;
  FStartupDone := TEvent.Create(nil, True, False, '');
  FStartupOK   := False;
  FStartupErr  := '';
end;

destructor TServerWorker.Destroy;
begin
  FreeAndNil(FStartupDone);
  inherited Destroy;
end;

function TServerWorker.WaitForStartup(TimeoutMS: Cardinal): Boolean;
begin
  Result := FStartupDone.WaitFor(TimeoutMS) = wrSignaled;
end;

procedure TServerWorker.Execute;
begin
  try
    FServer.Start(FAddr, FPort);
    FStartupOK := True;
    FStartupDone.SetEvent;
    FServer.WaitForStop;
  except
    on E: Exception do
    begin
      FErr := E.ClassName + ': ' + E.Message;
      FStartupErr := FErr;
      FStartupOK := False;
      FStartupDone.SetEvent;
    end;
  end;
end;

constructor TPasClawServer.Create(AOwner: TComponent);
begin
  if GServerInstance <> nil then
    raise EPasClawInstance.Create(
      'Only one TPasClawServer can be live per process — PasClaw.MCP.Bridge ' +
      'and PasClaw.Skills.Loader hold their state in module-level arrays. ' +
      'Free the existing instance before creating another.');
  inherited Create(AOwner);
  FBindAddr       := '127.0.0.1';
  FPort           := 8088;
  FMaxIter        := 25;
  FEnableTools    := True;
  FEnableMCP      := True;
  FEnableHashline := True;
  FOwnedTools     := TObjectList.Create(True);  { owns + frees its items }
  FStopSignal     := TEvent.Create(nil, True, False, '');  { manual reset, non-signalled }
  GServerInstance := Self;
end;

constructor TPasClawServer.Create(const AAddr: string; APort: Integer);
begin
  Create(TComponent(nil));
  FBindAddr := AAddr;
  FPort     := APort;
end;

destructor TPasClawServer.Destroy;
begin
  Stop;
  { Stop signals FStopSignal and tears down FServer/FThread. By the
    time we get here, any thread that was inside WaitForStop has
    already returned, so freeing FStopSignal is race-free. }
  FreeAndNil(FStopSignal);
  FreeAndNil(FOwnedTools);  { frees every TPasClawTool we accepted }
  if GServerInstance = Self then GServerInstance := nil;
  inherited Destroy;
end;

function TPasClawServer.Start: Boolean;
var
  Skills: TSkillSpecArray;
  Err: string;
  StartupMsg: string;
  i: Integer;
const
  STARTUP_TIMEOUT_MS = 5000;
begin
  if IsRunning then Exit(True);
  { Defensive: if a prior Start failed mid-bind (or the thread exited on
    its own), Stop joins the dead thread and clears stale state. Cheap
    no-op when nothing is left over. }
  if (FThread <> nil) or (FServer <> nil) then Stop;

  { Re-arm the stop signal for this run. Stop's last action is to
    SetEvent; a fresh Start needs to clear it so WaitForStop blocks
    again instead of returning immediately. }
  if FStopSignal <> nil then FStopSignal.ResetEvent;

  FConfig := LoadConfig;
  ConfigureSandbox(FConfig.Sandbox, '');
  if FModel <> '' then
    FConfig.DefaultModel := FModel;

  FProvider := nil;
  if (FProviderName <> '') or (FConfig.DefaultProvider <> '') then
  begin
    if FProviderName <> '' then
    begin
      if not NewProviderFromConfig(FConfig, FProviderName, FProvider, Err) then
        RaiseError('provider unavailable: ' + Err);
    end
    else if not NewDefaultProvider(FConfig, FProvider, Err) then
      RaiseError('provider unavailable: ' + Err);
  end;

  FRegistry := nil;
  if FEnableTools then
  begin
    FRegistry := TToolRegistry.Create;
    RegisterFSTools(FRegistry, FEnableHashline);
    RegisterShellTool(FRegistry);
    RegisterMemoryTools(FRegistry);
    RegisterWebSearchTool(FRegistry);
    RegisterWebFetchTool(FRegistry);
    Skills := LoadSkillManifests(GetHome);
    RegisterSkills(FRegistry, Skills);
  end;

  SetLength(FMCPClients, 0);
  if FEnableMCP and (FRegistry <> nil) then
    FMCPClients := ConnectMCPServers(FConfig, FRegistry);

  { Install OOP tools handed in via RegisterTool. Goes AFTER the
    built-ins and MCP so user names override on conflict — same
    semantic as TPasClawAgent.EnsureRegistry. When EnableTools is
    False but the caller registered custom tools, create a bare
    registry just for them. }
  if (FOwnedTools.Count > 0) and (FRegistry = nil) then
    FRegistry := TToolRegistry.Create;
  for i := 0 to FOwnedTools.Count - 1 do
    TPasClawTool(FOwnedTools[i]).Install(FRegistry);

  FServer := TGatewayServer.Create(FConfig, FProvider, FRegistry);
  FServer.DebugIO := FDebug;
  FServer.MaxIter := FMaxIter;

  FLastError := '';
  FThread := TServerWorker.Create(FServer, FBindAddr, FPort);
  TServerWorker(FThread).Start;

  if not TServerWorker(FThread).WaitForStartup(STARTUP_TIMEOUT_MS) then
  begin
    StartupMsg := Format('server startup timed out after %d ms', [STARTUP_TIMEOUT_MS]);
    FLastError := StartupMsg;
    RaiseError(StartupMsg);
    Stop;
    Exit(False);
  end;

  if not TServerWorker(FThread).StartupOK then
  begin
    StartupMsg := TServerWorker(FThread).StartupErr;
    if StartupMsg = '' then StartupMsg := 'server startup failed';
    FLastError := StartupMsg;
    RaiseError(StartupMsg);
    Stop;
    Exit(False);
  end;

  Result := True;
  if Assigned(FOnStarted) then FOnStarted(Self);
end;

procedure TPasClawServer.Stop;
begin
  { Wake WaitForStop callers FIRST so they can return all the way
    out of their stack frames before we tear down FServer below.
    The Run path's WaitForStop is parked on FStopSignal, which
    lives on Self (not on FServer), so signalling here gives any
    waiter a clean exit. }
  if FStopSignal <> nil then FStopSignal.SetEvent;
  if FServer <> nil then FServer.Stop;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FreeAndNil(FServer);
  FreeMCPClients(FMCPClients);
  FreeAndNil(FRegistry);
  FProvider := nil;
  FreeAndNil(FConfig);
  if Assigned(FOnStopped) then FOnStopped(Self);
end;

function TPasClawServer.IsRunning: Boolean;
begin
  Result := (FThread <> nil) and (not FThread.Finished);
end;

procedure TPasClawServer.RaiseError(const Msg: string);
begin
  if Assigned(FOnError) then FOnError(Self, Msg);
end;

procedure TPasClawServer.WaitForStop;
begin
  { Wait on the TPasClawServer-owned signal, NOT on FServer's
    internal stop flag — FServer can be freed in Stop while we're
    still mid-return from WaitFor, which Codex flagged as a P1 on
    the original draft. FStopSignal's lifetime is tied to Self, so
    the only way Stop can free it is via Destroy (which is the
    caller's responsibility to gate on Run/WaitForStop returning
    first). FStopSignal is created in the constructor and is nil
    only after Destroy, so guard for that. }
  if FStopSignal = nil then Exit;
  FStopSignal.WaitFor(INFINITE);
end;

procedure TPasClawServer.Run;
begin
  if not Start then
    raise EPasClawRun.Create(FLastError);
  WaitForStop;
end;

procedure TPasClawServer.RegisterTool(ATool: TPasClawTool);
begin
  if ATool = nil then Exit;
  { Registry doesn't exist yet — Start hasn't been called. Park the
    tool in FOwnedTools; Start's tail loop installs every entry on
    top of the built-ins so name overrides win. Safe to call any
    time before Start; calling after Start is technically allowed
    (the tool gets installed directly into the live registry) but
    the worker thread is already serving requests so callers should
    prefer to Stop, RegisterTool, Start if they want defined timing. }
  FOwnedTools.Add(ATool);
  if FRegistry <> nil then
    ATool.Install(FRegistry);
end;

{ ============================== Registration ============================== }

procedure Register;
begin
  RegisterComponents('PasClaw', [TPasClawAgent, TPasClawServer]);
end;

end.
