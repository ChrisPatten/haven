# Makefile for common development tasks

.PHONY: help rebuild purge local_setup start restart stop collector

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

