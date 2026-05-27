(*
  PasClaw.TUI - terminal UI for `pasclaw tui`.

  Two implementations behind the same TTUI class shape:

    {$IFNDEF FPC}  Delphi build: uses MVCFramework.Console (vendored in
                   src/pkg/vendor/dmvcframework/, Apache-2.0) for
                   themed headers, boxes, tables, themed colors, and a
                   background-threaded spinner during the LLM round trip.

    {$IFDEF FPC}   FPC build: original line-based ANSI renderer. Works
                   in any vt100-class terminal including tmux/screen
                   scrollback. No external deps.

  Both share the same loop: prompt, read line, slash-command vs.
  user-input dispatch, run tool loop, print the answer. The differences
  are purely visual.
*)
unit PasClaw.TUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TTUI = class
  private
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FModel:    string;
    FQuit:     Boolean;
    procedure DrawHeader;
    procedure ShowHelp;
    procedure ShowTools;
    procedure HandleSlashCommand(const Cmd: string);
    procedure HandleUserInput(const Text: string);
  public
    constructor Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
    procedure Run;
  end;

implementation

uses
  Classes,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop
  {$IFNDEF FPC}
  , MVCFramework.Console
  {$ENDIF}
  ;

constructor TTUI.Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
begin
  inherited Create;
  FProvider := Provider;
  FRegistry := Registry;
  FModel    := Model;
end;

function StatusLine(Provider: ILLMProvider; const Model: string;
                    Registry: TToolRegistry): string;
begin
  if Provider <> nil then
    Result := Provider.GetName + '/' + Model
  else
    Result := 'offline';
  if Registry <> nil then
    Result := Result + '  tools:' + IntToStr(Registry.Count);
end;

{ ============================== Delphi (rich) ============================== }
{$IFNDEF FPC}

procedure TTUI.DrawHeader;
begin
  ClrScr;
  WriteHeader('PasClaw  ' + StatusLine(FProvider, FModel, FRegistry), 80, Cyan);
end;

procedure TTUI.ShowHelp;
var
  Lines: TStringArray;
begin
  SetLength(Lines, 4);
  Lines[0] := '/help    show this panel';
  Lines[1] := '/tools   list registered tools';
  Lines[2] := '/clear   clear the screen';
  Lines[3] := '/quit    exit';
  Box('TUI commands', Lines, 60);
end;

procedure TTUI.ShowTools;
var
  Names: TStringArray;
  Rows: TStringMatrix;
  Headers: TStringArray;
  i: Integer;
begin
  if FRegistry = nil then
  begin
    WriteWarning('no registry');
    Exit;
  end;
  Names := FRegistry.Names;
  if Length(Names) = 0 then
  begin
    WriteInfo('registry is empty');
    Exit;
  end;
  SetLength(Headers, 2);
  Headers[0] := '#';
  Headers[1] := 'tool';
  SetLength(Rows, Length(Names));
  for i := 0 to High(Names) do
  begin
    SetLength(Rows[i], 2);
    Rows[i][0] := IntToStr(i + 1);
    Rows[i][1] := Names[i];
  end;
  Table(Headers, Rows, Format('tools (%d)', [Length(Names)]));
end;

procedure TTUI.HandleSlashCommand(const Cmd: string);
begin
  if (Cmd = '/quit') or (Cmd = '/exit') or (Cmd = '/q') then
  begin
    FQuit := True;
    Exit;
  end;
  if Cmd = '/clear' then begin DrawHeader; Exit; end;
  if Cmd = '/tools' then begin ShowTools; Exit; end;
  if Cmd = '/help'  then begin ShowHelp;  Exit; end;
  WriteWarning('unknown command: ' + Cmd);
end;

procedure TTUI.HandleUserInput(const Text: string);
var
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  Cfg: TToolLoopConfig;
  S: ISpinner;
  Ok: Boolean;
begin
  if FProvider = nil then
  begin
    WriteWarning('offline - no provider configured');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Text);

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := FModel;
  Cfg.MaxIterations := 6;
  Cfg.Options       := DefaultChatOptions;
  Cfg.OnText        := nil;
  Cfg.OnToolCall    := nil;
  Cfg.OnToolResult  := nil;

  S := Spinner('thinking', ssDots, Cyan);
  try
    Ok := RunToolLoop(Cfg, Msgs, Loop);
  finally
    S.Hide;
    S := nil;
  end;

  if not Ok then
  begin
    WriteError('tool loop failed');
    Exit;
  end;

  WriteColoredText('pasclaw', Magenta);
  WriteColoredText(' > ', DarkGray);
  WriteLn(Loop.Content);
  if Loop.LastResp.Usage.InputTokens + Loop.LastResp.Usage.OutputTokens > 0 then
    WriteColoredText(Format('         [tokens in=%d out=%d, iters=%d]'#10,
      [Loop.LastResp.Usage.InputTokens, Loop.LastResp.Usage.OutputTokens, Loop.Iterations]),
      DarkGray);
end;

procedure TTUI.Run;
var
  Line: string;
