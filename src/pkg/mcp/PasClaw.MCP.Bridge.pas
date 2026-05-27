{
  PasClaw.MCP.Bridge - registers MCP tools into the PasClaw tools registry
  so the agent loop can invoke them transparently. Tools are namespaced as
  "<server>__<tool>" to avoid clashes with built-ins or between servers.
}
unit PasClaw.MCP.Bridge;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.MCP.Types,
  PasClaw.MCP.StdioClient,
  PasClaw.MCP.HttpClient;

type
  TMCPClientList = array of TMCPBaseClient;

{ Connect every enabled MCP server from the config and register their tools
  into Reg. Returns the list of live clients (caller frees with FreeMCPClients
  after the agent loop exits). }
function ConnectMCPServers(Cfg: TConfig; Reg: TToolRegistry): TMCPClientList;
procedure FreeMCPClients(var Clients: TMCPClientList);

implementation

uses
  PasClaw.Logger;

type
  { Each handler needs to remember which client + tool to dispatch to.
    We keep a small global slot table because TToolHandler is a plain
    procedural type (no closure context). 32 slots is well above any
    reasonable MCP-server-count for a single-user CLI. }
  TMCPBinding = record
    Client:   TMCPBaseClient;
    ToolName: string;
    InUse:    Boolean;
  end;

const
  MaxBindings = 32;

var
  GBindings: array[0..MaxBindings - 1] of TMCPBinding;

function FindBinding(const RegisteredName: string; out Idx: Integer): Boolean; forward;

{ Per-slot handlers. We can't generate these dynamically in Pascal, so we
  hand-roll one per slot and use the slot index to look up the binding.
  The macro template below is FPC-only and documentary — Delphi ignores it. }
{$IFDEF FPC}
{$MACRO ON}
{$DEFINE MAKE_HANDLER :=
function H_NUM(const ArgsJSON: string; out ErrMsg: string): string;
var
  Idx: Integer;
  Done: Boolean;
begin
  ErrMsg := '';
  Idx := NUM;
  if not GBindings[Idx].InUse then
  begin
    ErrMsg := 'mcp slot stale';
    Exit('');
  end;
  Done := GBindings[Idx].Client.CallTool(GBindings[Idx].ToolName, ArgsJSON, Result, ErrMsg);
  if not Done and (ErrMsg = '') then ErrMsg := 'mcp call failed';
end;
}
{$ENDIF}

{ Slot handlers: we emit one per index so the function table is fixed at
  compile time. If you raise MaxBindings, extend this block to match. }
