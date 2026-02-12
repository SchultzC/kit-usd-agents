#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Start all Kit USD Agents MCP servers as background processes.
#
# This script validates the Python environment, installs Poetry if needed,
# sets up virtual environments on first run, and launches all three MCP
# servers in the background. Servers survive the script exiting but do
# NOT survive a reboot.
#
# Usage:
#   ./start_all_mcps.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$SCRIPT_DIR/source/mcp"
PID_DIR="$MCP_DIR/.mcp-pids"
LOG_DIR="$MCP_DIR/.mcp-logs"

# ---------------------------------------------------------------------------
# Color helpers (matching build-wheels.sh conventions)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Server definitions
# ---------------------------------------------------------------------------
SERVER_NAMES=("omni-ui-mcp" "kit-mcp" "usd-code-mcp")
SERVER_DIRS=("$MCP_DIR/omni_ui_mcp" "$MCP_DIR/kit_mcp" "$MCP_DIR/usd_code_mcp")
SERVER_ENTRY_POINTS=("omni-ui-aiq" "kit-mcp" "usd-code-mcp")
SERVER_PORTS=(9901 9902 9903)
SERVER_CONFIG_DIRS=("workflow" "workflows" "workflow")
SERVER_LOG_ENV_VARS=("OMNI_UI_DISABLE_USAGE_LOGGING" "KIT_MCP_DISABLE_USAGE_LOGGING" "USD_CODE_MCP_DISABLE_USAGE_LOGGING")

# ---------------------------------------------------------------------------
# Step 1: Find the best qualifying Python (>=3.11, <3.14)
# ---------------------------------------------------------------------------
echo "========================================"
echo "Kit USD Agents — Start All MCP Servers"
echo "========================================"
echo

