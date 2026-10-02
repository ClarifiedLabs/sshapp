SHELL := /bin/bash

VERSION ?=
SKIP_TESTS ?=
DRY_RUN ?=
AUTOPUSH ?= 0
RELEASE ?= ./tools/release.py
XCODEBUILD ?= xcodebuild
XCODE_PROJECT ?= SSHApp.xcodeproj
XCODE_SCHEME ?= SSHApp
XCODE_DESTINATION ?=
XCODE_SOURCE_PACKAGES_PATH ?= .build/ci/xcode-source-packages
XCODE_DERIVED_DATA_PATH ?= .build/ci/xcode-derived-data
XCODE_RESULT_BUNDLE_PATH ?= .build/ci/xcresults
TEST_SIMULATOR_NAME ?= SSHApp Tests
ALL_TEST_PLAN ?= SSHAppAllTests
UNIT_TEST_PLAN ?= SSHAppUnitTests
UI_TEST_PLAN ?= SSHAppUITests
LIVE_SSH_SIMULATOR_NAME ?= SSHApp Live SSH Smoke

.PHONY: all setup submodules libssh2 libssh2-host-test ghostty-vt build test test-unit test-ui test-device test-live-ssh clean clean-libssh2 clean-ghostty-vt release release-list test-release test-native-framework-build help

all: setup ## Build everything (submodules + all frameworks)

setup: submodules libssh2 ghostty-vt ## Init submodules and build all frameworks

submodules: ## Initialize and update git submodules
	# Non-recursive on purpose: OpenSSL's own test/fuzz/interop submodules
	# aren't needed to build the libraries (we configure with no-tests), and
	# libssh2/Ghostty have none. Ghostty is large, so fetch only its pinned
	# commit: `shallow = true` alone clones the branch tip at depth 1 and then
	# fetches a non-tip pin with full history; an explicit --depth 1 fetches
	# the pinned SHA itself.
	git submodule update --init --depth 1 -- vendor/ghostty
	git submodule update --init

libssh2: submodules ## Build libssh2 + OpenSSL when provenance inputs changed
	./scripts/build-libssh2.sh

libssh2-host-test: submodules ## Run the focused patched-libssh2 banner callback test
	./scripts/test-libssh2-banner-callback.sh

ghostty-vt: submodules ## Package libghostty-vt slices as GhosttyVT.xcframework when inputs changed
	./scripts/build-ghostty-vt.sh

build: setup ## Build the app for the default simulator
	$(XCODEBUILD) -resolvePackageDependencies -project "$(XCODE_PROJECT)"
	destination="$(XCODE_DESTINATION)"; \
	if [ -z "$$destination" ]; then destination="$$(python3 ./scripts/resolve-ios-simulator.py)"; fi; \
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "$(XCODE_SCHEME)" -destination "$$destination" build

test: setup ## Build once, then run unit and UI tests on one clean dedicated simulator
	mkdir -p "$(XCODE_SOURCE_PACKAGES_PATH)" "$(XCODE_DERIVED_DATA_PATH)" "$(XCODE_RESULT_BUNDLE_PATH)"
	$(XCODEBUILD) -resolvePackageDependencies \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-clonedSourcePackagesDirPath "$$PWD/$(XCODE_SOURCE_PACKAGES_PATH)" \
		-derivedDataPath "$$PWD/$(XCODE_DERIVED_DATA_PATH)" \
		-skipPackagePluginValidation
	PROJECT="$(XCODE_PROJECT)" \
		SCHEME="$(XCODE_SCHEME)" \
		XCODEBUILD="$(XCODEBUILD)" \
		XCODE_DESTINATION="$(XCODE_DESTINATION)" \
		XCODE_SOURCE_PACKAGES_PATH="$(XCODE_SOURCE_PACKAGES_PATH)" \
		XCODE_DERIVED_DATA_PATH="$(XCODE_DERIVED_DATA_PATH)" \
		XCODE_RESULT_BUNDLE_PATH="$(XCODE_RESULT_BUNDLE_PATH)" \
		TEST_SIMULATOR_NAME="$(TEST_SIMULATOR_NAME)" \
		ALL_TEST_PLAN="$(ALL_TEST_PLAN)" \
		UNIT_TEST_PLAN="$(UNIT_TEST_PLAN)" \
		UI_TEST_PLAN="$(UI_TEST_PLAN)" \
		./scripts/run-ios-tests.sh all

