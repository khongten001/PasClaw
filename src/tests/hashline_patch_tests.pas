program hashline_patch_tests;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Hashline;

procedure Fail(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

procedure TestValidInsertion;
var
  P, Err: string;
  Sections: THLSectionArray;
begin
  P := '¶a.txt#abcd' + #10 + '2:' + #10 + '↑inserted above';
  AssertTrue(ValidateHashlinePatchGrammar(P, Err), 'valid insertion rejected: ' + Err);
  AssertTrue(ParseHashlinePatch(P, Sections, Err), 'valid insertion parse failed: ' + Err);
  AssertTrue(Length(Sections) = 1, 'expected one section for insertion');
end;

procedure TestValidMultilineReplacement;
var
  P, Err: string;
  Sections: THLSectionArray;
begin
  P := '¶b.txt#beef' + #10 + '4-5:' + #10 + '|new line one' + #10 + '|new line two';
  AssertTrue(ValidateHashlinePatchGrammar(P, Err), 'valid replacement rejected: ' + Err);
  AssertTrue(ParseHashlinePatch(P, Sections, Err), 'valid replacement parse failed: ' + Err);
  AssertTrue(Length(Sections) = 1, 'expected one section for replacement');
end;

procedure TestInvalidInlinePayload;
var
  P, Err: string;
begin
  P := '¶c.txt#cafe' + #10 + '60:↓bad inline payload';
  AssertTrue(not ValidateHashlinePatchGrammar(P, Err), 'invalid inline payload accepted');
  AssertTrue(Pos(':↓', Err) > 0, 'expected actionable token in validator error');
end;

begin
  TestValidInsertion;
  TestValidMultilineReplacement;
  TestInvalidInlinePayload;
  Writeln('PASS');
end.
