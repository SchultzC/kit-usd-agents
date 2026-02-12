# Local MCP Server Management

This guide covers how to run the Kit USD Agents MCP servers locally for use with AI coding assistants like Claude Code and Cursor.

## Prerequisites

- **Python 3.11+** (up to 3.13; 3.12 recommended) — [python.org/downloads](https://www.python.org/downloads/)
- **NVIDIA API Key** — [build.nvidia.com](https://build.nvidia.com)
- **Poetry** — installed automatically by the start script if missing
- **Claude Code CLI** — only needed for `configure_claude_mcps.sh`

## Quick Start

```bash
# 1. Start all MCP servers (sets up environments on first run)
./start_all_mcps.sh

# 2. Register with Claude Code
./configure_claude_mcps.sh add

# 3. Verify in Claude Code
claude mcp list
```

That's it. All three servers are now running in the background and connected to Claude Code.

## Scripts Reference

### `start_all_mcps.sh`

Starts all three MCP servers as background processes.

**What it does:**
1. Detects the best Python on your PATH (checks both `python3` and `python`, picks the highest qualifying version >=3.11 <3.14)
2. Installs Poetry if not already present
3. Prompts for `NVIDIA_API_KEY` if not set in your environment
4. Creates virtual environments for any server that doesn't have one yet (first run only)
5. Launches each server in the background with `nohup`
6. Writes PID files and redirects output to log files
7. Prints a status summary

**Idempotent:** Running it again will skip servers that are already running.

**First run:** Expect several minutes for `poetry install` to download dependencies for each server.

```bash
./start_all_mcps.sh
```

### `stop_all_mcps.sh`

Stops all running MCP servers.

**What it does:**
1. Reads PID files written by `start_all_mcps.sh`
2. Sends SIGTERM for graceful shutdown
3. Waits up to 5 seconds, then sends SIGKILL if needed
4. Cleans up PID files

```bash
./stop_all_mcps.sh
```

### `configure_claude_mcps.sh`

Adds or removes the MCP servers from your Claude Code user-level configuration (`~/.claude.json`).

```bash
# Register all servers
./configure_claude_mcps.sh add

# Unregister all servers
./configure_claude_mcps.sh remove
```

The servers must be running for Claude Code to connect to them. Run `start_all_mcps.sh` first.

## Server Details

| Server | Port | MCP Endpoint | Description |
|--------|------|-------------|-------------|
| OmniUI MCP | 9901 | `http://localhost:9901/mcp` | Omniverse UI component tools |
| Kit MCP | 9902 | `http://localhost:9902/mcp` | Omniverse Kit development tools |
| USD Code MCP | 9903 | `http://localhost:9903/mcp` | USD code generation and search tools |

## File Locations

| What | Path |
|------|------|
| PID files | `source/mcp/.mcp-pids/<server-name>.pid` |
| Log files | `source/mcp/.mcp-logs/<server-name>.log` |
| Server source | `source/mcp/<server_dir>/` |
| Virtual envs | `source/mcp/<server_dir>/.venv/` |

Both `.mcp-pids/` and `.mcp-logs/` are gitignored.

## Checking Status

Check if the servers are running:

```bash
# Quick PID check
for f in source/mcp/.mcp-pids/*.pid; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .pid)
    pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then
        echo "$name: running (PID $pid)"
    else
        echo "$name: stopped (stale PID file)"
    fi
done
```

Check by port:

```bash
curl -s http://localhost:9901/health && echo "OmniUI MCP: OK"
curl -s http://localhost:9902/health && echo "Kit MCP: OK"
curl -s http://localhost:9903/health && echo "USD Code MCP: OK"
```

View live logs:

```bash
tail -f source/mcp/.mcp-logs/usd-code-mcp.log
```

## Reboot Behavior

The MCP servers run as regular background processes. They do **not** survive a machine restart. After rebooting, simply run `./start_all_mcps.sh` again. The virtual environments persist, so subsequent starts are fast.

## Troubleshooting

### "NVIDIA_API_KEY not set"

Set it before running the start script:

```bash
export NVIDIA_API_KEY=nvapi-...
./start_all_mcps.sh
```

Or add it to your shell profile (`~/.bashrc`, `~/.zshrc`) for persistence:

```bash
echo 'export NVIDIA_API_KEY=nvapi-...' >> ~/.bashrc
```

### Server fails to start

Check the log file for the specific server:

```bash
cat source/mcp/.mcp-logs/usd-code-mcp.log
```

Common causes:
- Missing `NVIDIA_API_KEY`
- Port already in use (see below)
- Failed `poetry install` (network issues, Python version mismatch)

### Port already in use

Find what is using the port and kill it, or stop the existing MCP first:

```bash
lsof -i :9903
./stop_all_mcps.sh
```

### Poetry not found after install

The installer puts Poetry in `~/.local/bin`. Add it to your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Orphaned processes after stop

If `stop_all_mcps.sh` does not fully clean up child processes:

```bash
# Find any remaining MCP-related processes
ps aux | grep -E "(omni-ui-aiq|kit-mcp|usd-code-mcp|nat mcp serve)" | grep -v grep

# Kill them manually
kill <pid>
```

## Cursor IDE Integration

For Cursor, create or edit `.cursor/mcp.json` in the project root:

```json
{
  "mcpServers": {
    "omni-ui-mcp": {
      "url": "http://localhost:9901/mcp"
    },
    "kit-mcp": {
      "url": "http://localhost:9902/mcp"
    },
    "usd-code-mcp": {
      "url": "http://localhost:9903/mcp"
    }
  }
}
```

The servers still need to be running via `./start_all_mcps.sh`.
