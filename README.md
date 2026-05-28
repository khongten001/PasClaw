# PasClaw

PasClaw is a Delphi Object Pascal port of PicoClaw —
Sipeed's ultra-lightweight personal AI agent. It targets Free Pascal 3.2+ in
`{$MODE DELPHI}` so the same sources build with both FPC and Delphi RAD Studio.

The port is being done in phases. Phase 1 (this commit) ships the full
command-tree skeleton; subsequent phases fill in real provider, MCP, gateway,
cron, skills, and channel implementations.

## Build

### With Free Pascal (Linux / Windows)

```
sudo apt install fpc fp-units-misc       # Free Pascal 3.2+, includes iconvenc
make get-indy                            # clones IndySockets/Indy → vendor/Indy
make                                     # produces build/pasclaw
make smoke                               # runs every top-level command
```

The HTTP client/server, Telegram channel, and any forthcoming socket-based
adapter all go through Indy — the same units build under Delphi without
any source changes.

### With Delphi / RAD Studio

Open `src/pasclaw/PasClaw.dpr`. Add the following to the project search path:
`src/cmd`, `src/pkg/cliui`, `src/pkg/utils`, `src/pkg/logger`,
`src/pkg/config`, `src/pkg/providers`, `src/pkg/tokenizer`, `src/pkg/tools`,
`src/pkg/mcp`, `src/pkg/gateway`, `src/pkg/channels`. Indy ships with RAD
Studio so no vendoring is needed.

> **JSON note:** Phase 1-5 use FPC's `fpjson`. The Delphi port will swap that
> for `System.JSON` (Delphi 10.4+) or `JsonDataObjects` via a thin abstraction
> unit — flagged for the next phase.

## Usage

```
pasclaw onboard                            # initialise ~/.pasclaw + config.json
pasclaw agent -m "hello"                   # one-shot chat (real LLM)
pasclaw agent                              # interactive chat with tools + MCP
pasclaw tui                                # full-screen TUI chat
pasclaw gateway                            # HTTP API + web UI on 127.0.0.1:8088
pasclaw gateway --telegram --token <TOK>   # API + Telegram bot
pasclaw gateway --addr 0.0.0.0 --port 8088
pasclaw status
pasclaw mcp list | mcp add <name> <cmd> [args] | mcp test <name>
pasclaw cron list|add|disable|enable|remove
pasclaw skills list|install|remove
pasclaw model show|set <name>
pasclaw post discord|slack <webhook-url> "<content>"
pasclaw membench [--records N] [--content N]
pasclaw update [--check] [--repo owner/name]
pasclaw auth login|logout|status <provider>
pasclaw version
```

The gateway exposes:

| Route          | Method | Body / Returns                              |
|----------------|--------|---------------------------------------------|
| `/v1/health`   | GET    | `{status, version}`                         |
| `/v1/version`  | GET    | `{version, build}`                          |
| `/v1/status`   | GET    | counts of providers, tools, MCP servers     |
| `/v1/tools`    | GET    | registered tool descriptors                 |
| `/v1/chat`     | POST   | `{message}` ⇒ `{content, iterations, …}`    |

Globals: `--no-color` (or `NO_COLOR=1`) disables ANSI styling.
`PASCLAW_HOME` overrides the home directory (default `~/.pasclaw`).
`PASCLAW_CONFIG` overrides the config path.

## Layout

```
src/
  pasclaw/          program entry (PasClaw.dpr)
  cmd/              one unit per CLI subcommand
  pkg/
    cliui/          colour, banner, panel rendering
    config/         on-disk JSON config + version constants
    logger/         levelled logging
    utils/          path / string / file helpers
```

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | CLI skeleton, banner, config, command dispatch         | ✅ done |
| 2 | Anthropic + OpenAI HTTP clients (Indy), tokenizer      | ✅ done |
| 3 | Tool registry + built-in tools (fs/shell) + tool loop  | ✅ done |
| 4 | MCP stdio client + bridge into tools registry          | ✅ done |
| 5 | Indy gateway (TIdHTTPServer) + Telegram long-poll bot  | ✅ done |
| 6 | JSON abstraction, additional channels (Discord/Slack)  | ✅ done |
| 7 | Cron scheduler, skills loader, memory store            | ✅ done |
| 8 | MCP over HTTP/SSE, SSE-streaming helper, web UI        | ✅ done |
| 9 | Self-update (GitHub releases), membench, TUI front-end | ✅ done |

License: MIT (see LICENSE).
