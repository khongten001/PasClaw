(*
  PasClaw.Memory - simple append-only conversation log.

  Each session writes one NDJSON file under $PASCLAW_HOME/workspace/memory/.
  Records are flushed line-by-line so a crash leaves a recoverable trail.
  This is intentionally lightweight; the picoclaw memory module includes a
  vector store, summarisation, and retrieval — those land in later phases.

  Record shape:
    {"ts":"2026-...","session":"...","role":"user|assistant|tool","content":"...","tool":"..."}
*)
unit PasClaw.Memory;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types;

type
  TMemoryLog = class
  private
    FPath:    string;
    FSession: string;
    FStream:  TFileStream;
    procedure WriteLine(const S: string);
  public
    constructor Create(const Path, SessionId: string);
    destructor  Destroy; override;
    procedure Append(Role: TMsgRole; const Content, ToolName: string);
    procedure AppendRaw(const RoleName, Content, ToolName: string);
    function  LoadHistory: TMessageArray;
  end;

function NewSessionId: string;
function NewMemoryLog(const HomeDir, SessionId: string): TMemoryLog;

implementation

uses
  DateUtils,
  PasClaw.Utils,
  PasClaw.JSON;

function NewSessionId: string;
var
  GUID: TGUID;
begin
  CreateGUID(GUID);
  Result := FormatDateTime('yyyymmdd-hhnnss', Now) + '-' +
            LowerCase(Copy(GUIDToString(GUID), 2, 8));
end;

function NewMemoryLog(const HomeDir, SessionId: string): TMemoryLog;
var
  Dir, Path: string;
begin
  Dir := JoinPath(HomeDir, 'workspace/memory');
  EnsureDir(Dir);
  Path := JoinPath(Dir, SessionId + '.ndjson');
  Result := TMemoryLog.Create(Path, SessionId);
end;

constructor TMemoryLog.Create(const Path, SessionId: string);
begin
  inherited Create;
  FPath := Path;
  FSession := SessionId;
  if FileExists(Path) then
    FStream := TFileStream.Create(Path, fmOpenReadWrite or fmShareDenyWrite)
  else
    FStream := TFileStream.Create(Path, fmCreate);
  FStream.Position := FStream.Size;
end;

destructor TMemoryLog.Destroy;
begin
  FreeAndNil(FStream);
  inherited Destroy;
end;

procedure TMemoryLog.WriteLine(const S: string);
var
  Line: string;
begin
  if FStream = nil then Exit;
  Line := S + #10;
  FStream.WriteBuffer(Line[1], Length(Line));
end;

procedure TMemoryLog.Append(Role: TMsgRole; const Content, ToolName: string);
begin
  AppendRaw(MsgRoleToString(Role), Content, ToolName);
end;

procedure TMemoryLog.AppendRaw(const RoleName, Content, ToolName: string);
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('ts',      FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', Now));
    Obj.PutStr('session', FSession);
    Obj.PutStr('role',    RoleName);
    Obj.PutStr('content', Content);
    if ToolName <> '' then Obj.PutStr('tool', ToolName);
    WriteLine(Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

function TMemoryLog.LoadHistory: TMessageArray;
var
  Reader: TStringList;
  i: Integer;
  Obj: TJsonObject;
  RoleStr, Content: string;
  Role: TMsgRole;
begin
  SetLength(Result, 0);
  if not FileExists(FPath) then Exit;
  Reader := TStringList.Create;
  try
    Reader.LoadFromFile(FPath);
    for i := 0 to Reader.Count - 1 do
    begin
      if Trim(Reader[i]) = '' then Continue;
      Obj := TJsonObject.Parse(Reader[i]);
      if Obj = nil then Continue;
      try
        RoleStr := Obj.GetStr('role',    'user');
        Content := Obj.GetStr('content', '');
        Role := MsgRoleFromString(RoleStr);
        if Content = '' then Continue;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := MakeMessage(Role, Content);
      finally
        Obj.Free;
      end;
    end;
  finally
    Reader.Free;
  end;
end;

end.
