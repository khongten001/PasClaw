{
  PasClaw.Providers.Intf - the ILLMProvider interface every provider implements.
  Mirrors the LLMProvider interface in pkg/providers/types.go.
}
unit PasClaw.Providers.Intf;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types;

type
  TStreamCallback = procedure(const Chunk: TStreamChunk) of object;

  ILLMProvider = interface
    ['{6F1E1A1B-7B0E-4B53-B6E3-71D9F1F1A001}']
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

implementation

end.
