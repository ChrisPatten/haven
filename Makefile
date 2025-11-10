# Makefile for common development tasks

.PHONY: help rebuild purge local_setup start restart stop collector backup restore list-backups export-openapi docs build-haven run-haven

LIMIT ?= 1

## Show available make targets and their descriptions
help:
	@echo "Haven Make targets:"
	@awk -F':' ' \
		/^[a-zA-Z0-9_.-]+:/ { \
			gsub(/:.*/, "", $$1); tgt=$$1; \
			if (prev ~ /^##/) { \
				gsub(/^##[ ]?/, "", prev); \
				printf "  %-20s %s\n", tgt, prev; \
			} \
		} { prev=$$0 }' $(MAKEFILE_LIST)
	
## Rebuild docker compose services from scratch, start detached, and follow logs. Optional: specify SERVICE to rebuild only that service
rebuild:
	@if [ -n "$(filter-out rebuild,$(MAKECMDGOALS))" ]; then \
		SERVICE="$(filter-out rebuild,$(MAKECMDGOALS))"; \
		echo "Rebuilding service: $$SERVICE"; \
		docker compose stop $$SERVICE || true; \
		docker compose build --no-cache $$SERVICE; \
		docker compose up -d $$SERVICE; \
		docker compose logs -f $$SERVICE; \
	else \
		echo "Rebuilding all services"; \
		docker compose down || true; \
		docker compose build --no-cache; \
		docker compose up -d; \
		docker compose logs -f; \
	fi

# Catch-all target to handle service names passed as arguments
%:
	@:

