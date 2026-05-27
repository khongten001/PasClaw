# PasClaw Delphi Port Sanity Review (2026-05-27)

Scope: fast static review of portability, runtime correctness, and maintainability hot spots after Go→Object Pascal port.

## Overall assessment

- **Build status in this environment**: could not verify full compile due missing FPC toolchain (`fpcres` not installed).
- **Code quality**: generally clean structure and readable unit boundaries.
- **Risk level**: **medium** (several correctness/compatibility edge cases to address before trusting production behavior).

## Findings

### 1) JSON object setters can create duplicate keys on FPC backend (High)

In `TJsonObject.PutStr/PutInt/PutBool/PutFloat/PutObject/PutArray/PutRaw`, the FPC backend uses `fpjson.TJSONObject.Add(...)` directly.

`Add` appends a new field and does not replace existing fields with the same key. Repeated writes to the same key can generate duplicate keys and ambiguous semantics across parsers.

**Impact**
- Inconsistent behavior between FPC and Delphi backend if Delphi path replaces keys.
- Potentially invalid assumptions in downstream consumers expecting last-write-wins or unique keys.

**Suggested fix**
- Implement a `ReplaceOrAdd` helper for FPC backend: delete existing key if present, then add new value.

### 2) Delphi support claims vs current MCP stdio implementation mismatch (Medium)

README advertises major phases complete, but `PasClaw.MCP.StdioClient` header states Delphi build has stubs and does not support stdio MCP process spawning yet.

**Impact**
- Feature expectations mismatch for Delphi users.
- Risk of runtime confusion during integration tests.

**Suggested fix**
- Either implement Delphi `CreateProcess`/POSIX spawn shim now, or mark README/CLI help explicitly with current limitations.

### 3) Argument splitting for spawned MCP process is simplistic (Medium)

`SplitArgs` handles basic quotes but not escapes, nested quoting, platform-specific commandline parsing rules, or backslash escaping.

**Impact**
- MCP servers with paths/args containing escaped quotes or complex flags may fail to launch.

**Suggested fix**
- Prefer structured args in config (array form) instead of shell-like string parsing.
- Or implement a robust cross-platform parser compatible with Delphi/FPC targets.

### 4) Environment-variable build metadata may not be stable (Low)

`make -n` shows `PASCLAW_VERSION='88284e9'` injected into the build command. Verify the Delphi build path receives the same version metadata consistently.

**Suggested fix**
- Centralize version at one source of truth and assert at startup/logging.

## Recommended next verification pass

1. Build matrix:
   - FPC (Linux/Windows)
   - Delphi (target version in CI)
2. Minimal integration tests:
   - JSON round-trip with repeated key updates
   - MCP stdio happy path and malformed response handling
   - gateway `/v1/chat` with tool loop disabled/enabled
3. Add regression tests for any bug fixed above.

