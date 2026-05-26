{
  PasClaw.Cmd.Root - root command dispatcher, equivalent to NewPicoclawCommand()
  in cmd/picoclaw/main.go. Each subcommand exposes a CmdSpec record and a
  Run() function; we route argv[1] to the matching command.
}
unit PasClaw.Cmd.Root;

{$MODE DELPHI}
{$H+}

interface

function RunRootCommand: Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Cmd.Onboard,
  PasClaw.Cmd.Agent,
  PasClaw.Cmd.Auth,
  PasClaw.Cmd.Gateway,
  PasClaw.Cmd.Status,
  PasClaw.Cmd.Version,
  PasClaw.Cmd.Cron,
  PasClaw.Cmd.MCP,
  PasClaw.Cmd.Migrate,
  PasClaw.Cmd.Skills,
  PasClaw.Cmd.Model,
  PasClaw.Cmd.Config_,
  PasClaw.Cmd.Update,
  PasClaw.Cmd.Post;

type
  TSubCmd = record
    Name: string;
    Help: string;
    Run:  function(const Argv: array of string): Integer;
  end;

procedure StripGlobalFlags(var Out_: TStringList);
var
  i: Integer;
begin
  i := 0;
  while i < Out_.Count do
  begin
    if (Out_[i] = '--no-color')
      or (Out_[i] = '--no-color=true')
      or (Out_[i] = '--no-color=1')
    then
      Out_.Delete(i)
    else
      Inc(i);
  end;
end;

function CollectArgs: TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  for i := 1 to ParamCount do Result.Add(ParamStr(i));
end;

function ToArray(L: TStringList; StartIdx: Integer): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, L.Count - StartIdx);
  for i := StartIdx to L.Count - 1 do
    Result[i - StartIdx] := L[i];
end;

procedure PrintRootHelp;
const
  Use = 'pasclaw [command] [flags]';
  Short = 'PasClaw — personal AI assistant';
  Long  = 'PasClaw is a lightweight personal AI assistant.';
  Example = 'pasclaw version' + sLineBreak +
            '  pasclaw onboard' + sLineBreak +
            '  pasclaw --no-color status';
var
  Sub, Fl: array of string;
begin
  SetLength(Sub, 14);
  Sub[0]  := 'config       View/edit configuration';
  Sub[1]  := 'onboard      Initialize config & workspace';
  Sub[2]  := 'agent        Chat with the assistant';
  Sub[3]  := 'auth         Authenticate with providers';
  Sub[4]  := 'gateway      Start the gateway';
  Sub[5]  := 'status       Show status';
  Sub[6]  := 'cron         Manage scheduled tasks';
  Sub[7]  := 'mcp          Manage MCP servers';
  Sub[8]  := 'migrate      Migrate data from older versions';
  Sub[9]  := 'skills       Manage skill extensions';
  Sub[10] := 'model        View or switch the default model';
  Sub[11] := 'post         Send a one-shot message to a channel';
  Sub[12] := 'update       Self-update PasClaw';
  Sub[13] := 'version      Show version info';

  SetLength(Fl, 2);
  Fl[0] := '--no-color   Disable colored output (also: NO_COLOR env)';
  Fl[1] := '-h, --help   Show this help';

  Write(RenderCommandHelp(Use, Short, Long, Example, Sub, Fl));
end;

function RunRootCommand: Integer;
var
  Args: TStringList;
  Cmd, Last: string;
  ArgArr: TArray<string>;
  Cfg: TConfig;
begin
  Result := 0;
  Args := CollectArgs;
  try
    StripGlobalFlags(Args);

    { Apply log level from config (best-effort; ignore on missing file). }
    Cfg := LoadConfig;
    try
      SetLogLevelFromString(Cfg.Gateway.LogLevel);
    finally
      Cfg.Free;
    end;

    if (Args.Count = 0) or (Args[0] = '-h') or (Args[0] = '--help') or (Args[0] = 'help') then
    begin
      PrintRootHelp;
      Exit(0);
    end;

    Cmd := Args[0];
    ArgArr := ToArray(Args, 1);
    Last := 'pasclaw ' + Cmd;

    if      Cmd = 'config'   then Result := Cmd_Config_Run(ArgArr)
    else if Cmd = 'onboard'  then Result := Cmd_Onboard_Run(ArgArr)
    else if Cmd = 'agent'    then Result := Cmd_Agent_Run(ArgArr)
    else if Cmd = 'auth'     then Result := Cmd_Auth_Run(ArgArr)
    else if Cmd = 'gateway'  then Result := Cmd_Gateway_Run(ArgArr)
    else if Cmd = 'status'   then Result := Cmd_Status_Run(ArgArr)
    else if Cmd = 'cron'     then Result := Cmd_Cron_Run(ArgArr)
    else if Cmd = 'mcp'      then Result := Cmd_MCP_Run(ArgArr)
    else if Cmd = 'migrate'  then Result := Cmd_Migrate_Run(ArgArr)
    else if Cmd = 'skills'   then Result := Cmd_Skills_Run(ArgArr)
    else if Cmd = 'model'    then Result := Cmd_Model_Run(ArgArr)
    else if Cmd = 'post'     then Result := Cmd_Post_Run(ArgArr)
    else if Cmd = 'update'   then Result := Cmd_Update_Run(ArgArr)
    else if Cmd = 'version'  then Result := Cmd_Version_Run(ArgArr)
    else
    begin
      Write(ErrOutput, FormatCLIError('unknown command: ' + Cmd, 'pasclaw'));
      Result := 1;
    end;
  finally
    Args.Free;
  end;
end;

end.
