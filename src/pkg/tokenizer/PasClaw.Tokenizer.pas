{
  PasClaw.Tokenizer - rough token-count estimator. Mirrors pkg/tokenizer
  in picoclaw: a 4-chars-per-token heuristic, sufficient for budgeting
  and context-window math without shipping a full BPE table.
}
unit PasClaw.Tokenizer;

{$MODE DELPHI}
{$H+}

interface

function EstimateTokens(const Text: string): Integer;
function EstimateMessagesTokens(const Texts: array of string): Integer;

implementation

function EstimateTokens(const Text: string): Integer;
var
  L: Integer;
begin
  L := Length(Text);
  if L = 0 then Exit(0);
  Result := (L + 3) div 4;
end;

function EstimateMessagesTokens(const Texts: array of string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Texts) do
    Result := Result + EstimateTokens(Texts[i]) + 4;  { 4 tokens per message envelope }
end;

end.
