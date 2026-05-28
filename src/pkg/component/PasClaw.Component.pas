(*
  PasClaw.Component - drop-in TComponent wrappers for embedding PasClaw
  inside other Delphi/FPC applications without shelling out to the CLI.

    TPasClawAgent  - chat/agent surface: Chat(), ChatHistory(), and a
                     pass-through Execute(cmd, args) that mirrors every
                     `pasclaw <cmd>` subcommand. OnText/OnToolCall/
                     OnToolResult/OnError events surface activity.
    TPasClawServer - hosts the same HTTP API as `pasclaw serve` inside
                     the calling process. Start/Stop manage a background
                     listener thread; OnStarted/OnStopped/OnError fire on
                     lifecycle transitions.

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
*)
unit PasClaw.Component;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Registry,
  PasClaw.Gateway.Server,
  PasClaw.MCP.Bridge;

type
  EPasClawInstance = class(Exception);

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
    FProviderName:   string;
    FModel:          string;
    FSystemPrompt:   string;
    FMaxIterations:  Integer;
    FUseTools:       Boolean;
    FUseMCP:         Boolean;
    FUseHashline:    Boolean;
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
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
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
    FServer:         TGatewayServer;
    FThread:         TThread;
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
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    function  Start: Boolean;
    procedure Stop;
    function  IsRunning: Boolean;
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
  GAgentInstance := Self;
end;

destructor TPasClawAgent.Destroy;
begin
  FreeMCPClients(FMCPClients);
  FreeAndNil(FRegistry);
  FProvider := nil;
  FreeAndNil(FConfig);
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
begin
  if FRegistry <> nil then Exit;
  if not FUseTools then Exit;
  EnsureConfig;
  FRegistry := TToolRegistry.Create;
  RegisterFSTools(FRegistry, FUseHashline);
  RegisterShellTool(FRegistry);
  Skills := LoadSkillManifests(GetHome);
  RegisterSkills(FRegistry, Skills);
  if FUseMCP then
    FMCPClients := ConnectMCPServers(FConfig, FRegistry);
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
  Cfg.Options.SystemPrompt := BuildSystemPrompt(FConfig, FSystemPrompt);
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
  GServerInstance := Self;
end;

destructor TPasClawServer.Destroy;
begin
  Stop;
  if GServerInstance = Self then GServerInstance := nil;
  inherited Destroy;
end;

function TPasClawServer.Start: Boolean;
var
  Skills: TSkillSpecArray;
  Err: string;
  StartupMsg: string;
const
  STARTUP_TIMEOUT_MS = 5000;
begin
  if IsRunning then Exit(True);
  { Defensive: if a prior Start failed mid-bind (or the thread exited on
    its own), Stop joins the dead thread and clears stale state. Cheap
    no-op when nothing is left over. }
  if (FThread <> nil) or (FServer <> nil) then Stop;

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
    Skills := LoadSkillManifests(GetHome);
    RegisterSkills(FRegistry, Skills);
  end;

  SetLength(FMCPClients, 0);
  if FEnableMCP and (FRegistry <> nil) then
    FMCPClients := ConnectMCPServers(FConfig, FRegistry);

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

{ ============================== Registration ============================== }

procedure Register;
begin
  RegisterComponents('PasClaw', [TPasClawAgent, TPasClawServer]);
end;

end.
