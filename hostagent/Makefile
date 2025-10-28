tail -n 200 ~/Library/Logs/Haven/hostagent.log || tail -n 200 /tmp/hostagent_run.log.PHONY: build test clean install uninstall run dev release help

# Default target
help:
	@echo "Haven Host Agent - Make targets:"
	@echo "  build      - Build debug version"
	@echo "  release    - Build release version"
	@echo "  test       - Run tests"
	@echo "  clean      - Clean build artifacts"
	@echo "  install    - Install to /usr/local/bin"
	@echo "  uninstall  - Remove from /usr/local/bin"
	@echo "  run        - Run debug version (auto-detects dev mode)"
	@echo "  dev        - Run with auto-reload (requires entr, auto-detects dev mode)"
	@echo "  dev-setup  - Set up development mode (copy chat.db to ~/.haven)"
	@echo "  launchd    - Install and start LaunchAgent"
	@echo "  unlaunchd  - Stop and uninstall LaunchAgent"

# Build debug version
build:
	arch -x86_64 swift build

# Build release version
release:
	arch -x86_64 swift build -c release

# Run tests
test:
	arch -x86_64 swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build

# Install binary to system
install: release
	@echo "Installing hostagent to /usr/local/bin..."
	@sudo cp .build/release/hostagent /usr/local/bin/
	@sudo chmod +x /usr/local/bin/hostagent
	@echo "Creating config directory..."
	@mkdir -p ~/.haven
	@if [ ! -f ~/.haven/hostagent.yaml ]; then \
		cp Resources/default-config.yaml ~/.haven/hostagent.yaml; \
		echo "Created default config at ~/.haven/hostagent.yaml"; \
		echo "⚠️  IMPORTANT: Edit this file and change the auth secret!"; \
	fi
	@echo "Installation complete!"

# Reset config to default (create ~/.haven if needed, backup existing)
reset-config:
	@echo "Resetting hostagent config to default..."
	@mkdir -p ~/.haven
	@if [ -f ~/.haven/hostagent.yaml ]; then \
		cp ~/.haven/hostagent.yaml ~/.haven/hostagent.yaml.bak && \
		echo "Existing config backed up to ~/.haven/hostagent.yaml.bak"; \
	fi
	@cp Resources/default-config.yaml ~/.haven/hostagent.yaml
	@chmod 600 ~/.haven/hostagent.yaml || true
	@echo "Default config written to ~/.haven/hostagent.yaml"

# Uninstall binary
uninstall:
	@echo "Removing hostagent from /usr/local/bin..."
	@sudo rm -f /usr/local/bin/hostagent
	@echo "Uninstall complete (config preserved at ~/.haven/)"

# Run debug version (with dev mode if ~/.haven/chat.db exists)
run: build
	@if [ -f ~/.haven/chat.db ]; then \
		echo "📋 Development mode: using ~/.haven/chat.db"; \
		export HAVEN_IMESSAGE_CHAT_DB_PATH=~/.haven/chat.db && ./.build/debug/hostagent; \
	else \
		./.build/debug/hostagent; \
	fi

# Development mode with auto-reload (requires entr)
dev:
	@if ! command -v entr > /dev/null; then \
		echo "Error: entr not found. Install with: brew install entr"; \
		exit 1; \
	fi
	@if [ -f ~/.haven/chat.db ]; then \
		echo "📋 Development mode: using ~/.haven/chat.db"; \
		export HAVEN_IMESSAGE_CHAT_DB_PATH=~/.haven/chat.db && find Sources -name '*.swift' | entr -r sh -c 'export HAVEN_IMESSAGE_CHAT_DB_PATH=~/.haven/chat.db && ./.build/debug/hostagent'; \
	else \
		find Sources -name '*.swift' | entr -r make run; \
	fi

# Set up development mode (copy chat.db to ~/.haven)
dev-setup:
	@echo "🏠 Haven Host Agent - Development Mode Setup"
	@echo "============================================="
	@echo ""
	@if [ -f ~/.haven/chat.db ]; then \
		echo "✅ Development mode already set up"; \
		echo "   ~/.haven/chat.db exists"; \
		echo ""; \
		echo "To refresh the copy:"; \
		echo "  1. Close Messages app (to release database locks)"; \
		echo "  2. Run: rm ~/.haven/chat.db && make dev-setup"; \
	else \
		if [ -f ~/Library/Messages/chat.db ]; then \
			mkdir -p ~/.haven; \
			echo "📋 Copying chat.db to ~/.haven/chat.db..."; \
			echo "   Note: Using nolock mode, so WAL files not required"; \
			cp ~/Library/Messages/chat.db ~/.haven/chat.db && \
			chmod 644 ~/.haven/chat.db && \
			echo "✅ Development mode setup complete!" && \
			echo "" && \
			echo "File copied: $$(du -h ~/.haven/chat.db | cut -f1)" && \
			echo "" && \
			echo "ℹ️  The copy is opened with 'nolock' mode, so missing WAL files are OK"; \
			echo "" && \
			echo "Now run: make run or make dev"; \
		else \
			echo "❌ System chat.db not found at ~/Library/Messages/chat.db"; \
			echo ""; \
			echo "You may need to:"; \
			echo "  1. Grant Full Disk Access to Terminal"; \
			echo "  2. Use Messages app to create message history"; \
		fi \
	fi

# Install and start LaunchAgent
launchd: install
	@echo "Setting up LaunchAgent..."
	@mkdir -p ~/Library/Logs/Haven
	@sed "s/YOUR_USER/$(USER)/g" Resources/LaunchAgents/com.haven.hostagent.plist > ~/Library/LaunchAgents/com.haven.hostagent.plist
	@launchctl unload ~/Library/LaunchAgents/com.haven.hostagent.plist 2>/dev/null || true
	@launchctl load ~/Library/LaunchAgents/com.haven.hostagent.plist
	@echo "LaunchAgent installed and started"
	@echo "View logs: tail -f ~/Library/Logs/Haven/hostagent.log"
	@echo "Control: launchctl {start|stop|restart} com.haven.hostagent"

# Stop and uninstall LaunchAgent
unlaunchd:
	@echo "Stopping and removing LaunchAgent..."
	@launchctl unload ~/Library/LaunchAgents/com.haven.hostagent.plist 2>/dev/null || true
	@rm -f ~/Library/LaunchAgents/com.haven.hostagent.plist
	@echo "LaunchAgent removed"

# Check health
health:
	@curl -s http://localhost:7090/v1/health | jq . || echo "Agent not running or jq not installed"

# Check capabilities (requires auth)
capabilities:
	@curl -s -H "x-auth: changeme" http://localhost:7090/v1/capabilities | jq . || echo "Failed (check auth token)"

# Format code (requires swift-format)
format:
	@if command -v swift-format > /dev/null; then \
		swift-format -i -r Sources Tests; \
	else \
		echo "swift-format not found. Install with: brew install swift-format"; \
	fi

# Lint code
lint:
	@if command -v swiftlint > /dev/null; then \
		swiftlint; \
	else \
		echo "swiftlint not found. Install with: brew install swiftlint"; \
	fi
