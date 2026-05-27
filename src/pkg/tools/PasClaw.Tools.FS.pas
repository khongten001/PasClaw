{
  PasClaw.Tools.FS - built-in filesystem tools: fs_read, fs_write, fs_list.
  Mirrors a subset of pkg/tools/fs in picoclaw. Paths are not sandboxed by
  default; the gateway will install a workspace-restricted variant in Phase 4.
}
unit PasClaw.Tools.FS;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterFSTools(R: TToolRegistry);

implementation

uses
  PasClaw.JSON,
  PasClaw.Utils;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if not Obj.Has(Field) then Exit;
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function Tool_FSRead(const ArgsJSON: string; out ErrMsg: string): string;
var
  Path: string;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  if not FileExists(Path) then
  begin
    ErrMsg := 'no such file: ' + Path;
    Exit('');
  end;
  Result := ReadFileText(Path);
end;

function Tool_FSWrite(const ArgsJSON: string; out ErrMsg: string): string;
var
  Path, Content: string;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  ParseStringArg(ArgsJSON, 'content', Content);
  try
    WriteFileText(Path, Content);
    Result := Format('wrote %d bytes to %s', [Length(Content), Path]);
  except
    on E: Exception do
    begin
      ErrMsg := E.Message;
      Result := '';
    end;
  end;
end;

function Tool_FSList(const ArgsJSON: string; out ErrMsg: string): string;
var
  Path: string;
  SR: TSearchRec;
  SB: TStringBuilder;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  if not DirectoryExists(Path) then
  begin
    ErrMsg := 'no such directory: ' + Path;
    Exit('');
  end;
  SB := TStringBuilder.Create;
  try
    if FindFirst(JoinPath(Path, '*'), faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if (SR.Attr and faDirectory) <> 0 then
            SB.Append('d ').Append(SR.Name).Append(sLineBreak)
          else
            SB.Append('- ').Append(SR.Name).Append('  ').Append(SR.Size).Append(sLineBreak);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure RegisterFSTools(R: TToolRegistry);
var
  T: TTool;
begin
  T.Name        := 'fs_read';
  T.Description := 'Read the contents of a file from the local filesystem.';
  T.Schema      := '{"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file."}},"required":["path"]}';
  T.Handler     := Tool_FSRead;
  T.IsCore      := True;
  R.Register(T);

  T.Name        := 'fs_write';
  T.Description := 'Write a string to a file (overwrites). Creates parent dirs.';
  T.Schema      := '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}';
  T.Handler     := Tool_FSWrite;
  T.IsCore      := True;
  R.Register(T);

  T.Name        := 'fs_list';
  T.Description := 'List entries in a directory. Returns "d name" or "- name  size" lines.';
  T.Schema      := '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}';
  T.Handler     := Tool_FSList;
  T.IsCore      := True;
  R.Register(T);
end;

end.
