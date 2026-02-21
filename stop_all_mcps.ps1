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
    Stop all Kit USD Agents MCP servers that were started by start_all_mcps.ps1.

.DESCRIPTION
    Sends a graceful stop first, waits up to 5 seconds, then force-kills if the
    process is still running. Also checks ports for any orphaned processes and
    cleans those up too.

.EXAMPLE
    .\stop_all_mcps.ps1
#>

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$McpDir = Join-Path $ScriptDir "source\mcp"
$PidDir = Join-Path $McpDir ".mcp-pids"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Message) Write-Host "[INFO] " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn  { param([string]$Message) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Err   { param([string]$Message) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $Message }

# ---------------------------------------------------------------------------
# Server definitions (must match start_all_mcps.ps1)
# ---------------------------------------------------------------------------
$Servers = @(
    @{ Name = "omni-ui-mcp"; Port = 9901 },
    @{ Name = "kit-mcp";     Port = 9902 },
    @{ Name = "usd-code-mcp"; Port = 9903 }
)

$GracePeriod = 5  # seconds to wait for graceful shutdown

# ---------------------------------------------------------------------------
# Helper: Get PID listening on a port
# ---------------------------------------------------------------------------
function Get-PortPid {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { return $conn.OwningProcess }
    } catch {}
    return $null
}

# ---------------------------------------------------------------------------
# Helper: Check if a process is alive
# ---------------------------------------------------------------------------
function Test-ProcessAlive {
    param([int]$Pid_)
    try {
        $p = Get-Process -Id $Pid_ -ErrorAction SilentlyContinue
        return ($null -ne $p -and -not $p.HasExited)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Helper: Kill a PID with grace period
# ---------------------------------------------------------------------------
function Stop-PidGraceful {
    param([int]$Pid_, [string]$Label)

    # Try graceful stop first
    try { Stop-Process -Id $Pid_ -ErrorAction SilentlyContinue } catch {}

    $elapsed = 0
    while ($elapsed -lt $GracePeriod) {
        if (-not (Test-ProcessAlive $Pid_)) {
            return $true
        }
        Start-Sleep -Seconds 1
        $elapsed++
    }

    if (Test-ProcessAlive $Pid_) {
        Write-Warn "${Label}: Still running after ${GracePeriod}s. Force-killing..."
        try { Stop-Process -Id $Pid_ -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 1
    }

    return -not (Test-ProcessAlive $Pid_)
}

Write-Host "========================================"
Write-Host "Kit USD Agents - Stop All MCP Servers"
Write-Host "========================================"
Write-Host ""

$StoppedCount = 0

foreach ($srv in $Servers) {
    $name = $srv.Name
    $port = $srv.Port
    $pidFile = Join-Path $PidDir "$name.pid"

    # --- Phase 1: Kill tracked PID from PID file ---
    if (Test-Path $pidFile) {
        $pid_ = [int](Get-Content $pidFile -Raw).Trim()

        if (Test-ProcessAlive $pid_) {
            Write-Info "${name}: Stopping PID $pid_..."
            if (Stop-PidGraceful -Pid_ $pid_ -Label $name) {
                Write-Info "${name}: Stopped PID $pid_."
            } else {
                Write-Err "${name}: Failed to stop PID $pid_!"
            }
        } else {
            Write-Warn "${name}: PID $pid_ is not running (stale PID file)."
        }

        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    # --- Phase 2: Check port for any remaining/orphaned process ---
    $portPid = Get-PortPid -Port $port
    if ($portPid) {
        Write-Warn "${name}: Orphaned process $portPid still on port $port. Killing..."
        if (Stop-PidGraceful -Pid_ $portPid -Label "$name (port $port)") {
            Write-Info "${name}: Orphaned process on port $port stopped."
        } else {
            Write-Err "${name}: Failed to stop orphaned process on port $port!"
        }
    }

    # --- Final status ---
    $stillUsed = Get-PortPid -Port $port
    if (-not $stillUsed) {
        $StoppedCount++
    }

    # Clean up launch script if it exists
    $launchScript = Join-Path $PidDir "$name-launch.ps1"
    if (Test-Path $launchScript) {
        Remove-Item $launchScript -Force -ErrorAction SilentlyContinue
    }
}

# Clean up PID directory if empty
if (Test-Path $PidDir) {
    $remaining = Get-ChildItem $PidDir -ErrorAction SilentlyContinue
    if (-not $remaining -or $remaining.Count -eq 0) {
        Remove-Item $PidDir -Force -ErrorAction SilentlyContinue
    }
}

# --- Final port verification ---
Write-Host ""
$allClear = $true
foreach ($srv in $Servers) {
    $name = $srv.Name
    $port = $srv.Port
    $portPid = Get-PortPid -Port $port
    if ($portPid) {
        Write-Err "${name}: Port $port is STILL in use!"
        $allClear = $false
    }
}

if ($allClear) {
    Write-Info "All MCP servers stopped. Ports 9901-9903 are free."
} else {
    Write-Err "Some ports could not be freed. Check with: Get-NetTCPConnection -LocalPort 9901,9902,9903"
}
