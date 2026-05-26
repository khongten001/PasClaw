# PasClaw

PasClaw is a Delphi Object Pascal port of [PicoClaw](https://github.com/sipeed/picoclaw) —
Sipeed's ultra-lightweight personal AI agent. It targets Free Pascal 3.2+ in
`{$MODE DELPHI}` so the same sources build with both FPC and Delphi RAD Studio.

The port is being done in phases. Phase 1 (this commit) ships the full
command-tree skeleton; subsequent phases fill in real provider, MCP, gateway,
cron, skills, and channel implementations.

## Build

```
sudo apt install fpc            # Free Pascal 3.2+
make                            # produces build/pasclaw
make smoke                      # runs every top-level command
```

Or with Delphi: open `src/pasclaw/PasClaw.dpr` and add `src/pkg/*` and `src/cmd`
to the search path.

## Usage

```
pasclaw onboard            # initialise ~/.pasclaw + config.json
pasclaw agent -m "hello"   # one-shot chat (Phase 3 wires real provider)
pasclaw agent              # interactive chat
pasclaw gateway            # start the gateway (Phase 4)
pasclaw status             # show effective config
pasclaw mcp list           # list MCP servers
pasclaw mcp add <name> <cmd> [args...]
pasclaw cron list|add|disable|enable|remove
pasclaw skills list|install|remove
pasclaw model show|set <name>
pasclaw auth login|logout|status <provider>
pasclaw version
```

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
| 2 | Anthropic + OpenAI HTTP clients, tokenizer             | ✅ done |
| 3 | Tool registry + built-in tools (fs/shell) + tool loop  | ✅ done |
| 4 | MCP stdio client + bridge into tools registry          | ✅ done |
| 5 | Gateway (fphttpserver), routing, channels (Telegram, Discord) | todo |
| 6 | Cron scheduler, skills loader, memory store            | todo |
| 7 | MCP over HTTP/SSE, streaming responses (true SSE)      | todo |
| 8 | Self-update, web UI launcher, membench tool            | todo |

License: MIT (see LICENSE).
