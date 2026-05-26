# PasClaw - Delphi Object Pascal port of picoclaw
# Builds with Free Pascal (FPC 3.2+, mode Delphi).

FPC      ?= fpc
BUILDDIR ?= build
BIN      ?= $(BUILDDIR)/pasclaw

# Unit search paths — every src/pkg/* and src/cmd directory.
UNIT_DIRS = \
	src/pkg/cliui \
	src/pkg/utils \
	src/pkg/logger \
	src/pkg/config \
	src/pkg/providers \
	src/pkg/tokenizer \
	src/pkg/tools \
	src/pkg/mcp \
	src/cmd

FPCFLAGS = -MDelphi -Sh -O2 -Xs -XX \
	$(foreach d,$(UNIT_DIRS),-Fu$(d)) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

.PHONY: all clean run test smoke print-version

all: $(BIN)

$(BIN): | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	PASCLAW_VERSION='$(VERSION)' $(FPC) $(FPCFLAGS) src/pasclaw/PasClaw.dpr -o$(BIN)

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
	NO_COLOR=1 $(BIN) version              >/dev/null && echo "  version  OK" ; \
	NO_COLOR=1 $(BIN) --help               >/dev/null && echo "  help     OK" ; \
	NO_COLOR=1 $(BIN) config reset         >/dev/null && echo "  config   OK" ; \
	NO_COLOR=1 $(BIN) status               >/dev/null && echo "  status   OK" ; \
	NO_COLOR=1 $(BIN) mcp list             >/dev/null && echo "  mcp      OK" ; \
	NO_COLOR=1 $(BIN) cron list            >/dev/null && echo "  cron     OK" ; \
	NO_COLOR=1 $(BIN) skills list          >/dev/null && echo "  skills   OK" ; \
	NO_COLOR=1 $(BIN) model show           >/dev/null && echo "  model    OK" ; \
	NO_COLOR=1 $(BIN) migrate              >/dev/null && echo "  migrate  OK" ; \
	NO_COLOR=1 $(BIN) update               >/dev/null && echo "  update   OK" ; \
	NO_COLOR=1 $(BIN) gateway              >/dev/null && echo "  gateway  OK" ; \
	echo "smoke: all commands OK"

test: smoke
