# Makefile for daps2docker
#
# Copyright (C) 2018 SUSE Linux GmbH
#
# Author:
# Stefan Knorr <sknorr@suse.de>
#

ifndef PREFIX_BIN
  PREFIX := /usr/bin
endif
ifndef PREFIX_EXTRA
  PREFIX := /usr/share
endif

SHELL         := /bin/bash
PACKAGE       := daps2docker

CDIR          := $(shell pwd)
BUILD_DIR     := build
CBUILD_DIR    := $(CDIR)/$(BUILD_DIR)

# project version number
VERSION       := 0.10

.PHONY: all dist clean
all: dist

build/%: % $(BUILD_DIR)
	cp $< $@

$(INSTALL_DIR) $(BUILD_DIR):
	@mkdir -p $@

dist: build/daps2docker.sh build/d2d_runner.sh build/defaults build/README.md build/LICENSE
	@tar cfjhP $(PACKAGE)-$(VERSION).tar.bz2 \
	  --transform 's:^$(CBUILD_DIR):$(PACKAGE)-$(VERSION):' \
	  $(CBUILD_DIR)
	@echo "Successfully created $(PACKAGE)-$(VERSION).tar.bz2"


clean:
	@rm -rf $(BUILD_DIR) 2> /dev/null || echo
	@rm $(PACKAGE)-*.tar.bz2 2> /dev/null || echo
	@echo "All deleted."
