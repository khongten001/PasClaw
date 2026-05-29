{
  PasClaw.Tools.Labels - one-line human-readable labels for tool calls.

  Used by the gateway to surface tool activity to chat-completions clients
  without leaking the full raw arguments. Streaming clients render the label
  as a heartbeat delta; the non-streaming path prepends a compact transcript
  of these labels above the model's content so frontends that can't read SSE
  still see what work happened on this turn.

  Only the tool name and a small key value extracted from the args reach the
  client. Full args (which can carry paths, sensitive content, large patch
  bodies) stay server-side in the debug log.
}
unit PasClaw.Tools.Labels;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

function LabelToolCall(const Name, ArgsJSON: string): string;

implementation

uses
  PasClaw.JSON;

const
  MAX_LABEL_LEN = 80;

function FirstLine(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(S) do
    if (S[I] = #10) or (S[I] = #13) then
    begin
      Result := Copy(S, 1, I - 1);
      Exit;
    end;
end;

function Truncate(const S: string; MaxLen: Integer): string;
begin
  if Length(S) <= MaxLen then Result := S
  else Result := Copy(S, 1, MaxLen - 1) + '…';
end;

function PathFromHashlinePatch(const Patch: string): string;
const
  HL_FILE_PREFIX = '¶';
var
  Line: string;
  HashPos: Integer;
begin
  Line := Trim(FirstLine(Patch));
  if (Line <> '') and (Pos(HL_FILE_PREFIX, Line) = 1) then
    Line := Copy(Line, Length(HL_FILE_PREFIX) + 1, MaxInt);
  HashPos := Pos('#', Line);
  if HashPos > 1 then
    Result := Copy(Line, 1, HashPos - 1)
  else
    Result := Line;
end;

function TryGetStr(Obj: TJsonObject; const Key: string; out Value: string): Boolean;
begin
  Result := False;
  if Obj = nil then Exit;
  Value := Obj.GetStr(Key, '');
  Result := Value <> '';
end;

function LabelToolCall(const Name, ArgsJSON: string): string;
var
  Obj: TJsonObject;
  PathV, PatternV, CommandV, PatchV, IncludeV, SkillName: string;
begin
  if Trim(Name) = '' then
  begin
    Result := 'Calling tool';
    Exit;
  end;

  Obj := nil;
  if Trim(ArgsJSON) <> '' then
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    Obj := nil;
  end;

  try
    if Name = 'fs_read' then
    begin
      if TryGetStr(Obj, 'path', PathV) then
        Result := 'Reading ' + PathV
      else
        Result := 'Reading file';
    end
    else if Name = 'fs_write' then
    begin
      if TryGetStr(Obj, 'path', PathV) then
        Result := 'Writing ' + PathV
      else
        Result := 'Writing file';
    end
    else if Name = 'fs_list' then
    begin
      if TryGetStr(Obj, 'path', PathV) then
        Result := 'Listing ' + PathV
      else
        Result := 'Listing directory';
    end
    else if Name = 'fs_grep' then
    begin
      PathV := ''; PatternV := ''; IncludeV := '';
      if Obj <> nil then
      begin
        PathV    := Obj.GetStr('path',    '');
        PatternV := Obj.GetStr('pattern', '');
        IncludeV := Obj.GetStr('include', '');
      end;
      if (PatternV <> '') and (PathV <> '') then
        Result := 'Searching for "' + PatternV + '" in ' + PathV
      else if PatternV <> '' then
        Result := 'Searching for "' + PatternV + '"'
      else if PathV <> '' then
        Result := 'Searching ' + PathV
      else
        Result := 'Searching files';
      if (IncludeV <> '') and (Length(Result) + Length(IncludeV) + 4 < MAX_LABEL_LEN) then
        Result := Result + ' (' + IncludeV + ')';
    end
    else if Name = 'fs_edit_hashline' then
    begin
      PatchV := '';
      if Obj <> nil then PatchV := Obj.GetStr('patch', '');
      PathV := PathFromHashlinePatch(PatchV);
      if PathV <> '' then
        Result := 'Editing ' + PathV
      else
        Result := 'Applying patch';
    end
    else if Name = 'shell_exec' then
    begin
      CommandV := '';
      if Obj <> nil then CommandV := Obj.GetStr('command', '');
      CommandV := Trim(FirstLine(CommandV));
      if CommandV <> '' then
        Result := 'Running: ' + CommandV
      else
        Result := 'Running shell command';
    end
    else if Copy(Name, 1, 6) = 'skill_' then
    begin
      SkillName := Copy(Name, 7, MaxInt);
      if SkillName = '' then SkillName := Name;
      Result := 'Running skill ' + SkillName;
    end
    else
      Result := 'Calling ' + Name;
  finally
    if Obj <> nil then Obj.Free;
  end;

  Result := Truncate(Result, MAX_LABEL_LEN);
end;

end.
