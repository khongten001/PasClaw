(*
  PasClaw.TUI - line-based ANSI terminal UI for `pasclaw tui`.

  Layout per turn:
       PASCLAW                                       provider/model | tools:N
       ---------------------------------------------------------------------
       you      > <input>
       pasclaw  > <streamed response, soft-wrapped to terminal width>
       ---------------------------------------------------------------------
       > _

  We deliberately stay line-based (no raw key handling, no alt-screen) so
  the same code runs in vt100, xterm, Windows Terminal, the GitHub Codespaces
  web terminal, and tmux/screen scrollback all behave intuitively. A future
  Phase can swap to a full-screen renderer (dmvc-tui or a curses-style)
  without changing the command-dispatch surface.

  ANSI references:
    CSI 2J        clear screen
    CSI <n>m      SGR (colour)
    \r            carriage return (overwrite current line)
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
    procedure DrawSeparator;
    function  TermWidth: Integer;
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
  PasClaw.Tools.ToolLoop;

{$IFDEF FPC}{$IFDEF UNIX}
{ Get terminal width via ioctl TIOCGWINSZ. Falls back to 80 if the call
  fails (e.g. stdin is a pipe). FPC-only — Delphi cross-platform width
  detection lands in a follow-up. }
const
  TIOCGWINSZ = $5413;
type
  Twinsize = record
    ws_row, ws_col, ws_xpixel, ws_ypixel: Word;
  end;
function FpIoctl(fd: Integer; req: Cardinal; argp: Pointer): Integer; cdecl;
  external 'c' name 'ioctl';
{$ENDIF}{$ENDIF}

constructor TTUI.Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
begin
  inherited Create;
  FProvider := Provider;
  FRegistry := Registry;
  FModel    := Model;
end;

function TTUI.TermWidth: Integer;
{$IFDEF FPC}{$IFDEF UNIX}
var
  ws: Twinsize;
{$ENDIF}{$ENDIF}
begin
  Result := 80;
  {$IFDEF FPC}{$IFDEF UNIX}
  FillChar(ws, SizeOf(ws), 0);
  if FpIoctl(1, TIOCGWINSZ, @ws) = 0 then
    if ws.ws_col > 0 then Result := ws.ws_col;
  {$ENDIF}{$ENDIF}
end;

procedure TTUI.DrawHeader;
var
  Left, Right: string;
  Pad, W: Integer;
begin
  Left  := Ansi.BoldBlue + 'PAS' + Ansi.BoldRed + 'CLAW' + Ansi.Reset;
  if FProvider <> nil then
    Right := Ansi.Dim + FProvider.GetName + '/' + FModel + Ansi.Reset
  else
    Right := Ansi.Yellow + 'offline' + Ansi.Reset;
  if FRegistry <> nil then
    Right := Right + Ansi.Dim + '  tools:' + IntToStr(FRegistry.Count) + Ansi.Reset;

  W := TermWidth;
  Pad := W - 7 - 8 - 8;
  if Pad < 2 then Pad := 2;
  WriteLn;
  WriteLn(Left, StringOfChar(' ', Pad), Right);
end;

procedure TTUI.DrawSeparator;
begin
  WriteLn(Ansi.Dim, StringOfChar('-', TermWidth), Ansi.Reset);
end;

procedure TTUI.HandleSlashCommand(const Cmd: string);
var
  i: Integer;
  Names: TStringArray;
begin
  if (Cmd = '/quit') or (Cmd = '/exit') or (Cmd = '/q') then
  begin
    FQuit := True;
    Exit;
  end;
  if Cmd = '/clear' then
  begin
    Write(#27'[2J', #27'[H');
    DrawHeader;
    DrawSeparator;
    Exit;
  end;
  if Cmd = '/tools' then
  begin
    if FRegistry = nil then
      WriteLn(Ansi.Dim, '(no registry)', Ansi.Reset)
    else
    begin
      Names := FRegistry.Names;
      WriteLn(Ansi.Bold, 'tools (', Length(Names), '):', Ansi.Reset);
      for i := 0 to High(Names) do
        WriteLn('  ', Names[i]);
    end;
    Exit;
  end;
  if Cmd = '/help' then
  begin
    WriteLn(Ansi.Bold, 'TUI commands:', Ansi.Reset);
    WriteLn('  /help    show this');
    WriteLn('  /tools   list registered tools');
    WriteLn('  /clear   clear the screen');
    WriteLn('  /quit    exit');
    Exit;
  end;
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
  DrawSeparator;
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

end.
