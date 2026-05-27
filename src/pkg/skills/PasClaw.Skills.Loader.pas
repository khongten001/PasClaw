(*
  PasClaw.Skills.Loader - skill manifest loader and runner.

  Skill manifest (JSON) lives at $PASCLAW_HOME/workspace/skills/<name>.json:

    {
      "name":        "weather_report",
      "description": "Fetch weather for a city",
      "type":        "shell" | "prompt",
      "schema":      { ... JSON Schema for args ... },
      "shell":       "curl -s 'https://wttr.in/{{city}}?format=3'",
      "prompt":      "Write a 2-sentence summary of: {{topic}}"
    }

  Shell skills run the configured command through a TProcess after token
  substitution of {{arg}} placeholders. Prompt skills return the rendered
  template unchanged for the caller (typically the agent) to send to the
  LLM. A skill registers as a tool in the registry once loaded.
*)
unit PasClaw.Skills.Loader;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

type
  TSkillSpec = record
    Name:        string;
    Description: string;
    Kind:        string;   { "shell" | "prompt" }
    Schema:      string;
    Shell:       string;
    Prompt:      string;
  end;

  TSkillSpecArray = array of TSkillSpec;

function LoadSkillManifests(const HomeDir: string): TSkillSpecArray;
procedure RegisterSkills(Reg: TToolRegistry; const Skills: TSkillSpecArray);
function RunSkill(Reg: TToolRegistry; const Name, ArgsJSON: string; out ErrMsg: string): string;
function RenderTemplate(const Template, ArgsJSON: string): string;

implementation

uses
  Process,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Logger;

const
  MaxSkills = 64;

var
  GSpecs: array[0..MaxSkills - 1] of TSkillSpec;
  GUsed: array[0..MaxSkills - 1] of Boolean;

function AllocSlot: Integer;
var
  i: Integer;
begin
  for i := 0 to High(GUsed) do
    if not GUsed[i] then Exit(i);
  Result := -1;
end;

(* Forward-declared handlers — one per slot. Same approach as MCP bridge. *)
function H_0  (const A: string; out E: string): string; forward;
function H_1  (const A: string; out E: string): string; forward;
function H_2  (const A: string; out E: string): string; forward;
function H_3  (const A: string; out E: string): string; forward;
function H_4  (const A: string; out E: string): string; forward;
function H_5  (const A: string; out E: string): string; forward;
function H_6  (const A: string; out E: string): string; forward;
function H_7  (const A: string; out E: string): string; forward;
function H_8  (const A: string; out E: string): string; forward;
function H_9  (const A: string; out E: string): string; forward;
function H_10 (const A: string; out E: string): string; forward;
function H_11 (const A: string; out E: string): string; forward;
function H_12 (const A: string; out E: string): string; forward;
function H_13 (const A: string; out E: string): string; forward;
function H_14 (const A: string; out E: string): string; forward;
function H_15 (const A: string; out E: string): string; forward;

function RunShellSkill(Slot: Integer; const ArgsJSON: string; out ErrMsg: string): string; forward;

function H_0  (const A: string; out E: string): string; begin Result := RunShellSkill(0,  A, E); end;
function H_1  (const A: string; out E: string): string; begin Result := RunShellSkill(1,  A, E); end;
function H_2  (const A: string; out E: string): string; begin Result := RunShellSkill(2,  A, E); end;
function H_3  (const A: string; out E: string): string; begin Result := RunShellSkill(3,  A, E); end;
function H_4  (const A: string; out E: string): string; begin Result := RunShellSkill(4,  A, E); end;
function H_5  (const A: string; out E: string): string; begin Result := RunShellSkill(5,  A, E); end;
function H_6  (const A: string; out E: string): string; begin Result := RunShellSkill(6,  A, E); end;
function H_7  (const A: string; out E: string): string; begin Result := RunShellSkill(7,  A, E); end;
function H_8  (const A: string; out E: string): string; begin Result := RunShellSkill(8,  A, E); end;
function H_9  (const A: string; out E: string): string; begin Result := RunShellSkill(9,  A, E); end;
function H_10 (const A: string; out E: string): string; begin Result := RunShellSkill(10, A, E); end;
function H_11 (const A: string; out E: string): string; begin Result := RunShellSkill(11, A, E); end;
function H_12 (const A: string; out E: string): string; begin Result := RunShellSkill(12, A, E); end;
function H_13 (const A: string; out E: string): string; begin Result := RunShellSkill(13, A, E); end;
function H_14 (const A: string; out E: string): string; begin Result := RunShellSkill(14, A, E); end;
function H_15 (const A: string; out E: string): string; begin Result := RunShellSkill(15, A, E); end;

const
  SkillHandlers: array[0..MaxSkills - 1] of TToolHandler = (
    @H_0,  @H_1,  @H_2,  @H_3,  @H_4,  @H_5,  @H_6,  @H_7,
    @H_8,  @H_9,  @H_10, @H_11, @H_12, @H_13, @H_14, @H_15,
    { 16..63 left nil; raising MaxSkills above 16 requires extending the
      handler block. We log a warning if anyone tries. }
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil,
    nil, nil, nil, nil, nil, nil, nil, nil
  );

function RenderTemplate(const Template, ArgsJSON: string): string;
var
  Obj: TJsonObject;
  Out_: string;
  i: Integer;
  Token, Key, Value: string;
  InToken: Boolean;
