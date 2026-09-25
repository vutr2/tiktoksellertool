# ListingForge - terminal workflow (VS Code friendly).
#
# The Xcode project is GENERATED from ios/project.yml, so every build target
# runs `xcodegen` first. Without it a .swift file you created in VS Code is
# invisible to xcodebuild and fails with "cannot find X in scope".
#
# Override the simulator:  make run DEVICE='iPhone 17 Pro'

DEVICE  ?= iPhone 17
SCHEME  := ListingForge
PROJECT := ios/ListingForge.xcodeproj
BUNDLE  := com.ctt.listingforge
DEST    := platform=iOS Simulator,name=$(DEVICE)
LOG     := /tmp/listingforge-test.log

.PHONY: help gen build test run shot api clean devices i18n

help:
	@echo "make build    - regenerate project + compile for the simulator"
	@echo "make test     - run the 40 unit tests + UI test"
	@echo "make run      - build, boot the simulator, install and launch"
	@echo "make i18n     - check every user-facing string has a Vietnamese translation"
	@echo "make shot     - screenshot the booted simulator to sim.png"
	@echo "make api      - start the Next.js backend on :3000"
	@echo "make devices  - list available simulators"
	@echo "make clean    - remove build artefacts"
	@echo ""
	@echo "Current DEVICE = $(DEVICE)"

gen:
	@cd ios && xcodegen generate >/dev/null

build: gen
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -quiet build

test: gen
	@set -o pipefail; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' test 2>&1 \
	  | tee $(LOG) \
	  | grep -E '✔ Suite|✘|error:|Test run with|Executed [0-9]+ test|\*\* TEST' || true
	@grep -q '\*\* TEST SUCCEEDED \*\*' $(LOG) || { echo "Full log: $(LOG)"; exit 1; }

# Reads the keys the compiler emitted during the build, so a string added
# without a translation is caught before a seller reads it mid-screen.
i18n: build
	@OBJECTS="$$(dirname "$$(find $$HOME/Library/Developer/Xcode/DerivedData -name 'AuthView.stringsdata' \
	  -path '*Debug-iphonesimulator*' 2>/dev/null | grep -v Index.noindex | head -1)")"; \
	python3 ios/scripts/check_localization.py \
	  --catalog ios/ListingForge/Resources/Localizable.xcstrings --objects "$$OBJECTS"

run: build
	@xcrun simctl boot "$(DEVICE)" 2>/dev/null || true
	@open -a Simulator
	@APP="$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
	         -showBuildSettings 2>/dev/null \
	         | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/$(SCHEME).app"; \
	 test -d "$$APP" || { echo "App not found at $$APP"; exit 1; }; \
	 xcrun simctl install booted "$$APP" && \
	 xcrun simctl launch booted $(BUNDLE)

shot:
	@xcrun simctl io booted screenshot sim.png && echo "-> sim.png"

api:
	@cd api && npm run dev

devices:
	@xcrun simctl list devices available | grep -A20 'iOS '

clean:
	@rm -rf ios/build sim.png $(LOG)
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true
	@echo "cleaned"
