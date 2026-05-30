{ MCP — list/add/remove/edit/test/show MCP server entries in config. }
unit PasClaw.Cmd.MCP;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_MCP_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config, PasClaw.CliUI,
  PasClaw.MCP.Types,
  PasClaw.MCP.StdioClient,
  PasClaw.MCP.HttpClient,
  PasClaw.MCP.Catalog;

procedure Help;
begin
  WriteLn('Usage: pasclaw mcp <list|add|remove|test|edit|show|catalog|install> [args]');
  WriteLn('  add <name> <cmd> [args]   register a new MCP server');
  WriteLn('  remove <name>             delete an MCP server entry');
  WriteLn('  list                      list configured servers');
  WriteLn('  show <name>               show one server in detail');
  WriteLn('  test <name>               probe a server: initialize + tools/list');
  WriteLn('  edit                      open config in $EDITOR');
  WriteLn('  catalog                   list public MCP servers PasClaw knows about');
  WriteLn('  install <name>            add a server from the catalog (reads auth');
  WriteLn('                            from the env var the catalog entry names)');
end;

function DoList: Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  Cfg := LoadConfig;
  try
    if Length(Cfg.MCPServers) = 0 then
    begin
      WriteLn('(no MCP servers configured)');
      Exit(0);
    end;
    WriteLn(Ansi.Bold, 'name', Ansi.Reset, '            cmd');
    for i := 0 to High(Cfg.MCPServers) do
      WriteLn(Cfg.MCPServers[i].Name:14, '  ', Cfg.MCPServers[i].Cmd, ' ', Cfg.MCPServers[i].Args);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAdd(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: string;
  i, n: Integer;
begin
  if Length(Argv) < 3 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Args := '';
    for i := 3 to High(Argv) do
    begin
      if Args <> '' then Args := Args + ' ';
      Args := Args + Argv[i];
    end;
    n := Length(Cfg.MCPServers);
    SetLength(Cfg.MCPServers, n + 1);
    Cfg.MCPServers[n].Name    := Argv[1];
    Cfg.MCPServers[n].Cmd     := Argv[2];
    Cfg.MCPServers[n].Args    := Args;
    Cfg.MCPServers[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'added MCP server ', Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    dst := 0;
    for i := 0 to High(Cfg.MCPServers) do
      if not SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        Cfg.MCPServers[dst] := Cfg.MCPServers[i];
        Inc(dst);
      end;
    SetLength(Cfg.MCPServers, dst);
    SaveConfig(Cfg);
    WriteLn('removed ', Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoShow(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        WriteLn('name:    ', Cfg.MCPServers[i].Name);
        WriteLn('cmd:     ', Cfg.MCPServers[i].Cmd);
        WriteLn('args:    ', Cfg.MCPServers[i].Args);
        WriteLn('env:     ', Cfg.MCPServers[i].Env);
        WriteLn('enabled: ', Cfg.MCPServers[i].Enabled);
        Exit(0);
      end;
    WriteLn('no such MCP server: ', Argv[1]);
    Result := 1;
  finally
    Cfg.Free;
  end;
end;

function IsHttpUrl(const S: string): Boolean;
begin
  Result := (Length(S) >= 7) and
            ((LowerCase(Copy(S, 1, 7)) = 'http://') or
             ((Length(S) >= 8) and (LowerCase(Copy(S, 1, 8)) = 'https://')));
end;

function DoTest(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, j: Integer;
  Client: TMCPBaseClient;
  Tools: TMCPToolArray;
  Err: string;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        if IsHttpUrl(Cfg.MCPServers[i].Cmd) then
        begin
          WriteLn('Connecting HTTP MCP at ', Cfg.MCPServers[i].Cmd, '...');
          Client := TMCPHttpClient.Create(Cfg.MCPServers[i].Name,
                                          Cfg.MCPServers[i].Cmd,
                                          Cfg.MCPServers[i].Args);
        end
        else
        begin
          WriteLn('Spawning ', Cfg.MCPServers[i].Cmd, ' ', Cfg.MCPServers[i].Args, '...');
          Client := TMCPStdioClient.Create(Cfg.MCPServers[i].Name,
                                           Cfg.MCPServers[i].Cmd,
                                           Cfg.MCPServers[i].Args);
        end;
        try
          if not Client.Connect(5000, Err) then
          begin
            WriteLn(Ansi.Red, '✗ ', Err, Ansi.Reset);
            Exit(1);
          end;
          WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'initialize OK');
          WriteLn('  server: ', Client.ServerInfo.Name, ' ', Client.ServerInfo.Version);
          if Client.ListTools(Tools, Err) then
          begin
            WriteLn('  tools (', Length(Tools), '):');
            for j := 0 to High(Tools) do
              WriteLn('    - ', Tools[j].Name, '  ', Tools[j].Description);
          end
          else
            WriteLn(Ansi.Yellow, '  tools/list failed: ', Err, Ansi.Reset);
        finally
          Client.Free;
        end;
        Exit(0);
      end;
    WriteLn('no such MCP server: ', Argv[1]);
    Result := 1;
  finally
    Cfg.Free;
  end;
end;

function DoEdit(const Argv: array of string): Integer;
begin
  WriteLn('open ', GetConfigPath, ' in your editor (no shell-out yet).');
  Result := 0;
end;

function DoCatalog: Integer;
var
  Entries: TMCPCatalogEntryArray;
  i: Integer;
  Auth: string;
begin
  Entries := KnownMCPServers;
  if Length(Entries) = 0 then
  begin
    WriteLn('(catalog empty)');
    Exit(0);
  end;
  WriteLn(Ansi.Bold, 'name', Ansi.Reset, '                       env var               status');
  for i := 0 to High(Entries) do
  begin
    if Entries[i].EnvVar = '' then Auth := '(no auth)'
    else if GetEnvironmentVariable(Entries[i].EnvVar) <> '' then Auth := Ansi.Green + 'set' + Ansi.Reset
    else Auth := Ansi.Yellow + 'unset' + Ansi.Reset;
    WriteLn(Entries[i].Name:24, '   ', Entries[i].EnvVar:18, '   ', Auth);
    if Entries[i].Desc <> '' then
      WriteLn('                            ', Ansi.Dim, Entries[i].Desc, Ansi.Reset);
  end;
  WriteLn;
  WriteLn(Ansi.Dim, 'Install one with: pasclaw mcp install <name>', Ansi.Reset);
  Result := 0;
end;

function DoInstall(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Entry: TMCPCatalogEntry;
  HeaderVal: string;
  EnvSet, AuthOk: Boolean;
  i, n: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  if not FindCatalogEntry(Argv[1], Entry) then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'no catalog entry named "', Argv[1],
            '". Try: ', Ansi.Bold, 'pasclaw mcp catalog', Ansi.Reset);
    Exit(1);
  end;

  AuthOk := ResolveAuthHeader(Entry, HeaderVal, EnvSet);
  if (Entry.EnvVar <> '') and (not EnvSet) then
  begin
    WriteLn(Ansi.Yellow, '! ', Ansi.Reset, 'env var ', Entry.EnvVar,
            ' is not set. Installing anyway with an empty Authorization');
    WriteLn('  header — set ', Entry.EnvVar,
            ' and re-run `pasclaw mcp install ', Entry.Name, '` to refresh it,');
    WriteLn('  or run `pasclaw mcp edit` to drop in the token by hand.');
    HeaderVal := '';
  end
  else if AuthOk and (HeaderVal <> '') then
    WriteLn(Ansi.Dim, '  using ', Entry.EnvVar, ' from environment', Ansi.Reset);

  Cfg := LoadConfig;
  try
    { Replace any prior install of this catalog entry rather than
      creating a duplicate (idempotent refresh after the user sets
      the env var). }
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Entry.Name) then
      begin
        Cfg.MCPServers[i].Cmd     := Entry.URL;
        Cfg.MCPServers[i].Args    := HeaderVal;
        Cfg.MCPServers[i].Enabled := True;
        SaveConfig(Cfg);
        WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'updated MCP server ', Entry.Name);
        Exit(0);
      end;

    n := Length(Cfg.MCPServers);
    SetLength(Cfg.MCPServers, n + 1);
    Cfg.MCPServers[n].Name    := Entry.Name;
    Cfg.MCPServers[n].Cmd     := Entry.URL;
    Cfg.MCPServers[n].Args    := HeaderVal;
    Cfg.MCPServers[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'installed MCP server ', Entry.Name);
    WriteLn('  ', Ansi.Dim, Entry.Desc, Ansi.Reset);
    WriteLn('  Test with: ', Ansi.Bold, 'pasclaw mcp test ', Entry.Name, Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_MCP_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'add'     then Result := DoAdd(Argv)
  else if Sub = 'remove'  then Result := DoRemove(Argv)
  else if Sub = 'show'    then Result := DoShow(Argv)
  else if Sub = 'test'    then Result := DoTest(Argv)
  else if Sub = 'edit'    then Result := DoEdit(Argv)
  else if Sub = 'catalog' then Result := DoCatalog
  else if Sub = 'install' then Result := DoInstall(Argv)
  else begin Help; Result := 1; end;
end;

end.
