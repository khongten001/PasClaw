{
  PasClaw.MCP.Types - Model Context Protocol types.
  MCP uses JSON-RPC 2.0 over stdio (this Phase) or HTTP/SSE (next phase).

  Spec: https://modelcontextprotocol.io/specification
}
unit PasClaw.MCP.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

const
  MCPProtocolVersion = '2024-11-05';
  JSONRPCVersion     = '2.0';

type
  TMCPTool = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON-encoded inputSchema }
    Server:      string;   { display name of the host server, for routing }
  end;

  TMCPToolArray = array of TMCPTool;

  TMCPCapabilities = record
    Tools:     Boolean;
    Resources: Boolean;
    Prompts:   Boolean;
  end;

  TMCPServerInfo = record
    Name:    string;
    Version: string;
    Caps:    TMCPCapabilities;
  end;

  (* Common base for stdio and HTTP MCP clients. The bridge keeps a list
     of these and dispatches tool calls polymorphically. *)
  TMCPBaseClient = class
  protected
    FInfo: TMCPServerInfo;
  public
    function Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean; virtual; abstract;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean; virtual; abstract;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean; virtual; abstract;
    property ServerInfo: TMCPServerInfo read FInfo;
  end;

implementation

end.
