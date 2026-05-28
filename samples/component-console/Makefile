# Sample build: a standalone FPC binary that embeds TPasClawAgent.
#
# This Makefile re-uses the same unit search paths as the top-level
# PasClaw build (../../Makefile) so the sample stays in sync without
# duplicating the list. Run:
#
#   cd samples/component-console
#   make
#
# The first build needs Indy vendored under ../../vendor/Indy; the
# top-level Makefile's `make get-indy` target handles that. Run it
# once from the repository root before building the sample.

ROOT     := ../..
FPC      ?= fpc
BUILDDIR ?= build
BIN      ?= $(BUILDDIR)/SampleConsole

INDY_DIR     ?= $(ROOT)/vendor/Indy
ICONVENC_DIR ?= /usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/iconvenc

# Every src/pkg/* the main binary uses, re-rooted at $(ROOT).
UNIT_DIRS = \
	$(ROOT)/src/pkg/cliui \
	$(ROOT)/src/pkg/utils \
	$(ROOT)/src/pkg/logger \
	$(ROOT)/src/pkg/config \
	$(ROOT)/src/pkg/json \
	$(ROOT)/src/pkg/providers \
	$(ROOT)/src/pkg/tokenizer \
	$(ROOT)/src/pkg/tools \
	$(ROOT)/src/pkg/mcp \
	$(ROOT)/src/pkg/gateway \
	$(ROOT)/src/pkg/channels \
	$(ROOT)/src/pkg/cron \
	$(ROOT)/src/pkg/skills \
	$(ROOT)/src/pkg/agent \
	$(ROOT)/src/pkg/memory \
	$(ROOT)/src/pkg/updater \
	$(ROOT)/src/pkg/membench \
	$(ROOT)/src/pkg/tui \
	$(ROOT)/src/pkg/platform \
	$(ROOT)/src/pkg/hashline \
	$(ROOT)/src/pkg/component \
	$(ROOT)/src/cmd

INDY_UNIT_DIRS = \
	$(INDY_DIR)/Lib/Core \
	$(INDY_DIR)/Lib/Protocols \
	$(INDY_DIR)/Lib/System

FPCFLAGS = -MDelphi -Sh -O2 -Xs -XX \
	$(foreach d,$(UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fi$(d)) \
	-Fu$(ICONVENC_DIR) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

.PHONY: all clean

all: $(BIN)

$(BIN): SampleConsole.dpr | $(BUILDDIR) $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) SampleConsole.dpr

$(BUILDDIR):
	mkdir -p $@
$(BUILDDIR)/lib:
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
