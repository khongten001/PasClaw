# Building PasClaw with Free Pascal

PasClaw builds with Free Pascal (FPC) 3.2 or newer in Delphi mode. The repository `Makefile` is the source of truth for FPC flags, source paths, resource generation, and output locations.

## Requirements

- Free Pascal 3.2+.
- Indy for HTTP client/server units (`TIdHTTP`, `TIdHTTPServer`). FPC builds vendor Indy into `vendor/Indy`.
- On Debian/Ubuntu FPC systems, install `fp-units-misc` so the `iconvenc` units are available. FPC's default configuration finds `iconvenc` on most distributions, but the Makefile also exposes `ICONVENC_DIR` for systems that need an explicit path.

```sh
sudo apt install fpc fp-units-misc
```

## Vendoring Indy

Fetch Indy before the first FPC build:

```sh
make get-indy
```

This clones `IndySockets/Indy` into `vendor/Indy` unless that directory already exists. Override the location with `INDY_DIR=/path/to/Indy` when needed.

## Embedded web UI resource

The gateway embeds `src/pkg/gateway/webui.html` through `src/pkg/gateway/webui.rc`. Compile the resource with:

```sh
make webui-res
```

This produces `src/pkg/gateway/webui.res`, which is linked by `PasClaw.Gateway.WebUI` using `{$R webui.res}`. The default `make` target runs this step before compiling `src/pasclaw/PasClaw.dpr`.

## Build commands

```sh
make                 # compiles webui.res and builds build/pasclaw
make run             # builds and runs build/pasclaw
make smoke           # quick top-level command smoke test
make test-hashline   # hashline patch test binary
make test            # smoke + test-hashline
make clean           # removes build/
make print-version   # prints the version Make will inject
```

The Makefile injects `PASCLAW_VERSION` from `git describe --tags --always` during FPC builds.

## Variable overrides

Override Makefile variables on the command line when needed:

```sh
make FPC=/path/to/fpc BUILDDIR=out BIN=out/pasclaw
make INDY_DIR=/path/to/Indy
make ICONVENC_DIR=/path/to/fpc/units/iconvenc
```

Common variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FPC` | `fpc` | Free Pascal compiler executable. |
| `BUILDDIR` | `build` | Directory for build outputs and compiled units. |
| `BIN` | `$(BUILDDIR)/pasclaw` | Final executable path. |
| `INDY_DIR` | `vendor/Indy` | Vendored Indy checkout used for FPC builds. |
| `ICONVENC_DIR` | `/usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/iconvenc` | Optional explicit `iconvenc` unit path. |

## Windows

On Windows, use `build-fpc.bat` from the repository root after installing FPC 3.2+ and ensuring `fpc.exe` and `fpcres.exe` are on `PATH`:

```bat
build-fpc.bat
```

The batch file compiles `src\pkg\gateway\webui.rc` to `src\pkg\gateway\webui.res` before building `src\pasclaw\PasClaw.dpr`. It mirrors the Makefile's FPC flags and source paths, and supports environment overrides for `FPC`, `BUILDDIR`, `BIN`, `INDY_DIR`, and `ICONVENC_DIR`.
