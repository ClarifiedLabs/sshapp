SHELL := /bin/bash

VERSION ?=
SKIP_TESTS ?=
DRY_RUN ?=
AUTOPUSH ?= 0
RELEASE ?= ./tools/release.py

.PHONY: all setup submodules libssh2 clean clean-libssh2 release release-list test-release test-native-framework-build help

all: setup ## Build everything (submodules + all frameworks)

setup: submodules libssh2 ## Init submodules and build all frameworks

submodules: ## Initialize and update git submodules
	git submodule update --init --recursive

libssh2: submodules ## Build libssh2 + OpenSSL xcframeworks
	@if [ -d Frameworks/libssh2.xcframework ]; then \
		echo "libssh2.xcframework already exists, skipping (use 'make clean-libssh2' to rebuild)"; \
	else \
		./scripts/build-libssh2.sh; \
	fi

clean: clean-libssh2 ## Remove all built frameworks

clean-libssh2: ## Remove libssh2/OpenSSL xcframeworks
	rm -rf Frameworks/libssh2.xcframework Frameworks/libcrypto.xcframework Frameworks/libssl.xcframework build-libssh2

release-list: ## List current release tags
	@$(RELEASE) list

release: ## Create a TestFlight release tag (VERSION=patch|minor|major|X.Y.Z)
	@if [ -z "$(VERSION)" ]; then \
		echo "VERSION is required. Use: make release VERSION=<patch|minor|major|X.Y.Z>"; \
		exit 2; \
	fi
	@if [ -z "$(SKIP_TESTS)" ]; then \
		echo "Running release regression tests..."; \
		$(MAKE) --no-print-directory test-release; \
	fi
	@args=(release --version "$(VERSION)"); \
	if [ -n "$(DRY_RUN)" ]; then args+=(--dry-run); fi; \
	if [ "$(AUTOPUSH)" = "1" ]; then args+=(--push); fi; \
	$(RELEASE) "$${args[@]}"

test-release: ## Run release and native build tooling regression tests
	@tools/tests/test-release.py
	@tools/tests/test-deploy-workflow.py
	@tools/tests/test-native-framework-build.py

test-native-framework-build: ## Run native framework build recipe regression tests
	@tools/tests/test-native-framework-build.py

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
