{
  PasClaw.Tools.Types - shared types for the tools registry.
  Mirrors the Tool interface in pkg/tools/registry.go.
}
unit PasClaw.Tools.Types;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { Handler signature: receives a raw JSON argument blob and returns a string
    that becomes the tool_result content. The handler may set Err to a non-empty
    string to signal a recoverable error to the model. }
  TToolHandler = function(const ArgsJSON: string; out ErrMsg: string): string;

  TTool = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON schema (parameters) }
    Handler:     TToolHandler;
    IsCore:      Boolean;
  end;

  TToolList = array of TTool;

implementation

end.
