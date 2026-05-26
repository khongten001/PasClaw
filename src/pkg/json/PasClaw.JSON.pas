(*
  PasClaw.JSON - thin JSON abstraction so the rest of the codebase doesn't
  bind to a specific JSON library.

  Backends:
    {$IFDEF FPC} fpjson + jsonparser
    {$ELSE}      System.JSON (Delphi 10.4+) or JsonDataObjects

  Surface area: opaque object/array handles + a small set of getters / setters
  that cover everything the agent loop, providers, MCP, gateway, and channels
  need. Call-sites use only this unit; nothing else imports fpjson.

  Memory model: TJsonObject / TJsonArray are reference-counted via interfaces
  in spirit, but we use plain classes with explicit Free since FPC interfaces
  + COM-style refcounting can clash with TInterfacedObject usage elsewhere.
  Owners free the root; nested objects are owned by their parents.
*)
unit PasClaw.JSON;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes;

type
  EPasClawJSON = class(Exception);

  TJsonObject = class;
  TJsonArray  = class;

  (* TJsonObject: build, parse, mutate JSON objects.
     Get* methods return the supplied Default when the key is missing or has
     the wrong type. ChildObject / ChildArray return live references owned by
     this object — do NOT free them yourself. *)
  TJsonObject = class
  private
    FBacking: TObject;   { wraps the backend's object type }
    FOwnsBacking: Boolean;
  public
    constructor Create;
    constructor CreateWrapping(Backing: TObject; OwnsIt: Boolean);
    destructor  Destroy; override;
    class function Parse(const S: string): TJsonObject;
    function Has(const Key: string): Boolean;
    function GetStr (const Key: string; const Default: string = ''): string;
    function GetInt (const Key: string; Default: Int64 = 0): Int64;
    function GetBool(const Key: string; Default: Boolean = False): Boolean;
    function GetFloat(const Key: string; Default: Double = 0): Double;
    function ChildObject(const Key: string): TJsonObject;   { nil if absent }
    function ChildArray (const Key: string): TJsonArray;    { nil if absent }
    procedure PutStr  (const Key, Value: string);
    procedure PutInt  (const Key: string; Value: Int64);
    procedure PutBool (const Key: string; Value: Boolean);
    procedure PutFloat(const Key: string; Value: Double);
    procedure PutObject(const Key: string; var Obj: TJsonObject);  { takes ownership; sets Obj := nil }
    procedure PutArray (const Key: string; var Arr: TJsonArray);   { takes ownership; sets Arr := nil }
    procedure PutRaw  (const Key, RawJSON: string);
    function ToJSON: string;
    function Backing: TObject;  { for cross-unit interop when absolutely needed }
  end;

  TJsonArray = class
  private
    FBacking: TObject;
    FOwnsBacking: Boolean;
  public
    constructor Create;
    constructor CreateWrapping(Backing: TObject; OwnsIt: Boolean);
    destructor  Destroy; override;
    class function Parse(const S: string): TJsonArray;
    function Count: Integer;
    function ItemStr   (Index: Integer; const Default: string = ''): string;
    function ItemInt   (Index: Integer; Default: Int64 = 0): Int64;
    function ItemBool  (Index: Integer; Default: Boolean = False): Boolean;
    function ItemObject(Index: Integer): TJsonObject;   { nil if not object }
    function ItemArray (Index: Integer): TJsonArray;    { nil if not array }
    procedure AddStr   (const Value: string);
    procedure AddInt   (Value: Int64);
    procedure AddBool  (Value: Boolean);
    procedure AddObject(var Obj: TJsonObject);
    procedure AddArray (var Arr: TJsonArray);
    procedure AddRaw   (const RawJSON: string);
    function ToJSON: string;
    function Backing: TObject;
  end;

{ Convenience: parse-then-free helpers for one-shot reads. }
function JsonReadStr (const Body, Key: string; const Default: string = ''): string;
function JsonReadInt (const Body, Key: string; Default: Int64 = 0): Int64;
function JsonReadBool(const Body, Key: string; Default: Boolean = False): Boolean;

{ Escape a string for embedding inside a JSON string literal (without quotes). }
function JsonEscape(const S: string): string;

implementation

{$IFDEF FPC}
uses
  fpjson, jsonparser;
{$ELSE}
uses
  System.JSON;
{$ENDIF}

function JsonEscape(const S: string): string;
var
  i: Integer;
  C: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for i := 1 to Length(S) do
    begin
      C := S[i];
      case C of
        '"':  SB.Append('\"');
        '\':  SB.Append('\\');
        #8:   SB.Append('\b');
        #9:   SB.Append('\t');
        #10:  SB.Append('\n');
        #12:  SB.Append('\f');
        #13:  SB.Append('\r');
      else
        if Ord(C) < 32 then
          SB.Append(Format('\u%.4x', [Ord(C)]))
        else
          SB.Append(C);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{$IFDEF FPC}
(* ----- FPC backend (fpjson) ----- *)

constructor TJsonObject.Create;
begin
  inherited Create;
  FBacking := fpjson.TJSONObject.Create;
  FOwnsBacking := True;
end;

constructor TJsonObject.CreateWrapping(Backing: TObject; OwnsIt: Boolean);
begin
  inherited Create;
  FBacking := Backing;
  FOwnsBacking := OwnsIt;
end;

destructor TJsonObject.Destroy;
begin
  if FOwnsBacking and (FBacking <> nil) then FBacking.Free;
  inherited Destroy;
end;

class function TJsonObject.Parse(const S: string): TJsonObject;
var
  Data: TJSONData;
begin
  Result := nil;
  if Trim(S) = '' then Exit;
  try
    Data := GetJSON(S);
  except
    on E: Exception do raise EPasClawJSON.CreateFmt('JSON parse: %s', [E.Message]);
  end;
  if not (Data is fpjson.TJSONObject) then
  begin
    Data.Free;
    Exit;
  end;
  Result := TJsonObject.CreateWrapping(Data, True);
end;

function TJsonObject.Has(const Key: string): Boolean;
begin
  Result := fpjson.TJSONObject(FBacking).IndexOfName(Key) >= 0;
end;

function TJsonObject.GetStr(const Key: string; const Default: string): string;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.GetInt(const Key: string; Default: Int64): Int64;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.GetBool(const Key: string; Default: Boolean): Boolean;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.GetFloat(const Key: string; Default: Double): Double;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.ChildObject(const Key: string): TJsonObject;
var
  D: TJSONData;
begin
  Result := nil;
  if not Has(Key) then Exit;
  D := fpjson.TJSONObject(FBacking).Find(Key);
  if D is fpjson.TJSONObject then
    Result := TJsonObject.CreateWrapping(D, False);
end;

function TJsonObject.ChildArray(const Key: string): TJsonArray;
var
  D: TJSONData;
begin
  Result := nil;
  if not Has(Key) then Exit;
  D := fpjson.TJSONObject(FBacking).Find(Key);
  if D is fpjson.TJSONArray then
    Result := TJsonArray.CreateWrapping(D, False);
end;

procedure TJsonObject.PutStr  (const Key, Value: string);
begin fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutInt  (const Key: string; Value: Int64);
begin fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutBool (const Key: string; Value: Boolean);
begin fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutFloat(const Key: string; Value: Double);
begin fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutObject(const Key: string; var Obj: TJsonObject);
var
  Inner: TJSONData;
begin
  if Obj = nil then Exit;
  Inner := TJSONData(Obj.Backing);
  Obj.FOwnsBacking := False;   { parent now owns it }
  Obj.Free;
  Obj := nil;
  fpjson.TJSONObject(FBacking).Add(Key, Inner);
end;

procedure TJsonObject.PutArray(const Key: string; var Arr: TJsonArray);
var
  Inner: TJSONData;
begin
  if Arr = nil then Exit;
  Inner := TJSONData(Arr.Backing);
  Arr.FOwnsBacking := False;
  Arr.Free;
  Arr := nil;
  fpjson.TJSONObject(FBacking).Add(Key, Inner);
end;

procedure TJsonObject.PutRaw(const Key, RawJSON: string);
var
  Data: TJSONData;
begin
  try
    Data := GetJSON(RawJSON);
    fpjson.TJSONObject(FBacking).Add(Key, Data);
  except
    fpjson.TJSONObject(FBacking).Add(Key, fpjson.TJSONObject.Create);
  end;
end;

function TJsonObject.ToJSON: string;
begin
  Result := fpjson.TJSONObject(FBacking).AsJSON;
end;

function TJsonObject.Backing: TObject;
begin
  Result := FBacking;
end;

(* TJsonArray *)

constructor TJsonArray.Create;
begin
  inherited Create;
  FBacking := fpjson.TJSONArray.Create;
  FOwnsBacking := True;
end;

constructor TJsonArray.CreateWrapping(Backing: TObject; OwnsIt: Boolean);
begin
  inherited Create;
  FBacking := Backing;
  FOwnsBacking := OwnsIt;
end;

destructor TJsonArray.Destroy;
begin
  if FOwnsBacking and (FBacking <> nil) then FBacking.Free;
  inherited Destroy;
end;

class function TJsonArray.Parse(const S: string): TJsonArray;
var
  Data: TJSONData;
begin
  Result := nil;
  if Trim(S) = '' then Exit;
  try
    Data := GetJSON(S);
  except
    on E: Exception do raise EPasClawJSON.CreateFmt('JSON parse: %s', [E.Message]);
  end;
  if not (Data is fpjson.TJSONArray) then
  begin
    Data.Free;
    Exit;
  end;
  Result := TJsonArray.CreateWrapping(Data, True);
end;

function TJsonArray.Count: Integer;
begin
  Result := fpjson.TJSONArray(FBacking).Count;
end;

function TJsonArray.ItemStr(Index: Integer; const Default: string): string;
var
  Arr: fpjson.TJSONArray;
begin
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit(Default);
  try Result := Arr.Strings[Index]; except Result := Default; end;
end;

function TJsonArray.ItemInt(Index: Integer; Default: Int64): Int64;
var
  Arr: fpjson.TJSONArray;
begin
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit(Default);
  try Result := Arr.Int64s[Index]; except Result := Default; end;
end;

function TJsonArray.ItemBool(Index: Integer; Default: Boolean): Boolean;
var
  Arr: fpjson.TJSONArray;
begin
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit(Default);
  try Result := Arr.Booleans[Index]; except Result := Default; end;
end;

function TJsonArray.ItemObject(Index: Integer): TJsonObject;
var
  Arr: fpjson.TJSONArray;
  D: TJSONData;
begin
  Result := nil;
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit;
  D := Arr[Index];
  if D is fpjson.TJSONObject then
    Result := TJsonObject.CreateWrapping(D, False);
end;

function TJsonArray.ItemArray(Index: Integer): TJsonArray;
var
  Arr: fpjson.TJSONArray;
  D: TJSONData;
begin
  Result := nil;
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit;
  D := Arr[Index];
  if D is fpjson.TJSONArray then
    Result := TJsonArray.CreateWrapping(D, False);
end;

procedure TJsonArray.AddStr (const Value: string);
begin fpjson.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddInt (Value: Int64);
begin fpjson.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddBool(Value: Boolean);
begin fpjson.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddObject(var Obj: TJsonObject);
var
  Inner: TJSONData;
begin
  if Obj = nil then Exit;
  Inner := TJSONData(Obj.Backing);
  Obj.FOwnsBacking := False;
  Obj.Free;
  Obj := nil;
  fpjson.TJSONArray(FBacking).Add(Inner);
end;

procedure TJsonArray.AddArray(var Arr: TJsonArray);
var
  Inner: TJSONData;
begin
  if Arr = nil then Exit;
  Inner := TJSONData(Arr.Backing);
  Arr.FOwnsBacking := False;
  Arr.Free;
  Arr := nil;
  fpjson.TJSONArray(FBacking).Add(Inner);
end;

procedure TJsonArray.AddRaw(const RawJSON: string);
var
  Data: TJSONData;
begin
  try
    Data := GetJSON(RawJSON);
    fpjson.TJSONArray(FBacking).Add(Data);
  except
    { swallow: bad JSON yields no addition }
  end;
end;

function TJsonArray.ToJSON: string;
begin
  Result := fpjson.TJSONArray(FBacking).AsJSON;
end;

function TJsonArray.Backing: TObject;
begin
  Result := FBacking;
end;

{$ELSE}
(* ----- Delphi backend (System.JSON) -----
   Implementations parallel to the FPC versions above. Keep the public
   interface identical so call sites need no changes. *)
{$ENDIF}

function JsonReadStr(const Body, Key: string; const Default: string): string;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit(Default);
  try
    Result := Obj.GetStr(Key, Default);
  finally
    Obj.Free;
  end;
end;

function JsonReadInt(const Body, Key: string; Default: Int64): Int64;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit(Default);
  try
    Result := Obj.GetInt(Key, Default);
  finally
    Obj.Free;
  end;
end;

function JsonReadBool(const Body, Key: string; Default: Boolean): Boolean;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit(Default);
  try
    Result := Obj.GetBool(Key, Default);
  finally
    Obj.Free;
  end;
end;

end.