begin
  EnableUTF8Console;
  EnableANSIColorConsole;
  DrawHeader;
  WriteColoredText('/help for commands, /quit to exit'#10, DarkGray);
  WriteLn;
  FQuit := False;
  while not FQuit do
  begin
    WriteColoredText('you', Cyan);
    WriteColoredText(' > ', DarkGray);
    if EOF then Break;
    ReadLn(Line);
    Line := Trim(Line);
    if Line = '' then Continue;
    if (Line[1] = '/') then
    begin
      HandleSlashCommand(Line);
      Continue;
    end;
    HandleUserInput(Line);
  end;
  WriteColoredText('goodbye.'#10, DarkGray);
end;

{$ELSE}
{ ============================= FPC (line-based) ============================ }

{$IFDEF UNIX}
const
  TIOCGWINSZ = $5413;
type
  Twinsize = record
    ws_row, ws_col, ws_xpixel, ws_ypixel: Word;
  end;
function FpIoctl(fd: Integer; req: Cardinal; argp: Pointer): Integer; cdecl;
  external 'c' name 'ioctl';
{$ENDIF}

function TermWidth: Integer;
{$IFDEF UNIX}
var
  ws: Twinsize;
{$ENDIF}
begin
  Result := 80;
  {$IFDEF UNIX}
  FillChar(ws, SizeOf(ws), 0);
  if FpIoctl(1, TIOCGWINSZ, @ws) = 0 then
    if ws.ws_col > 0 then Result := ws.ws_col;
  {$ENDIF}
end;

procedure TTUI.DrawHeader;
var
  Left, Right: string;
  Pad, W: Integer;
begin
  Left  := Ansi.BoldBlue + 'PAS' + Ansi.BoldRed + 'CLAW' + Ansi.Reset;
  Right := Ansi.Dim + StatusLine(FProvider, FModel, FRegistry) + Ansi.Reset;
  W := TermWidth;
  Pad := W - 7 - Length(StatusLine(FProvider, FModel, FRegistry));
  if Pad < 2 then Pad := 2;
  WriteLn;
  WriteLn(Left, StringOfChar(' ', Pad), Right);
  WriteLn(Ansi.Dim, StringOfChar('-', TermWidth), Ansi.Reset);
end;

procedure TTUI.ShowHelp;
begin
  WriteLn(Ansi.Bold, 'TUI commands:', Ansi.Reset);
  WriteLn('  /help    show this');
  WriteLn('  /tools   list registered tools');
  WriteLn('  /clear   clear the screen');
  WriteLn('  /quit    exit');
end;

procedure TTUI.ShowTools;
var
  i: Integer;
  Names: TStringArray;
begin
  if FRegistry = nil then
  begin
    WriteLn(Ansi.Dim, '(no registry)', Ansi.Reset);
    Exit;
  end;
  Names := FRegistry.Names;
  WriteLn(Ansi.Bold, 'tools (', Length(Names), '):', Ansi.Reset);
  for i := 0 to High(Names) do WriteLn('  ', Names[i]);
end;

procedure TTUI.HandleSlashCommand(const Cmd: string);
begin
  if (Cmd = '/quit') or (Cmd = '/exit') or (Cmd = '/q') then begin FQuit := True; Exit; end;
  if Cmd = '/clear' then begin Write(#27'[2J', #27'[H'); DrawHeader; Exit; end;
  if Cmd = '/tools' then begin ShowTools; Exit; end;
  if Cmd = '/help'  then begin ShowHelp;  Exit; end;
  WriteLn(Ansi.Yellow, 'unknown command: ', Cmd, Ansi.Reset);
end;

procedure TTUI.HandleUserInput(const Text: string);
var
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  Cfg: TToolLoopConfig;
begin
  if FProvider = nil then
  begin
    WriteLn(Ansi.Yellow, 'pasclaw  > ', Ansi.Reset,
            '(offline - no provider configured)');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Text);

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := FModel;
  Cfg.MaxIterations := 6;
  Cfg.Options       := DefaultChatOptions;
  Cfg.OnText        := nil;
  Cfg.OnToolCall    := nil;
  Cfg.OnToolResult  := nil;

  if not RunToolLoop(Cfg, Msgs, Loop) then
  begin
    WriteLn(Ansi.Red, 'pasclaw  > ', Ansi.Reset, '(tool loop failed)');
    Exit;
  end;
  Write(Ansi.BoldBlue, 'pasclaw', Ansi.Reset, '  > ');
  WriteLn(Loop.Content);
  if Loop.LastResp.Usage.InputTokens + Loop.LastResp.Usage.OutputTokens > 0 then
    WriteLn(Ansi.Dim, '         ',
      Format('[tokens in=%d out=%d, iters=%d]',
        [Loop.LastResp.Usage.InputTokens, Loop.LastResp.Usage.OutputTokens, Loop.Iterations]),
      Ansi.Reset);
end;

procedure TTUI.Run;
var
  Line: string;
begin
  Write(#27'[2J', #27'[H');
  DrawHeader;
  WriteLn(Ansi.Dim, '/help for commands, /quit to exit', Ansi.Reset);
  WriteLn;
  FQuit := False;
  while not FQuit do
  begin
    Write(Ansi.BoldBlue, 'you', Ansi.Reset, '      > ');
    if EOF then Break;
    ReadLn(Line);
    Line := Trim(Line);
    if Line = '' then Continue;
    if (Line[1] = '/') then
    begin
      HandleSlashCommand(Line);
      Continue;
    end;
    HandleUserInput(Line);
  end;
  WriteLn(Ansi.Dim, 'goodbye.', Ansi.Reset);
end;

{$ENDIF}

end.