find_best_python() {
    local best_cmd=""
    local best_minor=0

    for candidate in python3 python; do
        if ! command -v "$candidate" &> /dev/null; then
            continue
        fi

        local ver
        ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || continue
        local major="${ver%%.*}"
        local minor="${ver#*.}"

        if [ "$major" -eq 3 ] && [ "$minor" -ge 11 ] && [ "$minor" -lt 14 ]; then
            if [ "$minor" -gt "$best_minor" ]; then
                best_minor="$minor"
                best_cmd="$candidate"
            elif [ "$minor" -eq "$best_minor" ] && [ "$candidate" = "python3" ]; then
                best_cmd="python3"
            fi
        fi
    done

    if [ -z "$best_cmd" ]; then
        echo_error "No qualifying Python found on PATH."
        echo "  Requires Python >=3.11, <3.14 (3.12 recommended)."
        echo "  Checked: python3, python"
        echo "  Visit: https://www.python.org/downloads/"
        exit 1
    fi

    PYTHON_CMD="$best_cmd"
    PYTHON_VERSION=$("$PYTHON_CMD" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
    echo_info "Using $PYTHON_CMD (Python $PYTHON_VERSION)"
}

find_best_python

# ---------------------------------------------------------------------------
# Step 2: Ensure Poetry is available
# ---------------------------------------------------------------------------
if ! command -v poetry &> /dev/null; then
    echo_info "Poetry not found. Installing Poetry..."
    curl -sSL https://install.python-poetry.org | "$PYTHON_CMD" -

    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v poetry &> /dev/null; then
        echo_error "Failed to install Poetry or Poetry not in PATH."
        echo "  Install manually: https://python-poetry.org/docs/#installation"
        echo "  Or add ~/.local/bin to your PATH and re-run this script."
        exit 1
    fi

    echo_info "Poetry installed successfully!"
fi

echo_info "Poetry version: $(poetry --version)"

# ---------------------------------------------------------------------------
# Step 3: Ensure NVIDIA_API_KEY is set
# ---------------------------------------------------------------------------
if [ -z "${NVIDIA_API_KEY:-}" ]; then
    echo ""
    echo_warn "NVIDIA_API_KEY is not set."
    echo "  The MCP servers require an NVIDIA API key for embedding and reranking models."
    echo "  Get one at: https://build.nvidia.com"
    echo ""

    if [ -t 0 ]; then
        read -rp "Enter your NVIDIA_API_KEY: " NVIDIA_API_KEY
        if [ -z "$NVIDIA_API_KEY" ]; then
            echo_error "No API key provided. Exiting."
            exit 1
        fi
        export NVIDIA_API_KEY
        echo_info "NVIDIA_API_KEY set for this session."
    else
        echo_error "NVIDIA_API_KEY is not set and stdin is not interactive."
        echo "  Set it with:  export NVIDIA_API_KEY=nvapi-..."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Create runtime directories
# ---------------------------------------------------------------------------
mkdir -p "$PID_DIR"
mkdir -p "$LOG_DIR"

# Configure Poetry once (global setting, matches setup-dev.sh)
poetry config virtualenvs.in-project true

# ---------------------------------------------------------------------------
# Step 5: Set up and launch each server
# ---------------------------------------------------------------------------
STARTED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

echo ""

set +e  # Allow individual server failures without aborting

for i in "${!SERVER_NAMES[@]}"; do
    name="${SERVER_NAMES[$i]}"
    dir="${SERVER_DIRS[$i]}"
    entry="${SERVER_ENTRY_POINTS[$i]}"
    port="${SERVER_PORTS[$i]}"
    config_dir="${SERVER_CONFIG_DIRS[$i]}"
    log_env="${SERVER_LOG_ENV_VARS[$i]}"
    pid_file="$PID_DIR/${name}.pid"
    log_file="$LOG_DIR/${name}.log"

    echo_info "--- $name (port $port) ---"

    # Check if already running (via PID file)
    if [ -f "$pid_file" ]; then
        existing_pid=$(cat "$pid_file")
        if kill -0 "$existing_pid" 2>/dev/null; then
            echo_warn "$name is already running (PID $existing_pid). Skipping."
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            echo ""
            continue
        else
            echo_warn "Stale PID file found for $name. Cleaning up."
            rm -f "$pid_file"
        fi
    fi

    # Check if port is already in use (e.g. orphaned process from a previous session)
    port_pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
    if [ -n "$port_pid" ]; then
        echo_warn "Port $port is already in use by PID $port_pid."
        echo_warn "Killing existing process on port $port..."
        kill "$port_pid" 2>/dev/null || true
        sleep 2
        if lsof -ti :"$port" &>/dev/null; then
            echo_warn "Force-killing process on port $port..."
            kill -9 "$port_pid" 2>/dev/null || true
            sleep 1
        fi
        if lsof -ti :"$port" &>/dev/null; then
            echo_error "Cannot free port $port. Skipping $name."
            FAILED_COUNT=$((FAILED_COUNT + 1))
            echo ""
            continue
        fi
        echo_info "Port $port freed."
    fi

    # Set up virtual environment if missing or incomplete
    # Check both that .venv exists AND that the entry point script is installed
    needs_install=false
    if [ ! -d "$dir/.venv" ]; then
        needs_install=true
    elif [ ! -f "$dir/.venv/bin/$entry" ]; then
        echo_warn "Virtual environment exists but $entry is not installed. Re-running poetry install..."
        needs_install=true
    fi

    if [ "$needs_install" = true ]; then
        echo_info "Setting up virtual environment for $name (first run — this may take a few minutes)..."
        if ! (cd "$dir" && poetry install); then
            echo_error "Failed to set up virtual environment for $name. Skipping."
            FAILED_COUNT=$((FAILED_COUNT + 1))
            echo ""
            continue
        fi
    else
        echo_info "Virtual environment ready for $name."
    fi

    # Determine config file
    if [ -f "$dir/$config_dir/local_config.yaml" ]; then
        config_file="$config_dir/local_config.yaml"
    else
        config_file="$config_dir/config.yaml"
    fi

    echo_info "Config: $config_file"

    # Launch the server in the background using setsid to create a new process group.
    # This ensures stop_all_mcps.sh can kill the entire process tree (poetry + nat)
    # by sending a signal to the process group.
    setsid env \
        MCP_PORT="$port" \
        NVIDIA_API_KEY="$NVIDIA_API_KEY" \
        "${log_env}=false" \
        bash -c "cd \"$dir\" && exec poetry run \"$entry\" \"$config_file\"" \
        >> "$log_file" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$pid_file"

    # Wait for the server to load indexes and bind its port
    sleep 5

    # Find the actual nat process listening on the port (the long-lived child)
    nat_pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
    if [ -n "$nat_pid" ]; then
        echo_info "$name started (PID $nat_pid, port $port)"
        echo "$nat_pid" > "$pid_file"
        STARTED_COUNT=$((STARTED_COUNT + 1))
    elif kill -0 "$SERVER_PID" 2>/dev/null; then
        # Process is alive but not yet listening — keep wrapper PID
        echo_warn "$name process running (PID $SERVER_PID) but not yet listening on port $port."
        STARTED_COUNT=$((STARTED_COUNT + 1))
    else
        echo_error "$name failed to start. Last 15 lines of log:"
        tail -15 "$log_file" 2>/dev/null || true
        rm -f "$pid_file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    echo ""
done

set -e

# ---------------------------------------------------------------------------
# Step 6: Final health check and summary
# ---------------------------------------------------------------------------
# Re-verify all PIDs one more time (servers can die after initial check)
RUNNING_COUNT=0
DEAD_COUNT=0

echo "========================================"
echo "MCP Server Status Summary"
echo "========================================"
echo ""
printf "  ${CYAN}%-15s %-6s %-12s %s${NC}\n" "SERVER" "PORT" "STATUS" "LOG FILE"
printf "  %-15s %-6s %-12s %s\n" "------" "----" "------" "--------"
for i in "${!SERVER_NAMES[@]}"; do
    name="${SERVER_NAMES[$i]}"
    port="${SERVER_PORTS[$i]}"
    pid_file="$PID_DIR/${name}.pid"
    log_file="$LOG_DIR/${name}.log"
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            printf "  ${GREEN}%-15s %-6s %-12s${NC} %s\n" "$name" "$port" "UP (${pid})" "$log_file"
            RUNNING_COUNT=$((RUNNING_COUNT + 1))
        else
            printf "  ${RED}%-15s %-6s %-12s${NC} %s\n" "$name" "$port" "DEAD" "$log_file"
            DEAD_COUNT=$((DEAD_COUNT + 1))
        fi
    else
        printf "  ${RED}%-15s %-6s %-12s${NC} %s\n" "$name" "$port" "FAILED" "$log_file"
        DEAD_COUNT=$((DEAD_COUNT + 1))
    fi
done

echo ""
if [ "$RUNNING_COUNT" -eq "${#SERVER_NAMES[@]}" ]; then
    echo_info "All $RUNNING_COUNT servers are running."
elif [ "$RUNNING_COUNT" -gt 0 ]; then
    echo_warn "$RUNNING_COUNT/${#SERVER_NAMES[@]} servers running. $DEAD_COUNT failed — check logs above."
else
    echo_error "No servers are running. Check logs for errors."
fi
echo ""
echo "To stop all servers:     ./stop_all_mcps.sh"
echo "To view logs:            tail -f $LOG_DIR/<server-name>.log"
echo "To register with Claude: ./configure_claude_mcps.sh add"
