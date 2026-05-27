(*
  PasClaw.Cron.Scheduler - background thread that walks the configured
  cron entries, fires the next-due job, and sleeps until the next deadline.

  Job = invoke a registered skill (Phase 7's PasClaw.Skills) with the
  configured arguments, capture its output, write it to the memory store
  for the cron session, and optionally post to a channel.

  Lifecycle: Start spins up a TThread that loops; RequestStop sets a flag
  and pulses an event so the loop wakes immediately.
*)
unit PasClaw.Cron.Scheduler;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Config,
  PasClaw.Tools.Registry;

type
  TCronScheduler = class
  private
    FCfg:      TConfig;
    FRegistry: TToolRegistry;
    FThread:   TThread;
    FStopEvt:  TEvent;
    FStop:     Boolean;
    procedure RunOnce;
  public
    constructor Create(Cfg: TConfig; Registry: TToolRegistry);
    destructor  Destroy; override;
    procedure Start;
    procedure RequestStop;
    procedure WaitForStop;
  end;

implementation

uses
  DateUtils,
  PasClaw.Logger,
  PasClaw.Cron.Expr,
  PasClaw.Skills.Loader;

type
  TCronThread = class(TThread)
  private
    FOwner: TCronScheduler;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TCronScheduler);
  end;

constructor TCronThread.Create(Owner: TCronScheduler);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := Owner;
end;

procedure TCronThread.Execute;
begin
  while not Terminated do
  begin
    try
      FOwner.RunOnce;
    except
      on E: Exception do
        LogError('cron: scheduler loop error: %s', [E.Message]);
    end;
    { Sleep ~30s between ticks; 1-minute cron granularity tolerates this. }
    if FOwner.FStopEvt.WaitFor(30000) = wrSignaled then Break;
    if FOwner.FStop then Break;
  end;
end;

(* ---- TCronScheduler ---- *)

constructor TCronScheduler.Create(Cfg: TConfig; Registry: TToolRegistry);
begin
  inherited Create;
  FCfg      := Cfg;
  FRegistry := Registry;
  FStopEvt  := TEvent.Create(nil, True, False, '');
end;

destructor TCronScheduler.Destroy;
begin
  RequestStop;
  WaitForStop;
  FStopEvt.Free;
  inherited Destroy;
end;

procedure TCronScheduler.Start;
begin
  if FThread <> nil then Exit;
  FThread := TCronThread.Create(Self);
  FThread.Start;
  LogInfo('cron: scheduler started (%d entries)', [Length(FCfg.Crons)]);
end;

procedure TCronScheduler.RequestStop;
begin
  FStop := True;
  FStopEvt.SetEvent;
end;

procedure TCronScheduler.WaitForStop;
begin
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

procedure TCronScheduler.RunOnce;
var
  i: Integer;
  Expr: TCronExpr;
  Next, Now_: TDateTime;
  ShouldFire: Boolean;
  Output, Err: string;
begin
  Now_ := Now;
  for i := 0 to High(FCfg.Crons) do
  begin
    if not FCfg.Crons[i].Enabled then Continue;
    if not ParseCronExpr(FCfg.Crons[i].Spec, Expr) then
    begin
      LogWarn('cron[%s]: invalid expression %s', [FCfg.Crons[i].Id, FCfg.Crons[i].Spec]);
      Continue;
    end;

    { Fire if the previous next-fire time is within the last 60s (since we
      tick every ~30s). Persisting "last_fired" properly is Phase 8 work. }
    Next := NextFireAfter(Expr, IncMinute(Now_, -2));
    ShouldFire := (Next > 0) and (SecondsBetween(Now_, Next) <= 60) and (Next <= Now_);
    if not ShouldFire then Continue;

    LogInfo('cron[%s]: firing skill=%s args=%s',
            [FCfg.Crons[i].Id, FCfg.Crons[i].Skill, FCfg.Crons[i].Args]);
    Output := RunSkill(FRegistry, FCfg.Crons[i].Skill, FCfg.Crons[i].Args, Err);
    if Err <> '' then
      LogWarn('cron[%s]: skill error: %s', [FCfg.Crons[i].Id, Err])
    else if Output <> '' then
      LogInfo('cron[%s]: %s', [FCfg.Crons[i].Id, Copy(Output, 1, 200)]);
  end;
end;

end.
