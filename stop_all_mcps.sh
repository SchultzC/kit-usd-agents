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

# Stop all Kit USD Agents MCP servers that were started by start_all_mcps.sh.
#
# Sends SIGTERM first, waits up to 5 seconds for graceful shutdown, then
# sends SIGKILL if the process is still running. Also checks ports for any
# orphaned processes and cleans those up too.
#
# Usage:
#   ./stop_all_mcps.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$SCRIPT_DIR/source/mcp"
PID_DIR="$MCP_DIR/.mcp-pids"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Server definitions (must match start_all_mcps.sh)
# ---------------------------------------------------------------------------
SERVER_NAMES=("omni-ui-mcp" "kit-mcp" "usd-code-mcp")
SERVER_PORTS=(9901 9902 9903)
GRACE_PERIOD=5  # seconds to wait for graceful shutdown

# ---------------------------------------------------------------------------
# Helper: kill a PID with grace period
# ---------------------------------------------------------------------------
kill_pid() {
    local pid=$1
    local label=$2

    kill "$pid" 2>/dev/null || true

    local elapsed=0
    while [ "$elapsed" -lt "$GRACE_PERIOD" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo_warn "$label: Still running after ${GRACE_PERIOD}s. Sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

echo "========================================"
echo "Kit USD Agents — Stop All MCP Servers"
echo "========================================"
echo ""

STOPPED_COUNT=0
ALREADY_STOPPED_COUNT=0

for i in "${!SERVER_NAMES[@]}"; do
    name="${SERVER_NAMES[$i]}"
    port="${SERVER_PORTS[$i]}"
    pid_file="$PID_DIR/${name}.pid"

    # --- Phase 1: Kill tracked PID from PID file ---
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")

        if kill -0 "$pid" 2>/dev/null; then
            echo_info "$name: Sending SIGTERM to PID $pid..."
            if kill_pid "$pid" "$name"; then
                echo_info "$name: Stopped PID $pid."
            else
                echo_error "$name: Failed to stop PID $pid!"
            fi
        else
            echo_warn "$name: PID $pid is not running (stale PID file)."
        fi

        rm -f "$pid_file"
    fi

    # --- Phase 2: Check port for any remaining/orphaned process ---
    port_pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
    if [ -n "$port_pid" ]; then
        echo_warn "$name: Orphaned process $port_pid still on port $port. Killing..."
        if kill_pid "$port_pid" "$name (port $port)"; then
            echo_info "$name: Orphaned process on port $port stopped."
        else
            echo_error "$name: Failed to stop orphaned process on port $port!"
        fi
    fi

    # --- Final status ---
    if ! lsof -ti :"$port" &>/dev/null; then
        if [ -f "$pid_file" ] || [ -n "$port_pid" ] || kill -0 "${pid:-0}" 2>/dev/null; then
            STOPPED_COUNT=$((STOPPED_COUNT + 1))
        else
            STOPPED_COUNT=$((STOPPED_COUNT + 1))
        fi
    fi
done

# Clean up PID directory if empty
if [ -d "$PID_DIR" ]; then
    rmdir "$PID_DIR" 2>/dev/null || true
fi

# --- Final port verification ---
echo ""
all_clear=true
for i in "${!SERVER_NAMES[@]}"; do
    name="${SERVER_NAMES[$i]}"
    port="${SERVER_PORTS[$i]}"
    if lsof -ti :"$port" &>/dev/null; then
        echo_error "$name: Port $port is STILL in use!"
        all_clear=false
    fi
done

if [ "$all_clear" = true ]; then
    echo_info "All MCP servers stopped. Ports 9901-9903 are free."
else
    echo_error "Some ports could not be freed. Check with: lsof -i :9901 -i :9902 -i :9903"
fi
