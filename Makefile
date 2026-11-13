.PHONY: mac-office test test-ui

OFFICE_BUNDLE_ID ?= local.codex-office
export OFFICE_BUNDLE_ID
export OFFICE_RELEASE_REPO
OFFICE_TARGET = $(shell uname -m)-apple-macosx12.0
ZSTD_DIR = mac-office/Collector/Zstd
ZSTD_OBJECT = build/zstddeclib-$(shell uname -m).o
COLLECTOR_SOURCES = $(wildcard mac-office/Collector/*.swift)
COLLECTOR_FLAGS = -I $(ZSTD_DIR) -lsqlite3
OFFICE_SOURCES = mac-office/OfficeApplication.swift mac-office/OfficeChrome.swift mac-office/OfficeReleaseCheck.swift mac-office/UsageDetailWindow.swift mac-office/TokenMeter.swift $(COLLECTOR_SOURCES)
SWIFT_FLAGS = -swift-version 6 -O -parse-as-library -target "$(OFFICE_TARGET)" -module-cache-path build/swift-module-cache

mac-office: $(ZSTD_OBJECT)
	@test -f mac-office/Resources/office.html
	@mkdir -p build/swift-module-cache
	@set -eu; \
		stage=$$(mktemp -d build/codex-office.XXXXXXXX); \
		trap 'rm -rf "$$stage"' EXIT; \
		bundle="$$stage/Codex Office.app"; \
		mkdir -p "$$bundle/Contents/MacOS"; \
		xcrun --sdk macosx swiftc $(SWIFT_FLAGS) $(COLLECTOR_FLAGS) \
			$(OFFICE_SOURCES) "$(ZSTD_OBJECT)" \
			-o "$$bundle/Contents/MacOS/CodexOffice"; \
		cp mac-office/Info.plist "$$bundle/Contents/Info.plist"; \
		plutil -replace CFBundleIdentifier -string "$$OFFICE_BUNDLE_ID" "$$bundle/Contents/Info.plist"; \
		if revision=$$(git rev-parse --short=8 HEAD 2>/dev/null); then \
			plutil -insert OfficeSourceRevision -string "$$revision" "$$bundle/Contents/Info.plist"; \
		fi; \
		if [ -n "$${OFFICE_RELEASE_REPO:-}" ]; then \
			plutil -insert OfficeReleaseRepository -string "$$OFFICE_RELEASE_REPO" "$$bundle/Contents/Info.plist"; \
		fi; \
		ditto mac-office/Resources "$$bundle/Contents/Resources"; \
		cp "$(ZSTD_DIR)/LICENSE" "$$bundle/Contents/Resources/Zstandard-LICENSE.txt"; \
		codesign --force --sign - "$$bundle"; \
		rm -rf "build/Codex Office.app"; \
		mv "$$bundle" "build/Codex Office.app"
	@printf '%s\n' 'Built build/Codex Office.app'

$(ZSTD_OBJECT): $(ZSTD_DIR)/zstddeclib.c
	@mkdir -p build
	xcrun --sdk macosx clang -target "$(OFFICE_TARGET)" -O2 -c "$<" -o "$@"

test: $(ZSTD_OBJECT)
	@mkdir -p build/swift-module-cache
	@set -eu; \
		stage=$$(mktemp -d build/office-test.XXXXXXXX); \
		trap 'rm -rf "$$stage"' EXIT; \
		xcrun --sdk macosx swiftc $(SWIFT_FLAGS) $(COLLECTOR_FLAGS) \
			$(COLLECTOR_SOURCES) "$(ZSTD_OBJECT)" tests/CollectorProbe.swift -o "$$stage/CollectorProbe"; \
		OFFICE_TEST_PROBE="$$PWD/$$stage/CollectorProbe" /usr/bin/python3 -B -m unittest discover -s tests -v; \
		xcrun --sdk macosx swiftc $(SWIFT_FLAGS) \
			mac-office/Collector/OfficeData.swift mac-office/Collector/DesktopAttention.swift \
			tests/DesktopAttentionTest.swift -o "$$stage/DesktopAttentionTest"; \
		"$$stage/DesktopAttentionTest"

test-ui: $(ZSTD_OBJECT)
	@mkdir -p build/swift-module-cache
	@set -eu; \
		stage=$$(mktemp -d build/office-ui-test.XXXXXXXX); \
		trap 'rm -rf "$$stage"' EXIT; \
		xcrun --sdk macosx swiftc $(SWIFT_FLAGS) $(COLLECTOR_FLAGS) -D OFFICE_UI_TEST \
			$(OFFICE_SOURCES) "$(ZSTD_OBJECT)" \
			tests/OfficeUITest.swift -o "$$stage/OfficeUITest"; \
		"$$stage/OfficeUITest" mac-office/Resources "$$stage"
