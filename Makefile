# Common developer tasks. Run `make help` for the list.
SHELL := /bin/bash
PROJECT := SendToAlexa.xcodeproj
DERIVED := build/DerivedData

.PHONY: help setup project test cli build-ios build-macos build icon clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Create Config/Local.xcconfig: make setup TEAM=ABCDE12345 PREFIX=com.yourname
	@test -n "$(TEAM)" || (echo "usage: make setup TEAM=<your Team ID> PREFIX=<com.yourname>"; exit 1)
	@test -n "$(PREFIX)" || (echo "usage: make setup TEAM=<your Team ID> PREFIX=<com.yourname>"; exit 1)
	@printf 'DEVELOPMENT_TEAM = %s\nBUNDLE_ID_PREFIX = %s\n' "$(TEAM)" "$(PREFIX)" > Config/Local.xcconfig
	@echo "Wrote Config/Local.xcconfig — now open $(PROJECT) and run on your iPhone."

project: ## Regenerate the Xcode project from project.yml (needs: brew install xcodegen)
	xcodegen generate

test: ## Run AlexaKit unit tests
	cd AlexaKit && swift test

cli: ## Build the alexa-send CLI (release) into AlexaKit/.build/release/alexa-send
	cd AlexaKit && swift build -c release --product alexa-send
	@echo "→ AlexaKit/.build/release/alexa-send --help"

build-ios: ## Compile the iOS app + share extension for the simulator (no signing needed)
	xcodebuild -project $(PROJECT) -scheme SendToAlexa-iOS -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) -quiet build

build: test build-ios ## Test the core and compile every app target

icon: ## Re-render the app icon from scripts/make-icon.swift
	swift scripts/make-icon.swift iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png

clean: ## Remove build output
	rm -rf build AlexaKit/.build
