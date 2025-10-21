# HostAgent Overview

HostAgent is the native macOS companion to Haven. It unlocks capabilities that containers cannot access: iMessage collection, Vision-based OCR, filesystem monitoring, and link resolution. This page summarises the key workflows and links to deeper references.

## Why HostAgent Exists
- Provides read-only access to privileged macOS resources (Messages, Contacts, Filesystem).
- Wraps Vision APIs for OCR and entity detection with consistent JSON responses.
- Supplies a modular collector runtime that mirrors the Python CLI behaviours while remaining always-on via launchd.
- Keeps all traffic on-device; Gateway communicates with HostAgent over `host.docker.internal`.

## Core Endpoints
- `GET /v1/health` — verifies the agent is running and lists enabled modules.
- `GET /v1/capabilities` — advertises active collectors, OCR support, and configuration.
- `POST /v1/collectors/imessage:run` — runs the iMessage collector (supports `simulate`, `limit`, and lookback parameters).
- `POST /v1/ocr` — uploads an image or presigned URL for Vision OCR + entity extraction.
- `POST /v1/fswatch` (family of routes) — manages filesystem watch registrations and event queues.

Refer to [HostAgent README](hostagent-readme.md) for exhaustive endpoint descriptions, curl examples, and configuration keys.

## Install and Run
```bash
make -C hostagent install
make -C hostagent launchd
```
- Grants: Full Disk Access (Messages) and Contacts permission.
- Config: `~/.haven/hostagent.yaml` controls module enables, auth secret, and polling intervals.
- Logs: `~/Library/Logs/Haven/hostagent.log`
- Development mode: copy `~/Library/Messages/chat.db` to `~/.haven/chat.db` and set `HAVEN_IMESSAGE_CHAT_DB_PATH`.

## Operational Tips
- Use `make health` in `hostagent/` to exercise the health endpoint after upgrades.
- Monitor LaunchAgent state with `launchctl list | grep haven`.
- To rotate the auth secret, update `hostagent.yaml` and restart the LaunchAgent.
- For OCR throughput issues, ensure the Vision framework has hardware acceleration (macOS 13+ recommended).

## Related Documentation
- [Agents Overview](../guides/AGENTS.md) for network topology and orchestration rules.
- [Local Development](../operations/local-dev.md) for instructions on running HostAgent alongside Docker services.
- [Functional Guide](../reference/functional_guide.md) for how collectors feed downstream workflows.

_Adapted from `hostagent/README.md`, `AGENTS.md`, and prior HostAgent development notes._
