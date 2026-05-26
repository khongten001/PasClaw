{
  PasClaw.Providers.HTTP - small wrapper around TFPHTTPClient that posts
  JSON, attaches auth headers, and returns the body or a classified error.
  Used by the Anthropic and OpenAI providers.
}
unit PasClaw.Providers.HTTP;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes,
  fphttpclient, opensslsockets;

type
  THTTPResult = record
    StatusCode: Integer;
    Body:       string;
    ErrorMsg:   string;
  end;

  THeaderPair = record
    Name, Value: string;
  end;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
function MakeHeader(const Name, Value: string): THeaderPair;

implementation

function MakeHeader(const Name, Value: string): THeaderPair;
begin
  Result.Name  := Name;
  Result.Value := Value;
end;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
var
  Client: TFPHTTPClient;
  Req, Resp: TStringStream;
  i: Integer;
begin
  Result.StatusCode := 0;
  Result.Body := '';
  Result.ErrorMsg := '';

  Client := TFPHTTPClient.Create(nil);
  Req    := TStringStream.Create(JSON);
  Resp   := TStringStream.Create('');
  try
    Client.RequestHeaders.Clear;
    Client.AddHeader('Content-Type', 'application/json');
    Client.AddHeader('Accept', 'application/json');
    for i := 0 to High(Headers) do
      Client.AddHeader(Headers[i].Name, Headers[i].Value);
    Client.RequestBody := Req;
    Client.IOTimeout   := TimeoutSeconds * 1000;
    Client.ConnectTimeout := TimeoutSeconds * 1000;
    try
      Client.HTTPMethod('POST', URL, Resp, []);
      Result.StatusCode := Client.ResponseStatusCode;
      Result.Body := Resp.DataString;
    except
      on E: Exception do
      begin
        Result.ErrorMsg   := E.Message;
        Result.StatusCode := Client.ResponseStatusCode;
        Result.Body       := Resp.DataString;
      end;
    end;
  finally
    Resp.Free;
    Req.Free;
    Client.Free;
  end;
end;

end.
