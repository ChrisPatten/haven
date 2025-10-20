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
	@echo "  run        - Run debug version"
	@echo "  dev        - Run with auto-reload (requires entr)"
	@echo "  launchd    - Install and start LaunchAgent"
	@echo "  unlaunchd  - Stop and uninstall LaunchAgent"

# Build debug version
build:
	swift build

# Build release version
release:
	swift build -c release

# Run tests
test:
	swift test

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

# Uninstall binary
uninstall:
	@echo "Removing hostagent from /usr/local/bin..."
	@sudo rm -f /usr/local/bin/hostagent
	@echo "Uninstall complete (config preserved at ~/.haven/)"

# Run debug version
run: build
	./.build/debug/hostagent

# Development mode with auto-reload (requires entr)
dev:
	@if ! command -v entr > /dev/null; then \
		echo "Error: entr not found. Install with: brew install entr"; \
		exit 1; \
	fi
	@find Sources -name '*.swift' | entr -r make run

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
	@curl -s -H "x-auth: change-me" http://localhost:7090/v1/capabilities | jq . || echo "Failed (check auth token)"

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
