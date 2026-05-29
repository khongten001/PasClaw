(*
  PasClaw.Cron.State - on-disk "when did each cron last fire" map.

  Stored at <home>/workspace/cron/state.json as
    { "entries": [
        { "id": "<cron-id>", "last_fired": <unix-seconds> },
        …
    ] }

  Why this exists: TCronScheduler used to look back two minutes from
  Now to find missed fires. If the gateway was down longer than that
  (laptop closed, server restart, weekend), jobs silently skipped. If
  the gateway restarted within the window, the same job could double
  fire. Persisting the last successful fire time per id lets RunOnce
  compute NextFireAfter(LastFired) and catch up exactly once on
  startup — no silent skips, no double fires.

  Concurrency: only the single scheduler thread reads / writes this
  file, so no locking. Writes are atomic via temp + rename so a crash
  mid-save leaves the previous state intact rather than producing a
  half-written JSON.
*)
unit PasClaw.Cron.State;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TCronStateEntry = record
    Id:        string;
    LastFired: Int64;   { unix seconds; 0 = never }
  end;

  TCronState = class
  private
    FPath:    string;
    FEntries: array of TCronStateEntry;
    function IndexOf(const Id: string): Integer;
  public
    constructor Create(const Path: string);
    procedure Load;
    procedure Save;
    function  GetLastFired(const Id: string): Int64;
    procedure SetLastFired(const Id: string; UnixSeconds: Int64);
  end;

function DefaultCronStatePath: string;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger;

function DefaultCronStatePath: string;
begin
  Result := JoinPath(GetHome, 'workspace/cron/state.json');
end;

constructor TCronState.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  SetLength(FEntries, 0);
end;

function TCronState.IndexOf(const Id: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FEntries) do
    if FEntries[i].Id = Id then Exit(i);
  Result := -1;
end;

procedure TCronState.Load;
var
  Body: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  SetLength(FEntries, 0);
  if not FileExists(FPath) then Exit;
  try
    Body := ReadFileText(FPath);
  except
    on E: Exception do
    begin
      LogWarn('cron.state: read %s failed: %s', [FPath, E.Message]);
      Exit;
    end;
  end;
  if Trim(Body) = '' then Exit;
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      LogWarn('cron.state: bad JSON in %s (%s) — starting fresh', [FPath, E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray('entries');
    if Arr = nil then Exit;
    try
      SetLength(FEntries, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          FEntries[i].Id        := Item.GetStr('id',         '');
          FEntries[i].LastFired := Item.GetInt('last_fired', 0);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TCronState.Save;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  Tmp: string;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(FEntries) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('id',         FEntries[i].Id);
      Item.PutInt('last_fired', FEntries[i].LastFired);
      Arr.AddObject(Item);
    end;
    Root.PutArray('entries', Arr);

    EnsureDir(ExtractFilePath(FPath));
    Tmp := FPath + '.tmp';
    WriteFileText(Tmp, Root.ToJSON);
    { RenameFile is atomic on POSIX, near-atomic on NTFS. Either the
      old state survives or the new one lands; no partial write
      observed by the next Load. }
    if FileExists(FPath) then DeleteFile(FPath);
    if not RenameFile(Tmp, FPath) then
      LogWarn('cron.state: rename %s -> %s failed', [Tmp, FPath]);
  finally
    Root.Free;
  end;
end;

function TCronState.GetLastFired(const Id: string): Int64;
var
  Idx: Integer;
begin
  Idx := IndexOf(Id);
  if Idx < 0 then Exit(0);
  Result := FEntries[Idx].LastFired;
end;

procedure TCronState.SetLastFired(const Id: string; UnixSeconds: Int64);
var
  Idx: Integer;
begin
  Idx := IndexOf(Id);
  if Idx >= 0 then
    FEntries[Idx].LastFired := UnixSeconds
  else
  begin
    SetLength(FEntries, Length(FEntries) + 1);
    FEntries[High(FEntries)].Id        := Id;
    FEntries[High(FEntries)].LastFired := UnixSeconds;
  end;
end;

end.