## Stop compose and remove volumes; remove local caches and state files
purge:
	@echo "Removing all data from the database..."
	@docker compose down -v
	@echo "Clearing collector state files..."
	@rm -f ~/Library/Application\ Support/Haven/State/localfs_collector_state.json 2>/dev/null || true
	@rm -f ~/Library/Application\ Support/Haven/State/icloud_drive_collector_state.json 2>/dev/null || true
	@rm -f ~/Library/Application\ Support/Haven/State/contacts_collector_state.json 2>/dev/null || true
	@rm -f ~/Library/Application\ Support/Haven/State/imessage_state.json 2>/dev/null || true
	@rm -f ~/Library/Application\ Support/Haven/State/email_collector_state_run.json 2>/dev/null || true
	@rm -f ~/Library/Application\ Support/Haven/State/email_collector.lock 2>/dev/null || true
	@echo "Clearing handler status files..."
	@rm -f ~/Library/Caches/Haven/imessage_handler_state.json 2>/dev/null || true
	@rm -f ~/Library/Caches/Haven/imap_handler_state.json 2>/dev/null || true
	@echo "Clearing IMAP state files..."
	@rm -f ~/Library/Caches/Haven/remote_mail/imap_state_*.json 2>/dev/null || true
	@echo "Clearing debug files..."
	@rm -f ~/Library/Application\ Support/Haven/Debug/* 2>/dev/null || true
	@echo "Clearing chat backup..."
	@rm -rf ~/Library/Application\ Support/Haven/Backups/chat_backup/ 2>/dev/null || true
	@echo "Clearing legacy ~/.haven files (if any)..."
	@if [ -d ~/.haven ]; then \
		echo "Removing legacy iMessage backup..."; \
		rm -rf ~/.haven/chat_backup/ 2>/dev/null || true; \
		echo "Removing legacy state files..."; \
		rm -f ~/.haven/*_collector_state.json 2>/dev/null || true; \
		rm -f ~/.haven/email_collector.lock 2>/dev/null || true; \
		rm -f ~/.haven/cache/imessage_state.json 2>/dev/null || true; \
		rm -rf ~/.haven/cache/remote_mail/ 2>/dev/null || true; \
	fi
	@echo "✓ Purge complete"

## Create or activate local Python virtualenv using uv and install dependencies from pyproject.toml
local_setup:
	@echo "Setting up virtual environment with uv..."
	@uv venv --python 3.11
	@echo "Installing project dependencies..."
	@uv pip install -e ".[dev]"
	@echo "✓ Virtual environment ready at .venv"
	@echo "  Activate with: source .venv/bin/activate"
	@echo "  Or use uv run <command> to run commands in the venv automatically"

## Start docker compose services
start:
	@docker compose up -d

## Tail the docker compose logs
docker-logs:
	@docker compose logs -f

## Tail the Haven.app logs
haven-logs:
	@tail -f ~/Library/Logs/Haven/hostagent.log

## Stop docker compose services
stop:
	@docker compose stop

## Restart docker compose services
restart:
	@docker compose restart

## Create a backup of Docker volumes and state files. Optional: specify NAME for custom backup name
backup:
	@if [ -n "$(NAME)" ]; then \
		./scripts/backup.sh "$(NAME)"; \
	else \
		./scripts/backup.sh; \
	fi

## Restore from a backup (prompts for confirmation). Usage: make restore NAME=<backup_name>
restore:
	@if [ -z "$(NAME)" ]; then \
		echo "Error: Please specify a backup name"; \
		echo "Usage: make restore NAME=<backup_name>"; \
		echo ""; \
		echo "Available backups:"; \
		./scripts/list-backups.sh; \
		exit 1; \
	fi
	@./scripts/restore.sh "$(NAME)"

## List all available backups with details
list-backups:
	@./scripts/list-backups.sh

## Export Gateway OpenAPI schema to openapi/gateway.yaml for Redoc. Extracts live schema from FastAPI app
export-openapi:
	@echo "Exporting Gateway OpenAPI schema..."
	@if docker compose ps gateway | grep -q "Up"; then \
		echo "Using running gateway container..."; \
		docker compose exec -T gateway python -c "import sys; sys.path.insert(0, '/app'); from services.gateway_api.app import app; import yaml; schema = app.openapi(); print(yaml.dump(schema, default_flow_style=False, sort_keys=False, allow_unicode=True, width=120))" > openapi/gateway.yaml; \
	else \
		echo "Starting transient gateway container..."; \
		docker compose run --rm --no-deps gateway python -c "import sys; sys.path.insert(0, '/app'); from services.gateway_api.app import app; import yaml; schema = app.openapi(); print(yaml.dump(schema, default_flow_style=False, sort_keys=False, allow_unicode=True, width=120))" > openapi/gateway.yaml; \
	fi
	@echo "✓ OpenAPI schema exported to openapi/gateway.yaml"

## Serve MkDocs documentation locally. Optional: DOC_HOST, DOC_PORT, DOC_SITE_PATH, OPEN_BROWSER=false
docs:
	@./scripts/serve_docs.sh

## Install git hooks from .githooks directory into .git/hooks
.githooks/install-hooks:
	@echo "Installing git hooks from .githooks to .git/hooks"
	@mkdir -p .git/hooks
	@cp -R .githooks/* .git/hooks/
	@chmod +x .git/hooks/* || true

## Install git hooks from .githooks directory into .git/hooks
install-hooks: .githooks/install-hooks

## Show the last N records. Optional: TYPE=<type> LIMIT=<n>. TYPE can be: email, imessage, contact
peek:
	@if [ -z "$(TYPE)" ]; then \
		docker compose exec postgres psql -U postgres -d haven -t -c "SELECT text FROM documents ORDER BY ingested_at DESC LIMIT $(LIMIT);"; \
	elif [ "$(TYPE)" = "email" ]; then \
		docker compose exec postgres psql -U postgres -d haven -t -c "SELECT title || E'\n' || text FROM documents WHERE source_type IN ('email', 'email_local') ORDER BY ingested_at DESC LIMIT $(LIMIT);"; \
	elif [ "$(TYPE)" = "imessage" ]; then \
		docker compose exec postgres psql -U postgres -d haven -t -c "SELECT text FROM documents WHERE source_type = 'imessage' ORDER BY ingested_at DESC LIMIT $(LIMIT);"; \
	elif [ "$(TYPE)" = "contact" ]; then \
		docker compose exec postgres psql -U postgres -d haven -c "SELECT external_id, title, text, COALESCE(metadata->'contact'->>'display_name', metadata->>'display_name') as display_name, ingested_at FROM documents WHERE source_type = 'contact' ORDER BY ingested_at DESC LIMIT $(LIMIT);"; \
	else \
		echo "Error: Invalid TYPE. Valid types: email, imessage, contact"; \
		exit 1; \
	fi

## Update Beads and beads-mcp tools
upgrade-beads:
	@echo "Updating Beads and beads-mcp"
	@brew upgrade bd
	@uv tool upgrade beads-mcp
	@bd migrate

## Build Haven.app using AppleScript to tell Xcode to build
build-haven:
	@echo "Building Haven.app with Xcode..."
	@osascript -e 'tell application "Xcode"' \
		-e 'set projectPath to POSIX file "$(PWD)/Haven/Haven.xcodeproj"' \
		-e 'open projectPath' \
		-e 'delay 2' \
		-e 'tell workspace document 1' \
		-e 'build' \
		-e 'end tell' \
		-e 'end tell'

## Find the built Haven.app in DerivedData, and open it
run-haven:
	@echo "Finding Haven.app bundle..."
	@APP_PATH=$$(find ~/Library/Developer/Xcode/DerivedData -name "Haven" -path "*/Haven.app/Contents/MacOS/Haven" 2>/dev/null | head -1); \
	if [ -z "$$APP_PATH" ]; then \
		echo "Error: Could not find Haven.app bundle"; \
		exit 1; \
	fi; \
	APP_BUNDLE=$$(dirname $$(dirname $$(dirname $$APP_PATH))); \
	echo "Opening $$APP_BUNDLE"; \
	open "$$APP_BUNDLE"