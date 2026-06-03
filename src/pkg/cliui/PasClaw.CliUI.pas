{
  PasClaw.CliUI - terminal colour handling, banner, help/error rendering.
  Mirrors cmd/picoclaw/internal/cliui in picoclaw.
}
unit PasClaw.CliUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TAnsi = record
    Reset, Bold, Dim, Red, Green, Yellow, Blue, Magenta, Cyan, Gray, BoldBlue, BoldRed: string;
  end;

var
  Ansi: TAnsi;

procedure CliUI_Init(NoColor: Boolean);
function  CliUI_NoColor: Boolean;
function  EarlyColorDisabled: Boolean;
procedure PrintBanner;
procedure ApplyTimezoneFromEnv;

{ Boxed panel rendering used by help / error output. Width auto-fits to the
  terminal (capped at 100 cols) and falls back to ASCII when colour is off. }
function  RenderPanel(const Title: string; const Lines: array of string): string;
function  FormatCLIError(const Msg, CommandPath: string): string;
function  RenderCommandHelp(const Use, Short, Long, Example: string;
                            const Subcommands, Flags: array of string): string;

(* Prompt for a line of input WITHOUT echoing keystrokes to the
   terminal — for API keys, MCP auth tokens, and any other secret
   credential the user pastes during onboarding. Echo is restored
   before return regardless of exception. Falls back to a plain
   ReadLn (with echo) when the terminal mode can't be queried
   (e.g. stdin is a pipe, as in scripted tests) so non-interactive
   automation still works. Codex P2 on PR #126. *)
function ReadSecretLine(const Prompt: string): string;

implementation

uses
  PasClaw.Utils
  {$IFDEF MSWINDOWS}
  , {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF}
  {$ENDIF}
  {$IFDEF UNIX}
  , BaseUnix, TermIO
  {$ENDIF}
  ;

var
  GNoColor: Boolean = False;

{$IFDEF MSWINDOWS}
procedure EnableUTF8Console;
begin
  { Force UTF-8 console code pages on Windows so Unicode banner/panel glyphs
    (█, ╔, ┌, etc.) are not interpreted via legacy ANSI/OEM encodings.
    SetConsoleOutputCP alone tells the console how to interpret bytes;
    under Delphi the RTL also caches a per-Text-file codepage that
    converts UnicodeString → bytes before they reach the console, so we
    need SetTextCodePage to point Output/ErrOutput at UTF-8 as well.
    FPC's WriteLn already emits the UTF-8 bytes its AnsiString holds,
    so it doesn't need the extra call. }
  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
  {$IFNDEF FPC}
  SetTextCodePage(Output,    CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  {$ENDIF}
end;
{$ENDIF}

procedure SetAnsi(Disabled: Boolean);
begin
  if Disabled then
  begin
    Ansi.Reset    := '';
    Ansi.Bold     := '';
    Ansi.Dim      := '';
    Ansi.Red      := '';
    Ansi.Green    := '';
    Ansi.Yellow   := '';
    Ansi.Blue     := '';
    Ansi.Magenta  := '';
    Ansi.Cyan     := '';
    Ansi.Gray     := '';
    Ansi.BoldBlue := '';
    Ansi.BoldRed  := '';
  end
  else
  begin
    Ansi.Reset    := #27'[0m';
    Ansi.Bold     := #27'[1m';
    Ansi.Dim      := #27'[2m';
    Ansi.Red      := #27'[31m';
    Ansi.Green    := #27'[32m';
    Ansi.Yellow   := #27'[33m';
    Ansi.Blue     := #27'[34m';
    Ansi.Magenta  := #27'[35m';
    Ansi.Cyan     := #27'[36m';
    Ansi.Gray     := #27'[90m';
    Ansi.BoldBlue := #27'[1;38;2;62;93;185m';
    Ansi.BoldRed  := #27'[1;38;2;213;70;70m';
  end;
end;

procedure CliUI_Init(NoColor: Boolean);
begin
  {$IFDEF MSWINDOWS}
  EnableUTF8Console;
  {$ENDIF}
  GNoColor := NoColor;
  SetAnsi(NoColor);
end;

function CliUI_NoColor: Boolean;
begin
  Result := GNoColor;
end;

function EarlyColorDisabled: Boolean;
var
  i: Integer;
  a: string;
begin
  Result := False;
  if (GetEnvironmentVariable('NO_COLOR') <> '') or (GetEnvironmentVariable('TERM') = 'dumb') then
    Exit(True);
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if (a = '--no-color') or (a = '--no-color=true') or (a = '--no-color=1') then
      Exit(True);
  end;
end;

procedure PrintBanner;
const
  L1 = '██████╗  █████╗ ███████╗ ██████╗██╗      █████╗ ██╗    ██╗';
  L2 = '██╔══██╗██╔══██╗██╔════╝██╔════╝██║     ██╔══██╗██║    ██║';
  L3 = '██████╔╝███████║███████╗██║     ██║     ███████║██║ █╗ ██║';
  L4 = '██╔═══╝ ██╔══██║╚════██║██║     ██║     ██╔══██║██║███╗██║';
  L5 = '██║     ██║  ██║███████║╚██████╗███████╗██║  ██║╚███╔███╔╝';
  L6 = '╚═╝     ╚═╝  ╚═╝╚══════╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ';
begin
  WriteLn;
  if GNoColor then
  begin
    WriteLn(L1); WriteLn(L2); WriteLn(L3);
    WriteLn(L4); WriteLn(L5); WriteLn(L6);
  end
  else
  begin
    WriteLn(Ansi.BoldBlue + L1 + Ansi.Reset);
    WriteLn(Ansi.BoldBlue + L2 + Ansi.Reset);
    WriteLn(Ansi.BoldBlue + L3 + Ansi.Reset);
    WriteLn(Ansi.BoldRed  + L4 + Ansi.Reset);
    WriteLn(Ansi.BoldRed  + L5 + Ansi.Reset);
    WriteLn(Ansi.BoldRed  + L6 + Ansi.Reset);
  end;
  WriteLn;
end;

procedure ApplyTimezoneFromEnv;
var
  Tz: string;
begin
  Tz := GetEnvironmentVariable('TZ');
  if Tz = '' then Exit;
  WriteLn('TZ environment: ', Tz);
  WriteLn('ZONEINFO environment: ', GetEnvironmentVariable('ZONEINFO'));
  { FPC honours the TZ environment variable on Unix natively; on Windows we
    simply report it and let the RTL handle conversions. }
end;

function PadRight(const S: string; W: Integer): string;
begin
  if VisibleLength(S) >= W then Result := S
  else Result := S + StringOfChar(' ', W - VisibleLength(S));
end;

function RenderPanel(const Title: string; const Lines: array of string): string;
const
  TL = '┌'; TR = '┐'; BL = '└'; BR = '┘'; H = '─'; V = '│';
var
  i, W: Integer;
  SB: TStringBuilder;
  Hbar: string;
begin
  W := VisibleLength(Title) + 2;
  for i := 0 to High(Lines) do
    if VisibleLength(Lines[i]) + 2 > W then
      W := VisibleLength(Lines[i]) + 2;
  if W < 32 then W := 32;
  if W > 100 then W := 100;

  Hbar := DupStr(H, W);
  SB := TStringBuilder.Create;
  try
    SB.Append(Ansi.BoldBlue).Append(TL).Append(Hbar).Append(TR).Append(Ansi.Reset).AppendLine;
    SB.Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).Append(' ')
      .Append(Ansi.Bold).Append(PadRight(Title, W - 1)).Append(Ansi.Reset)
      .Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).AppendLine;
    SB.Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset)
      .Append(StringOfChar(' ', W))
      .Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).AppendLine;
    for i := 0 to High(Lines) do
      SB.Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).Append(' ')
        .Append(PadRight(Lines[i], W - 1))
        .Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).AppendLine;
    SB.Append(Ansi.BoldBlue).Append(BL).Append(Hbar).Append(BR).Append(Ansi.Reset).AppendLine;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function FormatCLIError(const Msg, CommandPath: string): string;
