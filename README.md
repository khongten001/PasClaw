# PasClaw

PasClaw is an ultra-lightweight personal AI agent written in Delphi Object Pascal. It is a Delphi/FPC port inspired by [picoclaw](https://github.com/sipeed/picoclaw), with a command-line assistant, tool calling, MCP integration, an HTTP gateway, an OpenAI-compatible API surface, a small embedded web UI, scheduled tasks, skills, and channel integrations.

The main program lives at `src/pasclaw/PasClaw.dpr`. It initializes terminal color handling, prints the banner, applies timezone configuration, and dispatches into the command tree implemented under `src/cmd/`.

## Requirements

- Free Pascal 3.2+ in Delphi mode, or Delphi/RAD Studio.
- Indy (`TIdHTTP`, `TIdHTTPServer`) for HTTP clients, the gateway, and channel integrations.
  - FPC builds vendor Indy with `make get-indy` into `vendor/Indy`.
  - Delphi/RAD Studio ships Indy, so no vendored Indy checkout is required.
- On Debian/Ubuntu FPC systems, install `fp-units-misc` so the `iconvenc` units are available.

## Build

The repository `Makefile` is the authoritative FPC build entry point.

```sh
sudo apt install fpc fp-units-misc
make get-indy
make
```

`make` compiles the embedded web UI resource first and then builds `src/pasclaw/PasClaw.dpr` into `build/pasclaw`:

```sh
make webui-res       # compiles src/pkg/gateway/webui.rc + webui.html to webui.res
make                 # builds build/pasclaw
make run             # builds and runs build/pasclaw
make smoke           # quick top-level command smoke test
make test-hashline   # hashline patch test binary
make test            # smoke + test-hashline
make clean           # removes build/
make print-version   # prints the version Make will inject
```

The Makefile injects `PASCLAW_VERSION` from `git describe --tags --always` when building with FPC. You can override key variables when needed:

```sh
make FPC=/path/to/fpc BUILDDIR=out BIN=out/pasclaw
make INDY_DIR=/path/to/Indy
make ICONVENC_DIR=/path/to/fpc/units/iconvenc
```

### Delphi / RAD Studio

Open `src/pasclaw/PasClaw.dpr` in RAD Studio and add the source directories from `Makefile`'s `UNIT_DIRS` to the project search path:

- `src/pkg/cliui`
- `src/pkg/utils`
- `src/pkg/logger`
- `src/pkg/config`
- `src/pkg/json`
- `src/pkg/providers`
- `src/pkg/tokenizer`
- `src/pkg/tools`
- `src/pkg/mcp`
- `src/pkg/gateway`
- `src/pkg/channels`
- `src/pkg/cron`
- `src/pkg/skills`
- `src/pkg/agent`
- `src/pkg/memory`
- `src/pkg/updater`
- `src/pkg/membench`
- `src/pkg/tui`
- `src/pkg/platform`
- `src/pkg/hashline`
- `src/pkg/component`
- `src/cmd`

For the embedded web UI, compile `src/pkg/gateway/webui.rc` to `src/pkg/gateway/webui.res` with the Delphi resource compiler (`brcc32` or equivalent) before building. The unit `PasClaw.Gateway.WebUI` links `webui.res` with `{$R webui.res}`.

## Configuration

PasClaw stores configuration as JSON. By default:

- Home directory: `~/.pasclaw`
- Config file: `~/.pasclaw/config.json`
- Default provider: `anthropic`
- Default model: `claude-opus-4-7`
- Gateway bind address: `127.0.0.1`
- Gateway port: `8088`
- Gateway log level: `info`

Environment variables:

| Variable | Purpose |
|----------|---------|
| `PASCLAW_HOME` | Overrides the PasClaw home directory. |
| `PASCLAW_CONFIG` | Overrides the config file path. |
| `PASCLAW_VERSION` | Compile-time FPC version override used by the Makefile. |
| `PASCLAW_TELEGRAM_TOKEN` | Default Telegram bot token for `pasclaw gateway --telegram`. |
| `NO_COLOR` | Disables ANSI color output. |

Useful config commands:

```sh
pasclaw onboard       # create/update home, workspace directories, and provider config
pasclaw config        # print current JSON config
pasclaw config path   # print resolved config path
pasclaw config reset  # write a default config
```

## Command surface

Global flags:

```sh
pasclaw --help
pasclaw --no-color status
NO_COLOR=1 pasclaw status
```

Top-level commands are dispatched by `src/cmd/PasClaw.Cmd.Root.pas`:

| Command | Purpose |
|---------|---------|
| `config` | View or reset the JSON configuration. |
| `onboard` | Initialize `PASCLAW_HOME`, workspace folders, and provider settings. |
| `agent` | Chat with the assistant from the terminal. |
| `tui` | Chat in the full-screen TUI. |
| `auth` | Store, clear, or inspect provider API keys. |
| `gateway` | Start the full HTTP gateway, embedded web UI, cron scheduler, tools, MCP, and optional Telegram channel. |
| `serve` | Start the OpenAI-compatible API server surface. |
| `status` | Show provider, model, gateway, MCP, cron, and skill status. |
| `cron` | Manage scheduled tasks. |
| `mcp` | Manage MCP server entries. |
| `migrate` | Run data migrations for older versions. |
| `skills` | List, install, or remove skill extensions. |
| `model` | Show or change the default model. |
| `post` | Send a one-shot message to Discord or Slack webhooks. |
| `membench` | Benchmark the memory log subsystem. |
| `update` | Check GitHub releases or self-update. |
| `version` | Print version/build information. |

### Chat and UI

```sh
pasclaw agent
pasclaw agent -m "hello"
pasclaw agent --model claude-opus-4-7 --provider anthropic -m "summarize this repo"
pasclaw agent --system "Be concise" --thinking medium --max-tokens 2048 --max-iterations 25
pasclaw agent --no-tools --no-mcp --no-hashline

pasclaw tui
pasclaw tui --provider openai --model gpt-4o-mini
pasclaw tui --no-tools --no-mcp --no-hashline
```

### Provider authentication and model selection

```sh
pasclaw auth status
pasclaw auth login anthropic
pasclaw auth logout anthropic
pasclaw auth weixin

pasclaw model show
pasclaw model set claude-opus-4-7
pasclaw model add openai gpt-4o-mini
```

`auth login` prompts for an API key and stores it in the matching provider entry. `model set` changes `default_model`; `model add` upserts a provider entry and records a model for that provider.

### MCP servers

```sh
pasclaw mcp list
pasclaw mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp
pasclaw mcp add remote https://example.com/mcp
pasclaw mcp show filesystem
pasclaw mcp test filesystem
pasclaw mcp remove filesystem
pasclaw mcp edit
```

MCP entries are stored in the config as `mcp_servers`. A command starting with `http://` or `https://` is tested with the HTTP MCP client; other commands are spawned with the stdio MCP client.

### Cron and skills

```sh
pasclaw cron list
pasclaw cron add daily-summary "0 9 * * *" summarize "workspace/memory"
pasclaw cron disable daily-summary
pasclaw cron enable daily-summary
pasclaw cron remove daily-summary

pasclaw skills list
pasclaw skills install ./my-skill
pasclaw skills remove my-skill
```

Skills are discovered from `workspace/skills` under `PASCLAW_HOME` and can be registered in config with `skills install`.

### Gateway, OpenAI-compatible server, and channels

```sh
pasclaw gateway
pasclaw gateway --addr 0.0.0.0 --port 8088
pasclaw gateway --telegram --token <BOT_TOKEN>
pasclaw gateway --no-tools --no-mcp --no-hashline

pasclaw serve
pasclaw serve --addr 0.0.0.0 --port 8088
pasclaw serve --debug
pasclaw serve --max-iter 40
pasclaw serve --no-tools --no-mcp --no-hashline
```

Both commands use the same `TGatewayServer` implementation. `gateway` starts the full surface and can also run the Telegram long-poll channel. `serve` is a focused wrapper for OpenAI-compatible clients and prints copy-pasteable client configuration.

OpenAI-compatible client example:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8088/v1", api_key="sk-pasclaw")
response = client.chat.completions.create(
    model="claude-opus-4-7",
    messages=[{"role": "user", "content": "hello"}],
)
print(response.choices[0].message.content)
```

Curl examples:

```sh
curl http://127.0.0.1:8088/v1/health
curl http://127.0.0.1:8088/v1/tools
curl http://127.0.0.1:8088/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello"}'
curl http://127.0.0.1:8088/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hello"}]}'
```

The gateway routes implemented in `src/pkg/gateway/` are:

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | `GET` | Embedded single-page web UI from `src/pkg/gateway/webui.html`. |
| `/v1` | `GET` | JSON index listing gateway routes. |
| `/v1/health` | `GET` | Health check with PasClaw version. |
| `/v1/version` | `GET` | Version and build metadata. |
| `/v1/status` | `GET` | Default provider/model plus provider, MCP, cron, skill, and tool counts. |
| `/v1/tools` | `GET` | Registered tool descriptors. |
| `/v1/chat` | `POST` | PasClaw JSON chat endpoint accepting `{"message":"..."}`. |
| `/v1/chat/completions` | `POST` | OpenAI Chat Completions-compatible endpoint; supports streaming with `stream: true`. |
| `/v1/models` | `GET` | OpenAI-compatible model list containing the configured default model. |

Channel posting commands:

```sh
pasclaw post discord <webhook-url> "hello"
pasclaw post slack <webhook-url> "hello"
```

### Maintenance and diagnostics

```sh
pasclaw status
pasclaw version
pasclaw migrate
pasclaw update --check
pasclaw update --repo owner/name
pasclaw membench --records 1000 --content 128
pasclaw membench --records 1000 --content 128 --keep --out /tmp
```

## Providers

Provider definitions live in `src/pkg/providers/PasClaw.Providers.Catalog.pas`. `pasclaw onboard` uses the catalog to populate provider `kind`, default API base URL, default model, and auth scheme.

Implemented protocol families:

- `pfAnthropic`: Anthropic Messages API using `x-api-key`.
- `pfOpenAI`: OpenAI Chat Completions-compatible HTTP API. This powers OpenAI and most compatible hosted/local providers.
- `pfGemini`: Google Gemini `generateContent` REST API using `x-goog-api-key`.
- `pfPlaceholder`: catalog placeholder for known future provider families that are not wired into this build.

Auth schemes:

- `asBearer`: `Authorization: Bearer <key>`.
- `asNone`: no auth header, used for local Ollama/vLLM deployments.
- `asHeader`: raw key in the catalog-specified header name.

Current catalog entries:

| Provider | `kind` | Family | Default base | Default model | Auth |
|----------|--------|--------|--------------|---------------|------|
| Anthropic | `anthropic` | Anthropic | `https://api.anthropic.com` | `claude-opus-4-7` | `x-api-key` header |
| OpenAI | `openai` | OpenAI-compatible | `https://api.openai.com` | `gpt-4o-mini` | Bearer |
| OpenRouter | `openrouter` | OpenAI-compatible | `https://openrouter.ai/api` | provider-selected | Bearer |
| Zhipu (GLM) | `zhipu` | OpenAI-compatible | `https://open.bigmodel.cn/api/paas` | `glm-4` | Bearer |
| DeepSeek | `deepseek` | OpenAI-compatible | `https://api.deepseek.com` | `deepseek-chat` | Bearer |
| Volcengine (Doubao/Ark) | `volcengine` | OpenAI-compatible | `https://ark.cn-beijing.volces.com/api` | provider-selected | Bearer |
| Qwen (DashScope) | `qwen` | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode` | `qwen-max` | Bearer |
| Groq | `groq` | OpenAI-compatible | `https://api.groq.com/openai` | provider-selected | Bearer |
| Moonshot (Kimi) | `moonshot` | OpenAI-compatible | `https://api.moonshot.cn` | `moonshot-v1-32k` | Bearer |
| MiniMax | `minimax` | OpenAI-compatible | `https://api.minimax.chat` | provider-selected | Bearer |
| Mistral | `mistral` | OpenAI-compatible | `https://api.mistral.ai` | `mistral-large-latest` | Bearer |
| NVIDIA NIM | `nvidia` | OpenAI-compatible | `https://integrate.api.nvidia.com` | provider-selected | Bearer |
| Cerebras | `cerebras` | OpenAI-compatible | `https://api.cerebras.ai` | provider-selected | Bearer |
| Novita AI | `novita` | OpenAI-compatible | `https://api.novita.ai` | provider-selected | Bearer |
| Xiaomi MiMo | `mimo` | OpenAI-compatible | set `api_base` in config | provider-selected | Bearer |
| Ollama (local) | `ollama` | OpenAI-compatible | `http://localhost:11434` | required during onboarding | none |
| vLLM (local) | `vllm` | OpenAI-compatible | `http://localhost:8000` | required during onboarding | none |
| LiteLLM proxy | `litellm` | OpenAI-compatible | set `api_base` in config | provider-selected | Bearer |
| Google Gemini | `gemini` | Gemini | `https://generativelanguage.googleapis.com` | `gemini-1.5-flash` | `x-goog-api-key` header |

Minimal local provider examples:

```json
{
  "default_provider": "ollama",
  "default_model": "llama3.1:8b",
  "gateway": { "log_level": "info", "bind_addr": "127.0.0.1", "port": 8088 },
  "providers": [
    {
      "name": "ollama",
      "kind": "ollama",
      "api_base": "http://localhost:11434",
      "api_key": "",
      "model": "llama3.1:8b"
    }
  ],
  "mcp_servers": [],
  "crons": [],
  "skills": []
}
```

```json
{
  "default_provider": "vllm",
  "default_model": "your-model",
  "gateway": { "log_level": "info", "bind_addr": "127.0.0.1", "port": 8088 },
  "providers": [
    {
      "name": "vllm",
      "kind": "vllm",
      "api_base": "http://localhost:8000",
      "api_key": "",
      "model": "your-model"
    }
  ],
  "mcp_servers": [],
  "crons": [],
  "skills": []
}
```

## Repository layout

```text
src/
  pasclaw/          Program entry point (`PasClaw.dpr`)
  cmd/              CLI command units and root dispatcher
  pkg/
    agent/          Agent execution and prompts
    channels/       Telegram, Discord, Slack integrations
    cliui/          ANSI styling, banner, command help rendering
    component/      Shared components
    config/         Version constants and on-disk config model
    cron/           Cron scheduler
    gateway/        Indy HTTP server, OpenAI-compatible API, embedded web UI
    hashline/       Hashline patch/edit support
    json/           Project JSON abstraction
    logger/         Levelled logging
    mcp/            MCP stdio/HTTP clients and tool bridge
    membench/       Memory benchmark helpers
    memory/         Memory log storage
    platform/       Platform helpers
    providers/      Provider catalog and LLM HTTP clients
    skills/         Skill manifest loading and tool registration
    tokenizer/      Token counting helpers
    tools/          Built-in tool registry, filesystem, shell, and tool loop
    tui/            Full-screen terminal UI
    updater/        GitHub release update support
    utils/          Path, file, and string helpers
```

## License

MIT. See `LICENSE`.
