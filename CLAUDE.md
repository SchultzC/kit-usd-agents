# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kit USD Agents is an NVIDIA Omniverse project providing AI-powered development tools for USD (Universal Scene Description) and Kit development. It has two main parts:

1. **MCP Servers** (`source/mcp/`) — Three standalone Model Context Protocol servers that expose specialized tools to AI coding assistants (Claude, Cursor, etc.)
2. **Chat USD Extension** (`source/extensions/`) — A multi-agent AI assistant that runs inside Omniverse Kit

## Connecting the MCP Servers to Claude Code

```bash
claude mcp add --transport http omni-ui-mcp http://localhost:9901/mcp
claude mcp add --transport http kit-mcp http://localhost:9902/mcp
claude mcp add --transport http usd-code-mcp http://localhost:9903/mcp
```

Servers must be running first — see "MCP Servers" under Build & Development Commands.

## Build & Development Commands

### MCP Servers (primary development area)

Each MCP server is an independent Poetry project. Set up and run individually:

```bash
# Set up a server (one-time, creates .venv and installs deps)
cd source/mcp/usd_code_mcp && ./setup-dev.sh    # USD Code MCP (port 9903)
cd source/mcp/kit_mcp && ./setup-dev.sh          # Kit MCP (port 9902)
cd source/mcp/omni_ui_mcp && ./setup-dev.sh      # OmniUI MCP (port 9901)

# Run a server
./run.sh

# Or manually via Poetry
poetry run usd-code-mcp   # (or kit-mcp, omni-ui-mcp)
```

### Building Wheels (for Docker)

```bash
source/mcp/build-wheels.sh all    # Build all wheels
source/mcp/build-wheels.sh kit    # Build only kit-mcp wheels
source/mcp/build-wheels.sh usd    # Build only usd-code-mcp wheels
source/mcp/build-wheels.sh omni   # Build only omni-ui-mcp wheels
```

### Docker Deployment

```bash
# NVIDIA API (no GPU required)
export NVIDIA_API_KEY=nvapi-...
docker compose -f source/mcp/docker-compose.ngc.yaml up --build

# Local GPU NIMs (requires 2 NVIDIA GPUs + NGC_API_KEY)
docker compose -f source/mcp/docker-compose.local.yaml up --build
```

### Kit Extension Build

```bash
./build.sh          # Debug build
./build.sh -r       # Release build
```

### Testing

```bash
# Module tests (from source/modules/)
cd source/modules
tox -e test_lc_agent
tox -e test_lc_agent_rag_modifiers
tox -e test_lc_agent_nat

# Individual package tests (from any package with pyproject.toml)
poetry run pytest
poetry run pytest tests/test_specific.py           # Single test file
poetry run pytest tests/test_specific.py::test_fn  # Single test function
```

### Code Quality

Configured in pyproject.toml per package:
- **Black**: line-length=120, target-version=py311
- **Flake8**: max-line-length=120
- **Mypy**: strict mode

## Architecture

### MCP Servers

Three independent servers, each following the same pattern:

```
source/mcp/<server>/
├── src/<package>/
│   ├── server.py          # FastAPI + MCP protocol handler
│   ├── tools.py           # MCP tool definitions (registered with NAT)
│   └── services/          # Business logic (search, retrieval, embeddings)
├── workflow/
│   ├── config.yaml        # Default configuration
│   └── local_config.yaml  # Local overrides (gitignored)
├── pyproject.toml         # Poetry dependencies
├── setup-dev.sh           # Dev environment setup
└── run.sh                 # Server launcher
```

Each MCP server imports its corresponding AIQ functions package as a dependency:
- `usd_code_mcp` → `usd_code_fns` (source/aiq/usd_code_fns)
- `kit_mcp` → `kit_fns` (source/aiq/kit_fns)
- `omni_ui_mcp` → `omni_ui_fns` (source/aiq/omni_ui_fns)

AIQ function packages contain the knowledge bases (FAISS indexes, code examples) in their `data/` directories. These are large binary files managed via Git LFS.

### Chat USD Extension (Multi-Agent Architecture)

```
ChatUSDNetworkNode (entry point / router)
    └── ChatUSDSupervisorNode (LLM-based query orchestrator)
            ├── USDCodeInteractiveNetworkNode  (generates & executes USD Python)
            ├── USDSearchNetworkNode            (searches USD assets via Deep Search)
            └── SceneInfoNetworkNode            (retrieves scene hierarchy/properties)
```

Key patterns:
- **NetworkNode**: Container for sub-nodes, doesn't interact with LLMs directly
- **RunnableNode**: Leaf node that invokes LLM chains
- **Modifiers**: Middleware that intercepts and enhances node processing (code extraction, scene info injection, etc.)
- **System Messages**: Define each agent's capabilities and response behavior

### Shared Modules (`source/modules/`)

Poetry monorepo with develop=true path dependencies. Key packages:
- `lc_agent` — Core LangChain agent framework (NetworkNode, RunnableNode, MultiAgentNetworkNode)
- `rags/` — RAG nodes, modifiers, and retrievers
- `nat/lc_agent_nat` — NeMo Agent Toolkit integration
- `agents/` — Specialized agent implementations (USD, planning, interactive, doc_atlas)

## Key Conventions

- All source files must have Apache 2.0 SPDX license headers
- Python 3.11+ required (3.12 recommended), upper bound <3.13
- MCP servers use NAT (NeMo Agent Toolkit) >=1.4.0 for tool registration
- Configuration via YAML (`workflow/config.yaml`) with optional `local_config.yaml` overrides
- Environment variables: `NVIDIA_API_KEY` (required for cloud), `NGC_API_KEY` (required for local NIM deployment)
- Docker images use `python:3.13-slim` base with non-root user

## Detailed Architecture Documentation

The following files contain in-depth documentation for the AI agent frameworks and components. Read these when working on the corresponding areas of the codebase:

- **`.cursor/rules/lc-agent.mdc`** — Core LC Agent framework: RunnableNode, RunnableNetwork, NetworkModifier, NodeFactory, NetworkNode, MultiAgentNetworkNode. Read when working on `source/modules/lc_agent/` or building new agent nodes.
- **`.cursor/rules/lc-agent-usd.mdc`** — USD-specific agent components: USDKnowledgeNetworkNode, USDCodeGenNetworkNode, USDCodeInteractiveNetworkNode, and USD modifiers. Read when working on `source/modules/agents/usd/`.
- **`.cursor/rules/chat-usd.mdc`** — Chat USD extension architecture: multi-agent routing, supervisor-agent interactions, message flow, component registration, and all Chat USD nodes/modifiers. Read when working on `source/extensions/omni.ai.chat_usd.bundle/`.
- **`.cursor/rules/extending-chat-usd.mdc`** — Step-by-step guide for adding custom agents to Chat USD, using the Navigation Agent as a reference implementation. Read when creating new agents or extensions.
