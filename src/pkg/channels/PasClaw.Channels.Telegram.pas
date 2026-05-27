(*
  PasClaw.Channels.Telegram - long-polling Telegram bot adapter.

  Uses TIdHTTP to call the Bot API. No webhook needed - getUpdates with a
  long poll keeps things firewall-friendly. Each incoming text message is
  fed to the agent loop and the reply is sent back via sendMessage.

  Configure with PASCLAW_TELEGRAM_TOKEN or pass --token on the command line.
  Bot API docs: https://core.telegram.org/bots/api
*)
unit PasClaw.Channels.Telegram;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TTelegramChannel = class
  private
    FToken:     string;
    FCfg:       TConfig;
    FProvider:  ILLMProvider;
    FRegistry:  TToolRegistry;
    FOffset:    Int64;
    FStop:      Boolean;
    function ApiUrl(const Method: string): string;
    function GetUpdates(out RawJSON: string): Boolean;
    function SendMessage(ChatId: Int64; const Text: string): Boolean;
    procedure ProcessUpdate(const UpdateJSON: string);
  public
    constructor Create(const Token: string; Cfg: TConfig;
                       Provider: ILLMProvider; Registry: TToolRegistry);
    procedure Run;       { blocks until Stop is called or Ctrl-C }
    procedure RequestStop;
  end;

implementation

uses
  fpjson, jsonparser,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.HTTP,
  PasClaw.Tools.ToolLoop;

constructor TTelegramChannel.Create(const Token: string; Cfg: TConfig;
                                    Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FToken    := Token;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FOffset   := 0;
  FStop     := False;
end;

function TTelegramChannel.ApiUrl(const Method: string): string;
begin
  Result := 'https://api.telegram.org/bot' + FToken + '/' + Method;
end;

function TTelegramChannel.GetUpdates(out RawJSON: string): Boolean;
var
  URL: string;
  Empty: array of THeaderPair;
  Resp: THTTPResult;
begin
  RawJSON := '';
  SetLength(Empty, 0);
  URL := ApiUrl('getUpdates') +
         '?timeout=25&offset=' + IntToStr(FOffset);
  Resp := GetJSONURL(URL, Empty, 30);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    RawJSON := Resp.Body;
    Exit(True);
  end;
  LogWarn('telegram getUpdates failed: status=%d err=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result := False;
end;

function TTelegramChannel.SendMessage(ChatId: Int64; const Text: string): Boolean;
var
  URL, Body: string;
  Empty: array of THeaderPair;
  J: TJSONObject;
  Resp: THTTPResult;
begin
  SetLength(Empty, 0);
  URL := ApiUrl('sendMessage');
  J := TJSONObject.Create;
  try
    J.Add('chat_id', ChatId);
    J.Add('text',    Text);
    Body := J.AsJSON;
  finally
    J.Free;
  end;
  Resp := PostJSON(URL, Body, Empty, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('telegram sendMessage failed: status=%d body=%s', [Resp.StatusCode, Copy(Resp.Body,1,200)]);
end;

procedure TTelegramChannel.ProcessUpdate(const UpdateJSON: string);
var
  Root: TJSONData;
  Obj, Msg, Chat: TJSONObject;
  Text: string;
  ChatId, UpdateId: Int64;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Msgs: array of TMessage;
begin
  Root := GetJSON(UpdateJSON);
  try
    if not (Root is TJSONObject) then Exit;
    Obj := TJSONObject(Root);
    UpdateId := Obj.Get('update_id', Int64(0));
    if UpdateId >= FOffset then FOffset := UpdateId + 1;
    if Obj.IndexOfName('message') < 0 then Exit;
    Msg := Obj.Objects['message'];
    if Msg.IndexOfName('chat') < 0 then Exit;
    Chat := Msg.Objects['chat'];
    ChatId := Chat.Get('id', Int64(0));
    Text   := Msg.Get('text', '');
    if Text = '' then Exit;
  finally
    Root.Free;
  end;

  LogInfo('telegram: chat=%d msg=%s', [ChatId, Copy(Text, 1, 80)]);

  if FProvider = nil then
  begin
    SendMessage(ChatId, '(no provider configured — run `pasclaw onboard`)');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Text);

  LoopCfg.Provider      := FProvider;
  LoopCfg.Registry      := FRegistry;
  LoopCfg.Model         := FCfg.DefaultModel;
  LoopCfg.MaxIterations := 6;
  LoopCfg.Options       := DefaultChatOptions;
  LoopCfg.OnText        := nil;
  LoopCfg.OnToolCall    := nil;
  LoopCfg.OnToolResult  := nil;

  if RunToolLoop(LoopCfg, Msgs, Loop) and (Loop.Content <> '') then
    SendMessage(ChatId, Loop.Content)
  else
    SendMessage(ChatId, '(sorry — model returned no content)');
end;

procedure TTelegramChannel.Run;
var
  RawJSON: string;
  Root: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  if FToken = '' then
  begin
    LogError('telegram: no bot token (set PASCLAW_TELEGRAM_TOKEN or --token)');
    Exit;
  end;
  LogInfo('telegram: long-poll started (token …%s)',
    [Copy(FToken, Length(FToken) - 5, 5)]);

  while not FStop do
  begin
    if not GetUpdates(RawJSON) then
    begin
      Sleep(2000);
      Continue;
    end;
    try
      Root := GetJSON(RawJSON);
    except
      Sleep(1000);
      Continue;
    end;
    try
      if not (Root is TJSONObject) then Continue;
      Obj := TJSONObject(Root);
      if not Obj.Get('ok', False) then Continue;
      if Obj.IndexOfName('result') < 0 then Continue;
      Arr := Obj.Arrays['result'];
      for i := 0 to Arr.Count - 1 do
        ProcessUpdate(Arr[i].AsJSON);
    finally
      Root.Free;
    end;
  end;
  LogInfo('telegram: long-poll stopped');
end;

procedure TTelegramChannel.RequestStop;
begin
  FStop := True;
end;

end.
