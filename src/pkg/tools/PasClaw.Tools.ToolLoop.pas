{
  PasClaw.Tools.ToolLoop - the core agent loop. Repeatedly calls the LLM
  with the running message history; if the response contains tool_calls,
  dispatches each through the registry, appends the tool result as a tool
  message, and continues. Mirrors pkg/tools/toolloop.go.
}
unit PasClaw.Tools.ToolLoop;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TToolLoopConfig = record
    Provider:      ILLMProvider;
    Registry:      TToolRegistry;
    Model:         string;
    MaxIterations: Integer;
    Options:       TChatOptions;
    OnText:        procedure(const S: string) of object;   { streaming-ish stdout }
    OnToolCall:    procedure(const Name, ArgsJSON: string) of object;
    OnToolResult:  procedure(const Name, ResultText, Err: string) of object;
  end;

  TToolLoopResult = record
    Content:     string;
    Iterations:  Integer;
    LastResp:    TLLMResponse;
  end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;

implementation

uses
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Hashline;

function IsPatchFormatError(const Err: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Err);
  Result := (Pos('patch parse:', L) > 0) or
            (Pos('patch preflight:', L) > 0) or
            (Pos('unsupported inline payload token', L) > 0);
end;

function NormalizePatchForCompare(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if (C <> #13) and (C <> #10) and (C <> #9) and (C <> ' ') then
      Result[i] := C
    else
      Result[i] := #0;
  end;
  Result := StringReplace(Result, #0, '', [rfReplaceAll]);
end;

function CanonicalizeHashlinePatch(const Patch: string;
                                   out Canonical: string;
                                   out HasUnsupportedTokens: Boolean): Boolean;
var
  Sections: THLSectionArray;
  ParseErr: string;
  i, j: Integer;
  E: THLEdit;
  Sb: TStringBuilder;
begin
  Canonical := '';
  HasUnsupportedTokens := False;
  if not ParseHashlinePatch(Patch, Sections, ParseErr) then Exit(False);
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Sections) do
    begin
      if i > 0 then Sb.Append(#10);
      if Sections[i].HasFileHash then
        Sb.Append(FormatHashlineHeader(Sections[i].Path, Sections[i].FileHash))
      else
        Sb.Append(HL_FILE_PREFIX + Sections[i].Path);
      Sb.Append(#10);
      for j := 0 to High(Sections[i].Edits) do
      begin
        E := Sections[i].Edits[j];
        Sb.Append(IntToStr(E.Anchor.LineNum)).Append(HL_LINE_BODY_SEP).Append(#10);
        case E.PayloadKind of
          hpkReplace: Sb.Append(HL_PAYLOAD_REPLACE);
          hpkAbove:   Sb.Append(HL_PAYLOAD_ABOVE);
          hpkBelow:   Sb.Append(HL_PAYLOAD_BELOW);
        else
          HasUnsupportedTokens := True;
          Sb.Append(HL_PAYLOAD_REPLACE);
        end;
        Sb.Append(E.Text).Append(#10);
      end;
    end;
    Canonical := Sb.ToString;
  finally
    Sb.Free;
  end;
  Result := True;
end;

function PreflightToolCall(const Name, ArgsJSON: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Patch, VErr: string;
begin
  Result := True;
  Err := '';
  if Name <> 'fs_edit_hashline' then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then
  begin
    Err := 'invalid JSON arguments for fs_edit_hashline';
    Exit(False);
  end;
  try
    Patch := Obj.GetStr('patch', '');
  finally
    Obj.Free;
  end;
  if Patch = '' then Exit;
  if not ValidateHashlinePatchGrammar(Patch, VErr) then
  begin
    Err := 'patch preflight: ' + VErr + ' (remediation: regenerate patch with ¶path#hash header, anchor line like "N:" or "N-M:", then payload lines prefixed by |/↑/↓ only)';
    Exit(False);
  end;
end;

function MakeAssistantWithToolCalls(const Content: string;
                                    const Calls: array of TToolCall): TMessage;
var
  i: Integer;
begin
  Result.Role       := mrAssistant;
  Result.Content    := Content;
  Result.Name       := '';
  Result.ToolCallId := '';
  SetLength(Result.ToolCalls, Length(Calls));
  for i := 0 to High(Calls) do Result.ToolCalls[i] := Calls[i];
end;

function MakeToolResult(const ToolCallId, Content: string): TMessage;
begin
  Result := MakeMessage(mrTool, Content);
  Result.ToolCallId := ToolCallId;
end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;
var
  Iter, i: Integer;
  Tools: TToolDefinitionArray;
  Resp: TLLMResponse;
  Hist: array of TMessage;
  ResultText, Err, RetryArgs, Patch, CanonicalPatch, N1, N2: string;
  ArgsObj: TJsonObject;
  HasUnsup: Boolean;
begin
  Loop.Content    := '';
  Loop.Iterations := 0;

  if Cfg.Provider = nil then Exit(False);

  { Copy input messages to a growable history. }
  SetLength(Hist, Length(Messages));
  for i := 0 to High(Messages) do Hist[i] := Messages[i];

  if Cfg.Registry <> nil then
    Tools := Cfg.Registry.ToProviderDefs
  else
    SetLength(Tools, 0);

  Iter := 0;
  while Iter < Cfg.MaxIterations do
  begin
    Inc(Iter);
    LogDebug('toolloop iteration %d / %d', [Iter, Cfg.MaxIterations]);

    Resp := Cfg.Provider.Chat(Hist, Tools, Cfg.Model, Cfg.Options);
    Loop.LastResp := Resp;

    { Stream the text part to the caller now so they can show progress. }
    if Assigned(Cfg.OnText) and (Resp.Content <> '') then
      Cfg.OnText(Resp.Content);

    if Length(Resp.ToolCalls) = 0 then
    begin
      Loop.Content    := Resp.Content;
      Loop.Iterations := Iter;
      Exit(True);
    end;

    { Append the assistant turn (text + tool calls) and dispatch each call. }
    SetLength(Hist, Length(Hist) + 1);
    Hist[High(Hist)] := MakeAssistantWithToolCalls(Resp.Content, Resp.ToolCalls);

    for i := 0 to High(Resp.ToolCalls) do
    begin
      if Assigned(Cfg.OnToolCall) then
        Cfg.OnToolCall(Resp.ToolCalls[i].Func.Name, Resp.ToolCalls[i].Func.Arguments);

      Err := '';
      ResultText := '';
      RetryArgs := Resp.ToolCalls[i].Func.Arguments;
      if not PreflightToolCall(Resp.ToolCalls[i].Func.Name, RetryArgs, Err) then
        ResultText := ''
      else if Cfg.Registry <> nil then
        ResultText := Cfg.Registry.RunTool(Resp.ToolCalls[i].Func.Name, RetryArgs, Err)
      else
        Err := 'no tool registry';

      if (Resp.ToolCalls[i].Func.Name = 'fs_edit_hashline') and IsPatchFormatError(Err) then
      begin
        LogWarn('tool-retry attempt=1 strategy=raw_hashline normalized_patch_len=%d has_unsupported_tokens=%s class=format_error',
          [Length(NormalizePatchForCompare(RetryArgs)), BoolToStr(False, True)]);
        ArgsObj := TJsonObject.Parse(RetryArgs);
        Patch := '';
        if ArgsObj <> nil then
        begin
          try
            Patch := ArgsObj.GetStr('patch', '');
          finally
            ArgsObj.Free;
          end;
        end;
        if (Patch <> '') and CanonicalizeHashlinePatch(Patch, CanonicalPatch, HasUnsup) then
        begin
          ArgsObj := TJsonObject.Create;
          try
            ArgsObj.Put('patch', CanonicalPatch);
            RetryArgs := ArgsObj.Stringify;
          finally
            ArgsObj.Free;
          end;
          N1 := NormalizePatchForCompare(Patch);
          N2 := NormalizePatchForCompare(CanonicalPatch);
          LogWarn('tool-retry attempt=2 strategy=strict_hashline_formatter normalized_patch_len=%d has_unsupported_tokens=%s class=format_error',
            [Length(N2), BoolToStr(HasUnsup, True)]);
          Err := '';
          if not PreflightToolCall(Resp.ToolCalls[i].Func.Name, RetryArgs, Err) then
            ResultText := ''
          else if Cfg.Registry <> nil then
            ResultText := Cfg.Registry.RunTool(Resp.ToolCalls[i].Func.Name, RetryArgs, Err)
          else
            Err := 'no tool registry';
          if IsPatchFormatError(Err) and (N1 = N2) then
            Err := 'format_error: deterministic fallback exhausted; two consecutive retries had equivalent normalized patch content. ' +
                   'Regenerate patch intent or use safer apply-patch/unified-diff edit path.';
        end
        else
          Err := 'format_error: unable to canonicalize patch for deterministic retry; regenerate patch intent or use safer apply-patch/unified-diff edit path. original=' + Err;
      end;

      if Assigned(Cfg.OnToolResult) then
        Cfg.OnToolResult(Resp.ToolCalls[i].Func.Name, ResultText, Err);

      SetLength(Hist, Length(Hist) + 1);
      if Err <> '' then
        Hist[High(Hist)] := MakeToolResult(Resp.ToolCalls[i].Id, 'ERROR: ' + Err)
      else
        Hist[High(Hist)] := MakeToolResult(Resp.ToolCalls[i].Id, ResultText);
    end;
  end;

  { Max iterations exhausted; return whatever we last got. }
  Loop.Content    := Resp.Content;
  Loop.Iterations := Iter;
  Result := True;
end;

end.