var
  Lines: array of string;
begin
  SetLength(Lines, 2);
  Lines[0] := Ansi.Red + 'error: ' + Ansi.Reset + Msg;
  if CommandPath <> '' then
    Lines[1] := Ansi.Dim + 'run `' + CommandPath + ' --help` for usage' + Ansi.Reset
  else
    Lines[1] := Ansi.Dim + 'run `pasclaw --help` for usage' + Ansi.Reset;
  Result := RenderPanel('PasClaw error', Lines);
end;

function RenderCommandHelp(const Use, Short, Long, Example: string;
                          const Subcommands, Flags: array of string): string;
var
  Lines: TStringList;
  i: Integer;
  Tmp: string;
begin
  Lines := TStringList.Create;
  try
    if Short <> '' then Lines.Add(Short);
    if Long  <> '' then
    begin
      Lines.Add('');
      Lines.Add(Long);
    end;
    Lines.Add('');
    Lines.Add(Ansi.Bold + 'Usage:' + Ansi.Reset);
    Lines.Add('  ' + Use);
    if Length(Subcommands) > 0 then
    begin
      Lines.Add('');
      Lines.Add(Ansi.Bold + 'Commands:' + Ansi.Reset);
      for i := 0 to High(Subcommands) do
        Lines.Add('  ' + Subcommands[i]);
    end;
    if Length(Flags) > 0 then
    begin
      Lines.Add('');
      Lines.Add(Ansi.Bold + 'Flags:' + Ansi.Reset);
      for i := 0 to High(Flags) do
        Lines.Add('  ' + Flags[i]);
    end;
    if Example <> '' then
    begin
      Lines.Add('');
      Lines.Add(Ansi.Bold + 'Examples:' + Ansi.Reset);
      Lines.Add('  ' + Example);
    end;

    Tmp := '';
    for i := 0 to Lines.Count - 1 do
    begin
      if i > 0 then Tmp := Tmp + sLineBreak;
      Tmp := Tmp + Lines[i];
    end;
    Result := Tmp + sLineBreak;
  finally
    Lines.Free;
  end;