begin
  Result := Template;
  if (Template = '') or (ArgsJSON = '') then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then Exit;
  try
    Out_ := '';
    Token := '';
    InToken := False;
    i := 1;
    while i <= Length(Template) do
    begin
      if (not InToken) and (i < Length(Template)) and
         (Template[i] = '{') and (Template[i + 1] = '{') then
      begin
        InToken := True;
        Token := '';
        Inc(i, 2);
        Continue;
      end;
      if InToken and (i < Length(Template)) and
         (Template[i] = '}') and (Template[i + 1] = '}') then
      begin
        Key := Trim(Token);
        Value := Obj.GetStr(Key, '');
        Out_ := Out_ + Value;
        InToken := False;
        Inc(i, 2);
        Continue;
      end;
      if InToken then Token := Token + Template[i]
      else Out_ := Out_ + Template[i];
      Inc(i);
    end;
    Result := Out_;
  finally
    Obj.Free;
  end;
end;

function RunShell(const Cmd: string; out ExitCode: Integer): string;
var
  P: TProcess;
  M: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  Result := '';
  ExitCode := -1;
  P := TProcess.Create(nil);
  M := TMemoryStream.Create;
  try
    {$IFDEF MSWINDOWS}
    P.Executable := 'cmd.exe';
    P.Parameters.Add('/C');
    P.Parameters.Add(Cmd);
    {$ELSE}
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(Cmd);
    {$ENDIF}
    P.Options := [poUsePipes, poStderrToOutPut];
    P.Execute;
    while P.Running or (P.Output.NumBytesAvailable > 0) do
    begin
      while P.Output.NumBytesAvailable > 0 do
      begin
        N := P.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then M.WriteBuffer(Buf, N);
      end;
      Sleep(20);
    end;
    ExitCode := P.ExitStatus;
    SetLength(Result, M.Size);
    if M.Size > 0 then
    begin
      M.Position := 0;
      M.ReadBuffer(Result[1], M.Size);
    end;
  finally
    M.Free;
    P.Free;
  end;
end;

function RunShellSkill(Slot: Integer; const ArgsJSON: string; out ErrMsg: string): string;
var
  Spec: TSkillSpec;
  Cmd: string;
  ExitCode: Integer;
begin
  ErrMsg := '';
  if (Slot < 0) or (Slot >= MaxSkills) or (not GUsed[Slot]) then
  begin
    ErrMsg := 'stale skill slot';
    Exit('');
  end;
  Spec := GSpecs[Slot];
  if Spec.Kind = 'prompt' then
  begin
    Result := RenderTemplate(Spec.Prompt, ArgsJSON);
    Exit;
  end;
  Cmd := RenderTemplate(Spec.Shell, ArgsJSON);
  if Cmd = '' then
  begin
    ErrMsg := 'empty shell template after rendering';
    Exit('');
  end;
  LogDebug('skill[%s]: %s', [Spec.Name, Copy(Cmd, 1, 200)]);
  Result := RunShell(Cmd, ExitCode);
  if ExitCode <> 0 then
    ErrMsg := Format('skill exit=%d', [ExitCode]);
end;

function LoadOne(const Path: string; out Spec: TSkillSpec): Boolean;
var
  Body: string;
  Obj, Schema: TJsonObject;
begin
  Result := False;
  Body := ReadFileText(Path);
  if Body = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Spec.Name        := Obj.GetStr('name',        '');
    Spec.Description := Obj.GetStr('description', '');
    Spec.Kind        := Obj.GetStr('type',        'shell');
    Spec.Shell       := Obj.GetStr('shell',       '');
    Spec.Prompt      := Obj.GetStr('prompt',      '');
    Schema := Obj.ChildObject('schema');
    if Schema <> nil then
    begin
      Spec.Schema := Schema.ToJSON;
      Schema.Free;
    end
    else
      Spec.Schema := '{"type":"object"}';
    Result := Spec.Name <> '';
  finally
    Obj.Free;
  end;
end;

function LoadSkillManifests(const HomeDir: string): TSkillSpecArray;
var
  Dir: string;
  SR: TSearchRec;
  Spec: TSkillSpec;
begin
  SetLength(Result, 0);
  Dir := JoinPath(HomeDir, 'workspace/skills');
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*.json'), faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      if LoadOne(JoinPath(Dir, SR.Name), Spec) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Spec;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure RegisterSkills(Reg: TToolRegistry; const Skills: TSkillSpecArray);
var
  i, Slot: Integer;
  Tool: TTool;
begin
  if Reg = nil then Exit;
  for i := 0 to High(Skills) do
  begin
    Slot := AllocSlot;
    if (Slot < 0) or (not Assigned(SkillHandlers[Slot])) then
    begin
      LogWarn('skills: out of handler slots (skipping %s)', [Skills[i].Name]);
      Continue;
    end;
    GSpecs[Slot] := Skills[i];
    GUsed[Slot]  := True;
    Tool.Name        := 'skill_' + Skills[i].Name;
    Tool.Description := Skills[i].Description;
    Tool.Schema      := Skills[i].Schema;
    Tool.Handler     := SkillHandlers[Slot];
    Tool.IsCore      := False;
    Reg.Register(Tool);
    LogDebug('skills: registered %s (slot=%d, kind=%s)', [Skills[i].Name, Slot, Skills[i].Kind]);
  end;
end;

function RunSkill(Reg: TToolRegistry; const Name, ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  if Reg = nil then begin ErrMsg := 'no registry'; Exit(''); end;
  Result := Reg.Dispatch('skill_' + Name, ArgsJSON, ErrMsg);
end;

initialization
  { all slots free }

end.
