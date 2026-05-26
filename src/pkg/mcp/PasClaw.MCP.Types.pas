{
  PasClaw.MCP.Types - Model Context Protocol types.
  MCP uses JSON-RPC 2.0 over stdio (this Phase) or HTTP/SSE (next phase).

  Spec: https://modelcontextprotocol.io/specification
}
unit PasClaw.MCP.Types;

{$MODE DELPHI}
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

implementation

end.