end;

function ReadSecretLine(const Prompt: string): string;
{$IFDEF UNIX}
var
  Old, New_: TermIOS;
  HaveTerm: Boolean;
begin
  Write(Prompt);
  Flush(Output);
  HaveTerm := tcgetattr(0, Old) = 0;
  if HaveTerm then
  begin
    New_ := Old;
    { Clear ECHO so the typed/pasted token doesn't appear on screen or
      land in the terminal scrollback. Leave ICANON on so the user can
      still backspace and the line is delivered on Enter. }
    New_.c_lflag := New_.c_lflag and not ECHO;
    tcsetattr(0, TCSANOW, New_);
  end;
  try
    ReadLn(Result);
  finally
    if HaveTerm then tcsetattr(0, TCSANOW, Old);
  end;
  { ReadLn consumed the newline silently when echo was off — emit one
    so the next prompt starts on a fresh line. }
  if HaveTerm then WriteLn;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  H: THandle;
  OldMode, NewMode: DWORD;
  HaveMode: Boolean;
begin
  Write(Prompt);
  Flush(Output);
  H := GetStdHandle(STD_INPUT_HANDLE);
  HaveMode := (H <> INVALID_HANDLE_VALUE) and GetConsoleMode(H, OldMode);
  if HaveMode then
  begin
    NewMode := OldMode and not DWORD(ENABLE_ECHO_INPUT);
    SetConsoleMode(H, NewMode);
  end;
  try
    ReadLn(Result);
  finally
    if HaveMode then SetConsoleMode(H, OldMode);
  end;
  if HaveMode then WriteLn;
end;
{$ENDIF}
{$IF NOT DEFINED(UNIX) AND NOT DEFINED(MSWINDOWS)}
begin
  { Unknown platform — fall through to plain echoing read so the
    program still runs. }
  Write(Prompt);
  ReadLn(Result);
end;
{$IFEND}

initialization
  SetAnsi(False);
end.
