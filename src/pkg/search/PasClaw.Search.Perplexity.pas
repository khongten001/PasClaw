(*
  PasClaw.Search.Perplexity - Perplexity Sonar API adapter.

  Perplexity is a search-grounded LLM, not a traditional results
  endpoint — the API returns a SYNTHESISED answer plus a flat list
  of citation URLs. The adapter maps that into ISearchProvider's
  uniform shape by treating the answer text as the first "hit"
  (title = "Perplexity answer", URL = first citation if any,
  snippet = the synthesised text truncated to the snippet budget)
  and each subsequent citation as a bare URL result the model can
  web_fetch for more detail.

  Endpoint: POST https://api.perplexity.ai/chat/completions
  Headers:  Authorization: Bearer <key>
            Content-Type:  application/json
  Body:     { "model": "sonar",
              "messages": [ { "role": "user", "content": "<query>" } ],
              "max_tokens": 1024 }
  Response: { "choices": [ { "message":
                { "content": "<answer>", "role": "assistant" } } ],
              "citations": [ "https://...", ... ] }

  Docs: https://docs.perplexity.ai/api-reference/chat-completions
*)
unit PasClaw.Search.Perplexity;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Search.Types;

function NewPerplexityProvider(const APIKey: string): ISearchProvider;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

const
  PPLX_MODEL        = 'sonar';
  PPLX_MAX_TOKENS   = 1024;
  ANSWER_SNIPPET_MAX = 1200;   { keep the synthesised answer readable }

type
  TPerplexityProvider = class(TInterfacedObject, ISearchProvider)
  private
    FAPIKey: string;
  public
    constructor Create(const APIKey: string);
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

constructor TPerplexityProvider.Create(const APIKey: string);
begin
  inherited Create;
  FAPIKey := APIKey;
end;

function TPerplexityProvider.Name: string;
begin
  Result := 'perplexity';
end;

function TPerplexityProvider.Search(const Query: string; Count: Integer;
                                     out Hits: TSearchResultArray;
                                     out ErrMsg: string): Boolean;
var
  Root, Msg: TJsonObject;
  ChoiceObj, Req, Item: TJsonObject;
  MsgsReq, ChoicesArr, Citations: TJsonArray;
  Body, Content, FirstURL, Citation: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  i, N, CitedCap: Integer;
begin
  SetLength(Hits, 0);
  ErrMsg := '';
  Result := False;

  if FAPIKey = '' then
  begin
    ErrMsg := 'perplexity: missing API key (set $PASCLAW_PERPLEXITY_API_KEY)';
    Exit;
  end;

  Req := TJsonObject.Create;
  try
    Req.PutStr('model',      PPLX_MODEL);
    Req.PutInt('max_tokens', PPLX_MAX_TOKENS);
    MsgsReq := TJsonArray.Create;
    Msg := TJsonObject.Create;
    Msg.PutStr('role',    'user');
    Msg.PutStr('content', Query);
    MsgsReq.AddObject(Msg);
    Req.PutArray('messages', MsgsReq);
    Body := Req.ToJSON;
  finally
    Req.Free;
  end;

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FAPIKey);

  Resp := PostJSON('https://api.perplexity.ai/chat/completions', Body, Headers, 30);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('perplexity: status=%d body=%s',
                     [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;

  Root := nil;
  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      ErrMsg := 'perplexity: bad JSON: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then begin ErrMsg := 'perplexity: empty JSON'; Exit; end;

  Content := '';
  FirstURL := '';
  try
    ChoicesArr := Root.ChildArray('choices');
    if ChoicesArr <> nil then
    try
      if ChoicesArr.Count > 0 then
      begin
        ChoiceObj := ChoicesArr.ItemObject(0);
        if ChoiceObj <> nil then
        try
          Msg := ChoiceObj.ChildObject('message');
          if Msg <> nil then
          try
            Content := Msg.GetStr('content', '');
          finally
            Msg.Free;
          end;
        finally
          ChoiceObj.Free;
        end;
      end;
    finally
      ChoicesArr.Free;
    end;

    Citations := Root.ChildArray('citations');
    if Citations <> nil then
    try
      if (Content <> '') and (Citations.Count > 0) then
        FirstURL := Citations.ItemStr(0, '');

      { Result[0] = synthesised answer.
        Result[1..N-1] = citations beyond the first. }
      N := 0;
      if Content <> '' then
      begin
        SetLength(Hits, 1);
        Hits[0].Title := 'Perplexity answer';
        Hits[0].URL   := FirstURL;
        if Length(Content) > ANSWER_SNIPPET_MAX then
          Hits[0].Snippet := Copy(Content, 1, ANSWER_SNIPPET_MAX) + ' …(truncated)'
        else
          Hits[0].Snippet := Content;
        N := 1;
      end;

      CitedCap := Citations.Count;
      if Content <> '' then Dec(CitedCap);   { first citation already in Hits[0] }
      if CitedCap < 0 then CitedCap := 0;
      if N + CitedCap > Count then CitedCap := Count - N;

      if CitedCap > 0 then
      begin
        SetLength(Hits, N + CitedCap);
        for i := 0 to CitedCap - 1 do
        begin
          { Skip the first one if it already lives in Hits[0]. }
          if Content <> '' then
            Citation := Citations.ItemStr(i + 1, '')
          else
            Citation := Citations.ItemStr(i,     '');
          Hits[N + i].Title   := '(citation)';
          Hits[N + i].URL     := Citation;
          Hits[N + i].Snippet := '';
        end;
      end;
    finally
      Citations.Free;
    end;

    if (Content = '') and (Length(Hits) = 0) then
      LogWarn('perplexity: response had neither content nor citations (body=%s)',
              [Copy(Resp.Body, 1, 200)]);
  finally
    Root.Free;
  end;

  Result := True;
end;

function NewPerplexityProvider(const APIKey: string): ISearchProvider;
begin
  Result := TPerplexityProvider.Create(APIKey);
end;

end.
