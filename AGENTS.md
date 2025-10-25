# AGENTS.md
Haven is a personal data plane that turns iMessage history, files, and email into a searchable knowledge base. It features hybrid lexical/vector search, summarization, and image enrichment powered by large language models. The hostagent collects data locally on your Mac, while the gateway and backend services run in Docker containers.

## Rules and Guidelines
* Haven agents are host-native daemons, container services, background workers, and CLI collectors that move or transform data. Each agent has a specific role and scope: 
  * **External entry point:** Gateway only.  
  * **HostAgent:** localhost-only.  
  * **No agent** interacts with internal services directly. All communication is via the gateway service API.
* If the user mentions "bead", "beads", or references beads by name like "haven-27" or "hv-27", they are referring to the planning and work-tracking system available via the beads MCP server. Call the `beads.show` tool to retrieve relevant information.
  * If the MCP server is not available, fall back to using the `bd` command-line tool to retrieve information about beads.
* Comprehensive documentation is available in the `/docs/` directory. Always refer to it and keep it updated with any changes you make.
* If changes are made in the `/docs/` directory, ensure that the mkdocs configuration file (`mkdocs.yml`) is updated accordingly to reflect the new or modified documentation. Pay attention to good information architecture.
* **NEVER** read or edit the files in ./.beads directly. All interactions must be via the beads MCP server or the `bd` CLI tool to ensure proper versioning and tracking.
* When writing commit messages, include the relevant beads issue ID in the footer as `Refs: beads:#<id>`. Do not include references to the files in the .beads/ directory in commit messages.
* When executing swift commands, prepend them with arch -x86_64 to ensure compatibility with Intel-based dependencies.
* To close an issue, use the beads.update command with the appropriate JSON payload to change the issue status to "closed".
