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

<#
.SYNOPSIS
    Add or remove Kit USD Agents MCP servers from the Claude Code CLI
    user-level configuration (~/.claude.json).

.DESCRIPTION
    Registers or unregisters all three MCP servers so they are available
    across all repositories.

.PARAMETER Action
    Either "add" to register servers or "remove" to unregister them.

.EXAMPLE
    .\configure_claude_mcps.ps1 add
    .\configure_claude_mcps.ps1 remove
#>

param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Action
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Message) Write-Host "[INFO] " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn  { param([string]$Message) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Err   { param([string]$Message) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $Message }

# ---------------------------------------------------------------------------
# Server definitions
# ---------------------------------------------------------------------------
$Servers = @(
    @{ Name = "omni-ui-mcp";  Url = "http://localhost:9901/mcp" },
    @{ Name = "kit-mcp";      Url = "http://localhost:9902/mcp" },
    @{ Name = "usd-code-mcp"; Url = "http://localhost:9903/mcp" }
)

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
function Show-Usage {
    Write-Host "Usage: .\configure_claude_mcps.ps1 <add|remove>"
    Write-Host ""
    Write-Host "  add     Register all MCP servers with Claude Code"
    Write-Host "  remove  Unregister all MCP servers from Claude Code"
    exit 1
}

if (-not $Action) {
    Show-Usage
}

if ($Action -ne "add" -and $Action -ne "remove") {
    Write-Err "Invalid action: $Action"
    Write-Host ""
    Show-Usage
}

# ---------------------------------------------------------------------------
# Check claude CLI
# ---------------------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Err "'claude' CLI not found in PATH."
    Write-Host "  Install Claude Code: https://docs.anthropic.com/en/docs/claude-code"
    Write-Host "  Or ensure it is in your PATH."
    exit 1
}

Write-Host "========================================"
Write-Host "Claude Code - MCP Server Configuration"
Write-Host "========================================"
Write-Host ""

if ($Action -eq "add") {
    Write-Info "Adding MCP servers to Claude Code..."
    Write-Host ""
    foreach ($srv in $Servers) {
        $name = $srv.Name
        $url = $srv.Url
        Write-Info "Adding $name -> $url"
        & claude mcp add --scope user --transport http $name $url
    }
    Write-Host ""
    Write-Info "All MCP servers registered with Claude Code."
    Write-Host "  Verify with:  claude mcp list"
}
elseif ($Action -eq "remove") {
    Write-Info "Removing MCP servers from Claude Code..."
    Write-Host ""
    foreach ($srv in $Servers) {
        $name = $srv.Name
        Write-Info "Removing $name"
        try {
            & claude mcp remove --scope user $name 2>$null
        } catch {
            Write-Warn "  $name was not registered (or already removed)."
        }
        # Also check exit code for non-terminating errors
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Warn "  $name was not registered (or already removed)."
        }
    }
    Write-Host ""
    Write-Info "All MCP servers unregistered from Claude Code."
}
