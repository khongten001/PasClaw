program openai_server_tools_tests;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.OpenAI;

procedure Fail(const Msg, Body: string);
begin
  Writeln('FAIL: ' + Msg);
  Writeln('--- body ---');
  Writeln(Body);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail(Msg + ' (expected to find: ' + Needle + ')', Haystack);
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail(Msg + ' (did NOT expect: ' + Needle + ')', Haystack);
end;

function OneUserMessage(const Text: string): TMessageArray;
begin
  SetLength(Result, 1);
  Result[0] := MakeMessage(mrUser, Text);
end;

function NoUserTools: TToolDefinitionArray;
begin
  SetLength(Result, 0);
end;

procedure TestNoServerTools;
var
  Opts: TChatOptions;
  Body: string;
begin
  Opts := DefaultChatOptions;
  Body := BuildOAIRequest(OneUserMessage('hi'), NoUserTools, 'gpt-4o',
                          Opts, NoOpenAIServerTools);
  { Default flipped to True in #146, but BuildOAIRequest is pure —
    it emits exactly what the caller asks for. NoOpenAIServerTools
    is the "off" sentinel, so the field must not appear. }
  AssertMissing(Body, 'web_search_options', 'no web_search_options when off');
end;

procedure TestServerWebSearchOn;
var
  Opts: TChatOptions;
  Body: string;
  ST: TOpenAIServerTools;
begin
  Opts := DefaultChatOptions;
  ST := NoOpenAIServerTools;
  ST.WebSearch := True;

  Body := BuildOAIRequest(OneUserMessage('hi'), NoUserTools, 'gpt-5-search-api',
                          Opts, ST);
  AssertContains(Body, '"web_search_options"', 'web_search_options field emitted');
  AssertContains(Body, '"model" : "gpt-5-search-api"',
                 'model passed through unchanged (operator picks the search model)');
end;

procedure TestCoexistsWithFunctionTool;
var
  Opts: TChatOptions;
  Body: string;
  ST: TOpenAIServerTools;
  Tools: TToolDefinitionArray;
begin
  { Unlike Anthropic, the server-side web_search isn't in tools[];
    a user-defined function named web_search coexists without 400. }
  Opts := DefaultChatOptions;
  ST := NoOpenAIServerTools;
  ST.WebSearch := True;

  SetLength(Tools, 1);
  Tools[0].Name        := 'web_search';
  Tools[0].Description := 'user-defined search';
  Tools[0].Schema      := '{"type":"object"}';

  Body := BuildOAIRequest(OneUserMessage('hi'), Tools, 'gpt-5-search-api',
                          Opts, ST);
  AssertContains(Body, '"web_search_options"',  'server-side flag still emitted');
  AssertContains(Body, '"name" : "web_search"', 'user function tool not dropped');
  AssertContains(Body, 'user-defined search',   'user description preserved');
end;

begin
  TestNoServerTools;
  TestServerWebSearchOn;
  TestCoexistsWithFunctionTool;
  Writeln('openai_server_tools_tests: OK');
end.
