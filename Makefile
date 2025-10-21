# Makefile for common development tasks

.PHONY: help rebuild purge local_setup start restart stop collector backup restore list-backups export-openapi

help:
	@echo "Available targets:"
	@echo "  help                      Show this help"
	@echo "  local_setup               Create/activate virtualenv and install local_requirements.txt"
	@echo "  start                     Start docker compose services and follow logs"
	@echo "  stop                      Stop docker compose services"
	@echo "  restart                   Restart docker compose services"
	@echo "  rebuild [SERVICE]         Rebuild docker compose services (no-cache) and follow logs"
	@echo "                            Optional: specify SERVICE to rebuild only that service"
	@echo "  purge                     Stop compose and remove volumes"
	@echo "  collector <name>          Run a collector using the env virtualenv"
	@echo "                            Available: imessage, localfs, contacts"
	@echo "                            Example: make collector contacts"
	@echo "                            Example: make collector imessage ARGS=\"--simulate 'Hi'\""
	@echo "                            Example: make collector imessage ARGS=\"--lookback=1h\""
	@echo "  export-openapi            Export Gateway OpenAPI schema to openapi/gateway.yaml for Redoc"
	@echo "  backup [NAME]             Create a backup of Docker volumes and state files"
	@echo "                            Optional: specify NAME for custom backup name"
	@echo "                            Example: make backup NAME=before-migration"
	@echo "  restore <name>            Restore from a backup (prompts for confirmation)"
	@echo "                            Example: make restore NAME=before-migration"
	@echo "  list-backups              List all available backups with details"

# Rebuild docker compose services from scratch, start detached, and follow logs
# Usage: make rebuild [SERVICE]
# Example: make rebuild gateway (rebuilds only gateway service)
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

# Remove containers, networks, volumes created by compose and clear ~/.haven
purge:
	@docker compose down -v
	@if [ -d ~/.haven ]; then \
		echo "Removing contents of ~/.haven..."; \
		rm -rf ~/.haven/*; \
	fi

# Run collectors from the virtualenv in env/
# Usage: make collector <name> [-- args...]
# Available collectors: imessage, localfs, contacts
# Example: make collector contacts
# Example: make collector imessage ARGS="--simulate 'Hi'"
# Example: make collector imessage ARGS="--lookback=1h"
collector:
	@COLLECTOR_NAME="$(word 1,$(filter-out collector,$(MAKECMDGOALS)))"; \
	if [ -z "$$COLLECTOR_NAME" ]; then \
		echo "Error: Please specify a collector name"; \
		echo "Usage: make collector <name> ARGS=\"...\""; \
		echo "Available: imessage, localfs, contacts"; \
		exit 1; \
	fi; \
	case "$$COLLECTOR_NAME" in \
		imessage|localfs|contacts) \
			echo "Running $$COLLECTOR_NAME collector..."; \
			./env/bin/python ./scripts/collectors/collector_$$COLLECTOR_NAME.py $(ARGS); \
			;; \
		*) \
			echo "Error: Unknown collector '$$COLLECTOR_NAME'"; \
			echo "Available: imessage, localfs, contacts"; \
			exit 1; \
			;; \
	esac

# Create or activate local Python virtualenv in ./env and install local_requirements.txt
# Usage: make local_setup
local_setup:
	@if [ -x ./env/bin/python ]; then \
		echo "Using existing virtualenv at ./env"; \
	else \
		echo "Creating virtualenv at ./env"; python3 -m venv env; \
	fi
	@./env/bin/pip install -U pip setuptools wheel
	@./env/bin/pip install -r local_requirements.txt

# Start docker compose in detached mode and follow logs
start:
	@docker compose up -d
	@docker compose logs -f

# Stop docker compose services
stop:
	@docker compose stop

# Restart running compose services
restart:
	@docker compose restart

# Create a backup of Docker volumes and state files
# Usage: make backup [NAME=<name>]
# Example: make backup
# Example: make backup NAME=before-migration
backup:
	@if [ -n "$(NAME)" ]; then \
		./scripts/backup.sh "$(NAME)"; \
	else \
		./scripts/backup.sh; \
	fi

# Restore from a backup (prompts for confirmation)
# Usage: make restore NAME=<backup_name>
# Example: make restore NAME=before-migration
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

# List all available backups with details
list-backups:
	@./scripts/list-backups.sh

# Export Gateway OpenAPI schema to openapi/gateway.yaml for Redoc
# This extracts the live schema from the FastAPI app so all routes are documented
# Tries running container first, falls back to transient container
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
