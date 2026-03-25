BINARY    := .build/debug/This
BUNDLE_ID := do.this.app
USER_TCC  := $(HOME)/Library/Application Support/com.apple.TCC/TCC.db
APP_PATH  := dist/This.app
DMG_PATH  := dist/This.dmg

.PHONY: build run sign app install dmg grant reset-tcc cert-instructions

# Build and sign (sign only if cert exists)
build:
	swift build
	@BIN_DIR=$$(swift build --show-bin-path 2>/dev/null) && cp Sources/Resources/*.wav "$$BIN_DIR/" 2>/dev/null || true
	@$(MAKE) --no-print-directory sign

sign:
	@IDENTITY="$$(./scripts/detect-signing-identity.sh 2>/dev/null || true)"; \
	if [ -n "$$IDENTITY" ]; then \
		codesign --force --sign "$$IDENTITY" --timestamp=none "$(BINARY)" && \
		echo "Signed with '$$IDENTITY'."; \
	fi

run: build
	"$(BINARY)"

app:
	./scripts/build-app.sh

install:
	./scripts/build-app.sh --install

dmg:
	./scripts/build-dmg.sh

# Create a self-signed code-signing cert via Keychain Access (one-time setup).
cert-instructions:
	@echo ""
	@echo "Create a self-signed code-signing cert (one-time):"
	@echo ""
	@echo "  1. Open Keychain Access"
	@echo "  2. Menu: Keychain Access → Certificate Assistant → Create a Certificate"
	@echo "  3. Name: This Local Development"
	@echo "  4. Identity Type: Self Signed Root"
	@echo "  5. Certificate Type: Code Signing"
	@echo "  6. Click Create"
	@echo ""
	@echo "After that, 'make build' will sign the binary automatically."
	@echo ""
	@open "/System/Library/CoreServices/Applications/Keychain Access.app"

# Write TCC grants directly — no permission dialogs ever.
# Usage: sudo make grant
grant:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Run as: sudo make grant"; exit 1; \
	fi
	@echo "Writing TCC grants for $(BUNDLE_ID)..."
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=UNUSED
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.finder
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.reminders
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.iCal
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.mail
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.Notes
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.Safari
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.Terminal
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.googlecode.iterm2
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.microsoft.VSCode
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAppleEvents   TARGET=com.apple.systempreferences
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceScreenCapture TARGET=UNUSED
	@$(MAKE) --no-print-directory _grant SVC=kTCCServiceAccessibility TARGET=UNUSED
	@echo "Done. Relaunch This — no permission popups."

_grant:
	@sqlite3 "$(USER_TCC)" \
		"INSERT OR REPLACE INTO access \
		 (service, client, client_type, auth_value, auth_reason, auth_version, \
		  indirect_object_identifier, flags, last_modified) \
		 VALUES('$(SVC)', '$(BUNDLE_ID)', 0, 2, 4, 1, '$(TARGET)', 0, \
		  CAST(strftime('%s','now') AS INTEGER));" \
	&& echo "  ✓ $(SVC)$(if $(filter-out UNUSED,$(TARGET)), → $(TARGET))" \
	|| echo "  ✗ $(SVC) failed"

# Clear all TCC grants for this app (useful for testing)
reset-tcc:
	tccutil reset All $(BUNDLE_ID)
	@echo "All TCC grants cleared."
