# PasClaw - Delphi Object Pascal port of picoclaw
# Builds with Free Pascal (FPC 3.2+, mode Delphi) or Delphi/RAD Studio.
#
# Indy is required for HTTP client/server (TIdHTTP, TIdHTTPServer). Under FPC
# we vendor it via `make get-indy` (clones IndySockets/Indy into vendor/Indy).
# Under Delphi, Indy ships with RAD Studio — no vendoring needed.

FPC      ?= fpc
BUILDDIR ?= build
BIN      ?= $(BUILDDIR)/pasclaw

INDY_DIR     ?= vendor/Indy
INDY_REPO    ?= https://github.com/IndySockets/Indy.git
# iconvenc lives in fp-units-misc on Debian; FPC's default config picks it up
# on most distros but not always.
ICONVENC_DIR ?= /usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/iconvenc

# fcl-db + sqlite ship with FPC's standard distribution but live outside the
# default search path (Debian package: fp-units-db). PasClaw.Memory.Index
# pulls TSQLite3Connection / TSQLQuery from these. libsqlite3.so must be
# present at runtime — every modern Linux/Mac has it; Windows builds need
# sqlite3.dll on PATH.
FCLDB_DIR    ?= /usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/fcl-db
SQLITE_DIR   ?= /usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/sqlite

# PasClaw.Tools.FS uses the Masks unit (case-insensitive glob matching for
# fs_grep's `include` filter). On Debian, Masks lives in Lazarus's lazutils
# source tree rather than the fpc rtl, so callers that don't already have it
# on their unit path can set LAZUTILS_DIR (apt: lazarus-src). Defaults to the
# Debian path; empty string skips the include.
LAZUTILS_DIR ?= /usr/lib/lazarus/3.0/components/lazutils

# PasClaw source dirs.
UNIT_DIRS = \
	src/pkg/cliui \
	src/pkg/utils \
	src/pkg/logger \
	src/pkg/config \
	src/pkg/json \
	src/pkg/providers \
	src/pkg/tokenizer \
	src/pkg/tools \
	src/pkg/mcp \
	src/pkg/gateway \
	src/pkg/channels \
	src/pkg/crypto \
	src/pkg/net \
	src/pkg/search \
	src/pkg/cron \
	src/pkg/skills \
	src/pkg/agent \
	src/pkg/memory \
	src/pkg/updater \
	src/pkg/membench \
	src/pkg/tui \
	src/pkg/platform \
	src/pkg/hashline \
	src/pkg/component \
	src/cmd

# Indy unit + include dirs (only used when building under FPC).
INDY_UNIT_DIRS = \
	$(INDY_DIR)/Lib/Core \
	$(INDY_DIR)/Lib/Protocols \
	$(INDY_DIR)/Lib/System

INDY_INC_DIRS = $(INDY_UNIT_DIRS)

FPCFLAGS = -MDelphi -Sh -O2 -Xs -XX \
	-Fu$(FCLDB_DIR) -Fu$(SQLITE_DIR) \
	$(if $(LAZUTILS_DIR),-Fu$(LAZUTILS_DIR)) \
	$(foreach d,$(UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_INC_DIRS),-Fi$(d)) \
	-Fu$(ICONVENC_DIR) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

.PHONY: all clean run test smoke test-hashline test-toolview print-version get-indy webui-res

all: $(WEBUI_RES) $(BIN)

# Compile the HTML resource into a .res that {$R webui.res} embeds.
WEBUI_RES = src/pkg/gateway/webui.res

webui-res: $(WEBUI_RES)

$(WEBUI_RES): src/pkg/gateway/webui.rc src/pkg/gateway/webui.html
	cd src/pkg/gateway && fpcres -of res -o webui.res webui.rc

$(BIN): $(WEBUI_RES) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	PASCLAW_VERSION='$(VERSION)' $(FPC) $(FPCFLAGS) src/pasclaw/PasClaw.dpr -o$(BIN)

$(INDY_DIR):
	@echo "Indy not found at $(INDY_DIR); run 'make get-indy' to clone it."
	@false

get-indy:
	@if [ ! -d $(INDY_DIR) ]; then \
	  mkdir -p $(dir $(INDY_DIR)); \
	  echo "Cloning Indy into $(INDY_DIR)..."; \
	  git clone --depth 1 $(INDY_REPO) $(INDY_DIR); \
	else \
	  echo "Indy already present at $(INDY_DIR)"; \
	fi

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR)

run: $(BIN)
	@$(BIN)

print-version:
	@echo $(VERSION)

# Quick smoke test that every top-level command at least prints help/status
# without crashing. Useful when adding subcommands.
smoke: $(BIN)
	@PASCLAW_HOME=$$(mktemp -d) ; export PASCLAW_HOME ; \
	echo "smoke: home=$$PASCLAW_HOME" ; \
	NO_COLOR=1 $(BIN) version                  >/dev/null && echo "  version   OK" ; \
	NO_COLOR=1 $(BIN) --help                   >/dev/null && echo "  help      OK" ; \
	NO_COLOR=1 $(BIN) config reset             >/dev/null && echo "  config    OK" ; \
	NO_COLOR=1 $(BIN) status                   >/dev/null && echo "  status    OK" ; \
	NO_COLOR=1 $(BIN) mcp list                 >/dev/null && echo "  mcp       OK" ; \
	NO_COLOR=1 $(BIN) cron list                >/dev/null && echo "  cron      OK" ; \
	NO_COLOR=1 $(BIN) skills list              >/dev/null && echo "  skills    OK" ; \
	NO_COLOR=1 $(BIN) model show               >/dev/null && echo "  model     OK" ; \
	NO_COLOR=1 $(BIN) migrate                  >/dev/null && echo "  migrate   OK" ; \
	NO_COLOR=1 $(BIN) update --check           >/dev/null && echo "  update    OK" ; \
	NO_COLOR=1 $(BIN) membench --records 100   >/dev/null && echo "  membench  OK" ; \
	echo "smoke: all commands OK"

test-hashline: $(WEBUI_RES) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/hashline_patch_tests.pas -o$(BUILDDIR)/hashline_patch_tests
	@$(BUILDDIR)/hashline_patch_tests

# Pure tool-activity formatter tests. No Indy/webui resource needed — the
# ToolView unit only depends on PasClaw.JSON and PasClaw.Hashline.
test-toolview: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/toolview_tests.pas -o$(BUILDDIR)/toolview_tests
	@$(BUILDDIR)/toolview_tests

test: smoke test-hashline test-toolview
