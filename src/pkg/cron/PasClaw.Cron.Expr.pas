(*
  PasClaw.Cron.Expr - 5-field cron expression parser and "next fire time"
  calculator. Mirrors a subset of pkg/cron in picoclaw.

  Fields: minute hour day-of-month month day-of-week
  Per-field syntax:
    *           any value
    N           single integer
    N,M,...     enumerated set
    N-M         inclusive range
    N-M/S       range with step
    */S         every step (full range)

  Both 0 and 7 are accepted as Sunday in the day-of-week field.

  Out of scope: special strings (@hourly, @daily), seconds field, named
  months/weekdays, last-day-of-month (L), nearest-weekday (W). They can
  be layered on top if/when needed.
*)
unit PasClaw.Cron.Expr;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils;

type
  TCronField = record
    Bits: array[0..63] of Boolean;   { only the relevant range is used }
    Min, Max: Integer;
  end;

  TCronExpr = record
    Minute, Hour, Day, Month, Weekday: TCronField;
    Valid: Boolean;
  end;

function ParseCronExpr(const S: string; out Expr: TCronExpr): Boolean;
function NextFireAfter(const Expr: TCronExpr; Start: TDateTime): TDateTime;

implementation

procedure InitField(var F: TCronField; AMin, AMax: Integer);
var
  i: Integer;
begin
  F.Min := AMin;
  F.Max := AMax;
  for i := 0 to High(F.Bits) do F.Bits[i] := False;
end;

procedure SetRange(var F: TCronField; Lo, Hi, Step: Integer);
var
  i: Integer;
begin
  if Step < 1 then Step := 1;
  if Lo < F.Min then Lo := F.Min;
  if Hi > F.Max then Hi := F.Max;
  i := Lo;
  while i <= Hi do
  begin
    if (i >= 0) and (i < Length(F.Bits)) then F.Bits[i] := True;
    Inc(i, Step);
  end;
end;

function ParseInt(const S: string; out V: Integer): Boolean;
var
  E: Integer;
begin
  Val(S, V, E);
  Result := E = 0;
end;

function ParseTerm(const Term: string; var F: TCronField): Boolean;
var
  Body, StepPart: string;
  SlashPos, DashPos: Integer;
  Lo, Hi, Step: Integer;
begin
  Result := False;
  if Term = '' then Exit;
  Body := Term;
  Step := 1;
  SlashPos := Pos('/', Body);
  if SlashPos > 0 then
  begin
    StepPart := Copy(Body, SlashPos + 1, MaxInt);
    Body := Copy(Body, 1, SlashPos - 1);
    if not ParseInt(StepPart, Step) then Exit;
    if Step < 1 then Exit;
  end;
  if Body = '*' then
  begin
    SetRange(F, F.Min, F.Max, Step);
    Exit(True);
  end;
  DashPos := Pos('-', Body);
  if DashPos > 0 then
  begin
    if not ParseInt(Copy(Body, 1, DashPos - 1), Lo) then Exit;
    if not ParseInt(Copy(Body, DashPos + 1, MaxInt), Hi) then Exit;
    SetRange(F, Lo, Hi, Step);
    Exit(True);
  end;
  if not ParseInt(Body, Lo) then Exit;
  if SlashPos > 0 then
    SetRange(F, Lo, F.Max, Step)
  else
    SetRange(F, Lo, Lo, 1);
  Result := True;
end;

function ParseList(const S: string; var F: TCronField): Boolean;
var
  Term: string;
  i, n: Integer;
begin
  Result := True;
  n := Length(S);
  Term := '';
  i := 1;
  while i <= n do
  begin
    if S[i] = ',' then
    begin
      if not ParseTerm(Term, F) then Exit(False);
      Term := '';
    end
    else
      Term := Term + S[i];
    Inc(i);
  end;
  if Term <> '' then
    if not ParseTerm(Term, F) then Exit(False);
end;

function SplitFields(const S: string; out F: array of string): Boolean;
var
  i, n, count: Integer;
  cur: string;
begin
  count := 0;
  cur := '';
  n := Length(S);
  for i := 1 to n do
  begin
    if (S[i] = ' ') or (S[i] = #9) then
    begin
      if cur <> '' then
      begin
        if count >= Length(F) then Exit(False);
        F[count] := cur;
        Inc(count);
        cur := '';
      end;
    end
    else
      cur := cur + S[i];
  end;
  if cur <> '' then
  begin
    if count >= Length(F) then Exit(False);
    F[count] := cur;
    Inc(count);
  end;
  Result := count = Length(F);
end;

function ParseCronExpr(const S: string; out Expr: TCronExpr): Boolean;
var
  Parts: array[0..4] of string;
begin
  FillChar(Expr, SizeOf(Expr), 0);
  Expr.Valid := False;
  InitField(Expr.Minute,  0, 59);
  InitField(Expr.Hour,    0, 23);
  InitField(Expr.Day,     1, 31);
  InitField(Expr.Month,   1, 12);
  InitField(Expr.Weekday, 0, 7);

  if not SplitFields(Trim(S), Parts) then Exit(False);
  if not ParseList(Parts[0], Expr.Minute)  then Exit(False);
  if not ParseList(Parts[1], Expr.Hour)    then Exit(False);
  if not ParseList(Parts[2], Expr.Day)     then Exit(False);
  if not ParseList(Parts[3], Expr.Month)   then Exit(False);
  if not ParseList(Parts[4], Expr.Weekday) then Exit(False);

  { Accept 0 and 7 as Sunday. }
  if Expr.Weekday.Bits[7] then Expr.Weekday.Bits[0] := True;
  if Expr.Weekday.Bits[0] then Expr.Weekday.Bits[7] := True;

  Expr.Valid := True;
  Result := True;
end;

function NextFireAfter(const Expr: TCronExpr; Start: TDateTime): TDateTime;
var
  Y, Mo, D, H, Mi, Se, MS: Word;
  Dow: Word;
  Candidate: TDateTime;
  i: Integer;
begin
  if not Expr.Valid then Exit(0);

  { Start at the next whole minute (cron has 1-minute granularity). }
  Candidate := Start + (1.0 / (24.0 * 60.0));
  for i := 1 to 60 * 24 * 366 + 60 * 24 * 7 do   { ~13 months of minutes }
  begin
    DecodeDate(Candidate, Y, Mo, D);
    DecodeTime(Candidate, H, Mi, Se, MS);
    Dow := DayOfWeek(Candidate) - 1;   { Pascal: 1=Sunday → 0=Sunday }

    if Expr.Minute.Bits[Mi] and
       Expr.Hour.Bits[H] and
       Expr.Day.Bits[D] and
       Expr.Month.Bits[Mo] and
       Expr.Weekday.Bits[Dow] then
      Exit(EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, 0, 0));

    Candidate := Candidate + (1.0 / (24.0 * 60.0));
  end;
  Result := 0;
end;

end.
