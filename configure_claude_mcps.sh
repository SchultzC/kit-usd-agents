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

# Add or remove Kit USD Agents MCP servers from the Claude Code CLI
# user-level configuration (~/.claude.json).
#
# Usage:
#   ./configure_claude_mcps.sh add      # Register all MCP servers
#   ./configure_claude_mcps.sh remove   # Unregister all MCP servers
set -e

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
# Server definitions
# ---------------------------------------------------------------------------
SERVER_NAMES=("omni-ui-mcp" "kit-mcp" "usd-code-mcp")
SERVER_URLS=("http://localhost:9901/mcp" "http://localhost:9902/mcp" "http://localhost:9903/mcp")

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <add|remove>"
    echo ""
    echo "  add     Register all MCP servers with Claude Code"
    echo "  remove  Unregister all MCP servers from Claude Code"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

ACTION="$1"

if [ "$ACTION" != "add" ] && [ "$ACTION" != "remove" ]; then
    echo_error "Invalid action: $ACTION"
    echo ""
    usage
fi

# ---------------------------------------------------------------------------
# Check claude CLI
# ---------------------------------------------------------------------------
if ! command -v claude &> /dev/null; then
    echo_error "'claude' CLI not found in PATH."
    echo "  Install Claude Code: https://docs.anthropic.com/en/docs/claude-code"
    echo "  Or ensure it is in your PATH."
    exit 1
fi

echo "========================================"
echo "Claude Code — MCP Server Configuration"
echo "========================================"
echo ""

if [ "$ACTION" = "add" ]; then
    echo_info "Adding MCP servers to Claude Code..."
    echo ""
    for i in "${!SERVER_NAMES[@]}"; do
        name="${SERVER_NAMES[$i]}"
        url="${SERVER_URLS[$i]}"
        echo_info "Adding $name -> $url"
        claude mcp add --transport http "$name" "$url"
    done
    echo ""
    echo_info "All MCP servers registered with Claude Code."
    echo "  Verify with:  claude mcp list"

elif [ "$ACTION" = "remove" ]; then
    echo_info "Removing MCP servers from Claude Code..."
    echo ""
    for name in "${SERVER_NAMES[@]}"; do
        echo_info "Removing $name"
        claude mcp remove "$name" 2>/dev/null || echo_warn "  $name was not registered (or already removed)."
    done
    echo ""
    echo_info "All MCP servers unregistered from Claude Code."
fi
