program gemini_schema_strip_tests;
(*
  Covers SanitizeSchemaForGemini — the wire-boundary scrub that lets
  Gemini accept tool schemas containing additionalProperties (and
  other JSON-Schema-but-not-OpenAPI-3.0 fields) that MCP servers and
  external skill manifests emit.

  Test 1 reproduces the exact 400 shape the user hit and asserts
  the unsupported fields are gone while the legitimate ones survive.

  Test 2 covers Codex P2 on PR #153 — a tool parameter literally
  named "additionalProperties" must NOT be dropped by the walker.
  The original blind-recursion walker treated the `properties` map
  as a schema node and would strip user-defined keys colliding with
  schema keywords. The schema-aware walker only strips on schema
  nodes, never on the properties name->schema map itself.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Gemini;

procedure Fail(const Msg, Body: string);
begin
  WriteLn('FAIL: ' + Msg);
  WriteLn('--- body ---');
  WriteLn(Body);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail(Msg + ' (expected substring: ' + Needle + ')', Haystack);
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail(Msg + ' (did NOT expect substring: ' + Needle + ')', Haystack);
end;

procedure TestRejectedFieldsScrubbed;
const
  { Same shape as the user's reported 400 — additionalProperties at
    two nesting levels plus $schema meta. }
  Bad =
    '{' +
      '"type":"object",' +
      '"properties":{' +
        '"url":{"type":"string"},' +
        '"options":{' +
          '"type":"object",' +
          '"properties":{"timeout":{"type":"integer"}},' +
          '"additionalProperties":false' +
        '}' +
      '},' +
      '"required":["url"],' +
      '"additionalProperties":false,' +
      '"$schema":"http://json-schema.org/draft-07/schema#"' +
    '}';
var
  Out_: string;
begin
  Out_ := SanitizeSchemaForGemini(Bad);
  AssertMissing(Out_, 'additionalProperties', 'additionalProperties stripped');
  AssertMissing(Out_, '$schema',              '$schema stripped');
  AssertContains(Out_, '"url"',               'url property survives');
  AssertContains(Out_, '"timeout"',           'nested timeout survives');
  AssertContains(Out_, '"required"',          'required[] survives');
end;

procedure TestUserPropertyNamedAdditionalPropertiesSurvives;
const
  { Two layers of trickery:
      - A schema KEYWORD additionalProperties at the top level
        (should be stripped).
      - A user PROPERTY literally named additionalProperties inside
        the `properties` map (must NOT be stripped — it's a tool
        parameter name).
      - Same trap for $schema and $ref as user property names. }
  Bad =
    '{' +
      '"type":"object",' +
      '"properties":{' +
        '"additionalProperties":{"type":"boolean","description":"user property"},' +
        '"$schema":{"type":"string"},' +
        '"$ref":{"type":"string"},' +
        '"normal":{"type":"integer"}' +
      '},' +
      '"additionalProperties":false,' +
      '"$schema":"http://json-schema.org/draft-07/schema#"' +
    '}';
var
  Out_: string;
begin
  Out_ := SanitizeSchemaForGemini(Bad);

  { The user PROPERTIES survive even though they share names with
    schema keywords. Match on the description / type tag we put
    inside their schemas — the bare key text "additionalProperties"
    can match either the property name OR the schema keyword, so we
    pin the assertion on a sibling that only exists if the property
    schema was preserved. }
  AssertContains(Out_, '"description" : "user property"',
    'user property named "additionalProperties" survives');
  AssertContains(Out_, '"normal"', 'normal property survives');

  { Top-level schema keywords ARE stripped — we proved that in test 1.
    Here, prove there are no instances of additionalProperties:false
    or $schema as a URL (the keyword forms) left, while accepting
    that "additionalProperties" as a key name in the properties map
    is allowed. }
  AssertMissing(Out_, ':false', 'top-level additionalProperties:false stripped');
  AssertMissing(Out_, 'json-schema.org', '$schema URL keyword stripped');
end;

procedure TestEmptyAndMalformed;
begin
  if SanitizeSchemaForGemini('') <> '' then
    Fail('empty input should round-trip as empty', SanitizeSchemaForGemini(''));
  { Malformed JSON: walker returns input verbatim so Gemini's own
    400 with field pointer surfaces, instead of a silent drop. }
  if SanitizeSchemaForGemini('not json') <> 'not json' then
    Fail('malformed input should round-trip verbatim',
         SanitizeSchemaForGemini('not json'));
end;

begin
  TestRejectedFieldsScrubbed;
  TestUserPropertyNamedAdditionalPropertiesSurvives;
  TestEmptyAndMalformed;
  WriteLn('gemini_schema_strip_tests: OK');
end.
