# Developer entry points. `make test` needs only the Swift toolchain; the app targets need Xcode and XcodeGen
# (`make setup`). CI builds unsigned with: make build XCODEBUILD_FLAGS="CODE_SIGNING_ALLOWED=NO"

PROJECT := QuotaRing.xcodeproj
SCHEME := QuotaRing
DERIVED_DATA := build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/QuotaRing.app
XCODEBUILD_FLAGS ?=

.PHONY: setup generate build test lint format run demo clean

setup:
	brew bundle --file=Brewfile

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) build $(XCODEBUILD_FLAGS)

test:
	swift test --package-path Core

lint:
	swift format lint -r --strict Core App

format:
	swift format format -r -i Core App

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
