.PHONY: build test run app run-app run-release clean cli install-cli web

BUNDLE_NAME = KanbanCode.app
BUNDLE_DIR = build/$(BUNDLE_NAME)
BUNDLE_ID = com.kanban-code.app
VERSION ?= 0.1.1
CONFIG ?= debug
ARCH := $(shell uname -m)
BUILD_DIR = .build/$(ARCH)-apple-macosx/$(CONFIG)

build:
	swift build

test:
	swift test

run:
	swift run KanbanCode

app: build cli install-cli web
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	@mkdir -p $(BUNDLE_DIR)/Contents/Resources
	@cp $(BUILD_DIR)/KanbanCode $(BUNDLE_DIR)/Contents/MacOS/KanbanCode
	@# Active session marker app (detected by Amphetamine etc.)
	@mkdir -p $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/MacOS
	@cp $(BUILD_DIR)/kanban-code-active-session $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/MacOS/kanban-code-active-session
	@/bin/echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>kanban-code-active-session</string><key>CFBundleIdentifier</key><string>com.kanban-code.active-session</string><key>CFBundleName</key><string>kanban-code-active-session</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$(VERSION)</string><key>LSUIElement</key><true/></dict></plist>' > $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/Info.plist
	@codesign --force --sign - $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app 2>/dev/null || true
	@cp Sources/KanbanCode/Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>KanbanCode</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>Kanban Code</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundlePackageType</key><string>APPL</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSMinimumSystemVersion</key><string>14.0</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>NSHighResolutionCapable</key><true/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSUIElement</key><false/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconFile</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconName</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.kanban-code</string><key>CFBundleURLSchemes</key><array><string>kanbancode</string></array></dict></array>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '</dict></plist>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@# Copy SPM bundle resources
	@if [ -d $(BUILD_DIR)/KanbanCode_KanbanCode.bundle ]; then \
		cp -R $(BUILD_DIR)/KanbanCode_KanbanCode.bundle $(BUNDLE_DIR)/Contents/Resources/; \
	fi
	@# Bundle the kanban CLI inside the app so it's always available.
	@# cloudflared is NOT bundled — the bundled copy gets quarantined by
	@# macOS Gatekeeper (unsigned-by-us origin binary), which then breaks
	@# its outbound network. `npx -y cloudflared` fetches & caches it under
	@# ~/.npm/_npx/ where it runs without the quarantine xattr.
	@# Ship only runtime artifacts:
	@#  • dist/*.js (compiled TypeScript) minus *.test.js
	@#  • package.json + lockfile so npm can reinstall deterministically
	@#  • a PROD-only node_modules (no typescript/tsx/esbuild/@types/supertest —
	@#    those are ~50 MB of dev-time tooling that has no business shipping)
	@rm -rf $(BUNDLE_DIR)/Contents/Resources/cli
	@mkdir -p $(BUNDLE_DIR)/Contents/Resources/cli/dist
	@find cli/dist -maxdepth 1 -type f \
		\( -name '*.js' -o -name '*.d.ts' \) \
		! -name '*.test.js' ! -name '*.test.d.ts' \
		-exec cp {} $(BUNDLE_DIR)/Contents/Resources/cli/dist/ \;
	@cp cli/package.json cli/package-lock.json $(BUNDLE_DIR)/Contents/Resources/cli/
	@cd $(BUNDLE_DIR)/Contents/Resources/cli && npm ci --omit=dev --ignore-scripts --silent --no-audit --no-fund
	@# Bundle the built web client — served by the share-server at `/`.
	@rm -rf $(BUNDLE_DIR)/Contents/Resources/share-web
	@cp -R web/dist $(BUNDLE_DIR)/Contents/Resources/share-web
	@# Code sign so macOS grants notification permissions and Web Inspector can attach
	@codesign --force --sign - --entitlements KanbanCode.entitlements $(BUNDLE_DIR)
	@# Register with Launch Services so macOS picks up the icon
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR) 2>/dev/null || true
	@echo "Built $(BUNDLE_DIR)"

run-app: app
	open $(BUNDLE_DIR)

run-release:
	swift build -c release
	@$(MAKE) app CONFIG=release
	KANBAN_WATCHDOG=1 build/$(BUNDLE_NAME)/Contents/MacOS/KanbanCode

cli:
	@cd cli && npm install --silent && npm run build

web:
	@cd web && npm install --silent && npm run build


install-cli: cli
	@mkdir -p $(HOME)/.local/bin
	@printf '#!/bin/sh\nexec node "$(CURDIR)/cli/dist/kanban.js" "$$@"\n' > $(HOME)/.local/bin/kanban
	@chmod 755 $(HOME)/.local/bin/kanban
	@echo "Installed kanban CLI to ~/.local/bin/kanban"

clean:
	swift package clean
	rm -rf build