test-unit: setup ## Run unit tests on a clean dedicated simulator
	mkdir -p "$(XCODE_SOURCE_PACKAGES_PATH)" "$(XCODE_DERIVED_DATA_PATH)" "$(XCODE_RESULT_BUNDLE_PATH)"
	$(XCODEBUILD) -resolvePackageDependencies \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-clonedSourcePackagesDirPath "$$PWD/$(XCODE_SOURCE_PACKAGES_PATH)" \
		-derivedDataPath "$$PWD/$(XCODE_DERIVED_DATA_PATH)" \
		-skipPackagePluginValidation
	PROJECT="$(XCODE_PROJECT)" \
		SCHEME="$(XCODE_SCHEME)" \
		XCODEBUILD="$(XCODEBUILD)" \
		XCODE_DESTINATION="$(XCODE_DESTINATION)" \
		XCODE_SOURCE_PACKAGES_PATH="$(XCODE_SOURCE_PACKAGES_PATH)" \
		XCODE_DERIVED_DATA_PATH="$(XCODE_DERIVED_DATA_PATH)" \
		XCODE_RESULT_BUNDLE_PATH="$(XCODE_RESULT_BUNDLE_PATH)" \
		TEST_SIMULATOR_NAME="$(TEST_SIMULATOR_NAME)" \
		ALL_TEST_PLAN="$(ALL_TEST_PLAN)" \
		UNIT_TEST_PLAN="$(UNIT_TEST_PLAN)" \
		UI_TEST_PLAN="$(UI_TEST_PLAN)" \
		./scripts/run-ios-tests.sh unit

test-ui: setup ## Run UI tests on a dedicated erased simulator unless XCODE_DESTINATION is set
	mkdir -p "$(XCODE_SOURCE_PACKAGES_PATH)" "$(XCODE_DERIVED_DATA_PATH)" "$(XCODE_RESULT_BUNDLE_PATH)"
	$(XCODEBUILD) -resolvePackageDependencies \
		-project "$(XCODE_PROJECT)" \
		-scheme "$(XCODE_SCHEME)" \
		-clonedSourcePackagesDirPath "$$PWD/$(XCODE_SOURCE_PACKAGES_PATH)" \
		-derivedDataPath "$$PWD/$(XCODE_DERIVED_DATA_PATH)" \
		-skipPackagePluginValidation
	PROJECT="$(XCODE_PROJECT)" \
		SCHEME="$(XCODE_SCHEME)" \
		XCODEBUILD="$(XCODEBUILD)" \
		XCODE_DESTINATION="$(XCODE_DESTINATION)" \
		XCODE_SOURCE_PACKAGES_PATH="$(XCODE_SOURCE_PACKAGES_PATH)" \
		XCODE_DERIVED_DATA_PATH="$(XCODE_DERIVED_DATA_PATH)" \
		XCODE_RESULT_BUNDLE_PATH="$(XCODE_RESULT_BUNDLE_PATH)" \
		TEST_SIMULATOR_NAME="$(TEST_SIMULATOR_NAME)" \
		ALL_TEST_PLAN="$(ALL_TEST_PLAN)" \
		UNIT_TEST_PLAN="$(UNIT_TEST_PLAN)" \
		UI_TEST_PLAN="$(UI_TEST_PLAN)" \
		./scripts/run-ios-tests.sh ui

test-device: setup ## Run isolated physical-device tests (requires DEVICE_UDID)
	./scripts/run-device-tests.py

test-live-ssh: setup ## Run the opt-in live SSH smoke test on a disposable iPad simulator
	PROJECT="$(XCODE_PROJECT)" \
		SCHEME="$(XCODE_SCHEME)" \
		XCODEBUILD="$(XCODEBUILD)" \
		XCODE_DESTINATION="$(XCODE_DESTINATION)" \
		XCODE_SOURCE_PACKAGES_PATH="$(XCODE_SOURCE_PACKAGES_PATH)" \
		XCODE_DERIVED_DATA_PATH="$(XCODE_DERIVED_DATA_PATH)" \
		UI_TEST_PLAN="$(UI_TEST_PLAN)" \
		LIVE_SSH_SIMULATOR_NAME="$(LIVE_SSH_SIMULATOR_NAME)" \
		./scripts/run-live-ssh-smoke-test.sh

clean: clean-libssh2 clean-ghostty-vt ## Remove all built frameworks
	rm -rf Frameworks/GhosttyKit.xcframework build-ghostty

clean-libssh2: ## Remove libssh2/OpenSSL xcframeworks
	rm -rf Frameworks/libssh2.xcframework Frameworks/libcrypto.xcframework Frameworks/libssl.xcframework build-libssh2

clean-ghostty-vt: ## Remove GhosttyVT xcframework
	rm -rf Frameworks/GhosttyVT.xcframework build-ghostty-vt Packages/SSHAppGhostty/Sources/CGhosttyVT/include/ghostty

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
	@tools/tests/test-device-runner.py
	@tools/tests/test-xcode-resolution.py
	@tools/tests/test-ios-simulator-resolution.py
	@tools/tests/test-test-workflow.py
	@tools/tests/test-deploy-workflow.py
	@python3 tools/tests/test-ipa-validation.py
	@python3 tools/tests/test-libssh2-cache.py
	@tools/tests/test-native-framework-build.py
	@python3 tools/tests/test-ghostty-vt-native-build.py

test-native-framework-build: ## Run native framework build recipe regression tests
	@tools/tests/test-native-framework-build.py

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