function H_0(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[0 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[0 ].Client.CallTool(GBindings[0 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_1(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[1 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[1 ].Client.CallTool(GBindings[1 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_2(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[2 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[2 ].Client.CallTool(GBindings[2 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_3(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[3 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[3 ].Client.CallTool(GBindings[3 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_4(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[4 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[4 ].Client.CallTool(GBindings[4 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_5(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[5 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[5 ].Client.CallTool(GBindings[5 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_6(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[6 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[6 ].Client.CallTool(GBindings[6 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_7(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[7 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[7 ].Client.CallTool(GBindings[7 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_8(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[8 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[8 ].Client.CallTool(GBindings[8 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_9(const A: string; out E: string): string;  var D: Boolean; begin E:=''; if not GBindings[9 ].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[9 ].Client.CallTool(GBindings[9 ].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_10(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[10].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[10].Client.CallTool(GBindings[10].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_11(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[11].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[11].Client.CallTool(GBindings[11].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_12(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[12].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[12].Client.CallTool(GBindings[12].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_13(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[13].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[13].Client.CallTool(GBindings[13].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_14(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[14].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[14].Client.CallTool(GBindings[14].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_15(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[15].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[15].Client.CallTool(GBindings[15].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_16(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[16].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[16].Client.CallTool(GBindings[16].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_17(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[17].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[17].Client.CallTool(GBindings[17].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_18(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[18].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[18].Client.CallTool(GBindings[18].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_19(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[19].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[19].Client.CallTool(GBindings[19].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_20(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[20].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[20].Client.CallTool(GBindings[20].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_21(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[21].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[21].Client.CallTool(GBindings[21].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_22(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[22].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[22].Client.CallTool(GBindings[22].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_23(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[23].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[23].Client.CallTool(GBindings[23].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_24(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[24].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[24].Client.CallTool(GBindings[24].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_25(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[25].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[25].Client.CallTool(GBindings[25].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_26(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[26].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[26].Client.CallTool(GBindings[26].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_27(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[27].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[27].Client.CallTool(GBindings[27].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_28(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[28].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[28].Client.CallTool(GBindings[28].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_29(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[29].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[29].Client.CallTool(GBindings[29].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_30(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[30].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[30].Client.CallTool(GBindings[30].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;
function H_31(const A: string; out E: string): string; var D: Boolean; begin E:=''; if not GBindings[31].InUse then begin E:='stale';Result:='';Exit;end; D:=GBindings[31].Client.CallTool(GBindings[31].ToolName,A,Result,E); if not D and (E='') then E:='mcp call failed'; end;

const
  Handlers: array[0..MaxBindings - 1] of TToolHandler = (
    @H_0,  @H_1,  @H_2,  @H_3,  @H_4,  @H_5,  @H_6,  @H_7,
    @H_8,  @H_9,  @H_10, @H_11, @H_12, @H_13, @H_14, @H_15,
    @H_16, @H_17, @H_18, @H_19, @H_20, @H_21, @H_22, @H_23,
    @H_24, @H_25, @H_26, @H_27, @H_28, @H_29, @H_30, @H_31
  );

function FindBinding(const RegisteredName: string; out Idx: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(GBindings) do
    if GBindings[i].InUse and (GBindings[i].ToolName = RegisteredName) then
    begin
      Idx := i;
      Exit(True);
    end;
end;

function AllocateSlot: Integer;
var
  i: Integer;
begin
  for i := 0 to High(GBindings) do
    if not GBindings[i].InUse then Exit(i);
  Result := -1;
end;

function IsHttpUrl(const S: string): Boolean;
begin
  Result := (Length(S) >= 7) and
            ((LowerCase(Copy(S, 1, 7)) = 'http://') or
             ((Length(S) >= 8) and (LowerCase(Copy(S, 1, 8)) = 'https://')));
end;

function ConnectMCPServers(Cfg: TConfig; Reg: TToolRegistry): TMCPClientList;
var
  i, j, slot: Integer;
  Client: TMCPBaseClient;
  Tools: TMCPToolArray;
  Err: string;
  ToolEntry: TTool;
  Bound: Integer;
begin
  SetLength(Result, 0);
  Bound := 0;
  for i := 0 to High(Cfg.MCPServers) do
  begin
    if not Cfg.MCPServers[i].Enabled then Continue;
    if IsHttpUrl(Cfg.MCPServers[i].Cmd) then
    begin
      { HTTP transport: Cmd = URL, Args (optional) = "Bearer ..." token }
      Client := TMCPHttpClient.Create(Cfg.MCPServers[i].Name,
                                      Cfg.MCPServers[i].Cmd,
                                      Cfg.MCPServers[i].Args);
    end
    else
    begin
      Client := TMCPStdioClient.Create(Cfg.MCPServers[i].Name,
                                       Cfg.MCPServers[i].Cmd,
                                       Cfg.MCPServers[i].Args);
    end;
    if not Client.Connect(5000, Err) then
    begin
      LogWarn('mcp[%s] connect failed: %s', [Cfg.MCPServers[i].Name, Err]);
      Client.Free;
      Continue;
    end;
    if not Client.ListTools(Tools, Err) then
    begin
      LogWarn('mcp[%s] list tools failed: %s', [Cfg.MCPServers[i].Name, Err]);
      Client.Free;
      Continue;
    end;
    LogInfo('mcp[%s] connected, %d tool(s)', [Cfg.MCPServers[i].Name, Length(Tools)]);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Client;
    for j := 0 to High(Tools) do
    begin
      slot := AllocateSlot;
      if slot < 0 then
      begin
        LogWarn('mcp: out of binding slots (max %d); skipping further tools', [MaxBindings]);
        Exit;
      end;
      ToolEntry.Name        := Cfg.MCPServers[i].Name + '__' + Tools[j].Name;
      ToolEntry.Description := '[mcp:' + Cfg.MCPServers[i].Name + '] ' + Tools[j].Description;
      ToolEntry.Schema      := Tools[j].Schema;
      ToolEntry.Handler     := Handlers[slot];
      ToolEntry.IsCore      := False;
      GBindings[slot].Client   := Client;
      GBindings[slot].ToolName := Tools[j].Name;
      GBindings[slot].InUse    := True;
      Reg.Register(ToolEntry);
      Inc(Bound);
    end;
  end;
  if Bound > 0 then LogDebug('mcp: %d tool(s) bound across %d server(s)', [Bound, Length(Result)]);
end;

procedure FreeMCPClients(var Clients: TMCPClientList);
var
  i: Integer;
begin
  for i := 0 to High(Clients) do
    if Clients[i] <> nil then Clients[i].Free;
  SetLength(Clients, 0);
  for i := 0 to High(GBindings) do
  begin
    GBindings[i].Client   := nil;
    GBindings[i].ToolName := '';
    GBindings[i].InUse    := False;
  end;
end;

initialization
  { all bindings start free }

end.
