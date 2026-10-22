# Developer entry points. `make test` needs only the Swift toolchain; the app targets need Xcode and XcodeGen
# (`make setup`). CI builds unsigned with: make build XCODEBUILD_FLAGS="CODE_SIGNING_ALLOWED=NO"
# `make test-all` runs both test suites: Core's (`make test`) and the app's (`make test-app`).

PROJECT := QuotaRing.xcodeproj
SCHEME := QuotaRing
TEST_SCHEME := QuotaRingAppTests
DERIVED_DATA := build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/QuotaRing.app
XCODEBUILD_FLAGS ?=

.PHONY: setup generate build test test-app test-all lint format run demo clean

setup:
	brew bundle --file=Brewfile

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) build $(XCODEBUILD_FLAGS)

test:
	swift test --package-path Core

# The app's unit tests: a hostless bundle (the app is not started; its sources are compiled into the bundle), so
# no signing is needed and no real Claude file, preference or Keychain item is touched.
test-app: generate
	xcodebuild -project $(PROJECT) -scheme $(TEST_SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) test CODE_SIGNING_ALLOWED=NO $(XCODEBUILD_FLAGS)

test-all: test test-app

lint:
	swift format lint -r --strict Core App AppTests

format:
	swift format format -r -i Core App AppTests

# A running copy is quit first: `open` would otherwise just activate it and silently drop `--demo`. `-n` starts a new
# instance even if the old one has not finished quitting.
run: build
	pkill -x QuotaRing || true
	open -n "$(APP)"

demo: build
	pkill -x QuotaRing || true
	open -n "$(APP)" --args --demo

clean:
	rm -rf build $(PROJECT) Core/.build
