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
    Start all Kit USD Agents MCP servers as background processes.

.DESCRIPTION
    This script validates the Python environment, installs Poetry if needed,
    sets up virtual environments on first run, and launches all three MCP
    servers in the background. Servers survive the script exiting but do
    NOT survive a reboot.

.EXAMPLE
    .\start_all_mcps.ps1
#>

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$McpDir = Join-Path $ScriptDir "source\mcp"
$PidDir = Join-Path $McpDir ".mcp-pids"
$LogDir = Join-Path $McpDir ".mcp-logs"

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
    @{ Name = "omni-ui-mcp"; Dir = "omni_ui_mcp"; Entry = "omni-ui-aiq"; Port = 9901; ConfigDir = "workflow"; LogEnv = "OMNI_UI_DISABLE_USAGE_LOGGING" },
    @{ Name = "kit-mcp";     Dir = "kit_mcp";     Entry = "kit-mcp";     Port = 9902; ConfigDir = "workflows"; LogEnv = "KIT_MCP_DISABLE_USAGE_LOGGING" },
    @{ Name = "usd-code-mcp"; Dir = "usd_code_mcp"; Entry = "usd-code-mcp"; Port = 9903; ConfigDir = "workflow"; LogEnv = "USD_CODE_MCP_DISABLE_USAGE_LOGGING" }
)

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
# Refresh PATH from registry so newly-installed tools are visible even in
# shells that were started before the install (e.g. IDE terminals, CI agents).
# ---------------------------------------------------------------------------
$userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
$machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($userPath -or $machinePath) {
    $env:PATH = ($userPath, $machinePath, $env:PATH | Where-Object { $_ }) -join ';'
}

# ---------------------------------------------------------------------------
# Step 1: Find the best qualifying Python (>=3.11, <3.14)
# ---------------------------------------------------------------------------
Write-Host "========================================"
Write-Host "Kit USD Agents - Start All MCP Servers"
Write-Host "========================================"
Write-Host ""

function Find-BestPython {
    $bestCmd = $null
    $bestMinor = 0

    foreach ($candidate in @("python", "python3", "py")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }

        try {
            if ($candidate -eq "py") {
                # Windows py launcher: try py -3
                $ver = & py -3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            } else {
                $ver = & $candidate -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            }
            if (-not $ver) { continue }

            $parts = $ver.Split(".")
            $major = [int]$parts[0]
            $minor = [int]$parts[1]

            if ($major -eq 3 -and $minor -ge 11 -and $minor -lt 14) {
                if ($minor -gt $bestMinor) {
                    $bestMinor = $minor
                    $bestCmd = $candidate
                }
            }
        } catch {
            continue
        }
    }

    if (-not $bestCmd) {
        Write-Err "No qualifying Python found on PATH."
        Write-Host "  Requires Python >=3.11, <3.14 (3.12 recommended)."
        Write-Host "  Checked: python, python3, py"
        Write-Host "  Visit: https://www.python.org/downloads/"
        exit 1
    }

    return $bestCmd
}

$PythonCmd = Find-BestPython

# For the py launcher, always use "py -3" to invoke
if ($PythonCmd -eq "py") {
    $PythonVersion = & py -3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
    Write-Info "Using py -3 (Python $PythonVersion)"
} else {
    $PythonVersion = & $PythonCmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
    Write-Info "Using $PythonCmd (Python $PythonVersion)"
}

# ---------------------------------------------------------------------------
# Step 2: Ensure Poetry is available
# ---------------------------------------------------------------------------
if (-not (Get-Command poetry -ErrorAction SilentlyContinue)) {
    Write-Info "Poetry not found. Installing Poetry..."

    try {
        $installScript = (Invoke-WebRequest -Uri "https://install.python-poetry.org" -UseBasicParsing).Content
        if ($PythonCmd -eq "py") {
            $installScript | & py -3 -
        } else {
            $installScript | & $PythonCmd -
        }
    } catch {
        Write-Err "Failed to download/run Poetry installer."
        Write-Host "  Install manually: https://python-poetry.org/docs/#installation"
        exit 1
    }

    # Poetry installs to %APPDATA%\Python\Scripts on Windows
    $poetryPath = Join-Path $env:APPDATA "Python\Scripts"
    if (Test-Path $poetryPath) {
        $env:PATH = "$poetryPath;$env:PATH"
    }

    if (-not (Get-Command poetry -ErrorAction SilentlyContinue)) {
        Write-Err "Failed to install Poetry or Poetry not in PATH."
        Write-Host "  Install manually: https://python-poetry.org/docs/#installation"
        Write-Host "  Or add Poetry to your PATH and re-run this script."
        exit 1
    }

    Write-Info "Poetry installed successfully!"
}

$poetryVer = & poetry --version
Write-Info "Poetry version: $poetryVer"

# ---------------------------------------------------------------------------
# Step 3: Ensure NVIDIA_API_KEY is set
# ---------------------------------------------------------------------------
# Check current env first, then fall back to the Windows user registry
if (-not $env:NVIDIA_API_KEY) {
    $regKey = [System.Environment]::GetEnvironmentVariable('NVIDIA_API_KEY', 'User')
    if ($regKey) {
        $env:NVIDIA_API_KEY = $regKey
        Write-Info "NVIDIA_API_KEY loaded from user environment."
    }
}

if (-not $env:NVIDIA_API_KEY) {
    Write-Host ""
    Write-Warn "NVIDIA_API_KEY is not set."
    Write-Host "  The MCP servers require an NVIDIA API key for embedding and reranking models."
    Write-Host "  Get one at: https://build.nvidia.com"
    Write-Host ""

    # Check if running interactively
    if ([Environment]::UserInteractive) {
        $key = Read-Host -Prompt "Enter your NVIDIA_API_KEY"
        if (-not $key) {
            Write-Err "No API key provided. Exiting."
            exit 1
        }
        $env:NVIDIA_API_KEY = $key
        Write-Info "NVIDIA_API_KEY set for this session."
    } else {
        Write-Err "NVIDIA_API_KEY is not set and session is not interactive."
        Write-Host '  Set it with:  $env:NVIDIA_API_KEY = "nvapi-..."'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Step 4: Create runtime directories
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $PidDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Configure Poetry once (global setting, matches setup-dev.sh)
& poetry config virtualenvs.in-project true

# ---------------------------------------------------------------------------
# Step 5: Set up and launch each server
# ---------------------------------------------------------------------------
$StartedCount = 0
$SkippedCount = 0
$FailedCount = 0

Write-Host ""

foreach ($srv in $Servers) {
    $name = $srv.Name
    $dir = Join-Path $McpDir $srv.Dir
    $entry = $srv.Entry
    $port = $srv.Port
    $configDir = $srv.ConfigDir
    $logEnv = $srv.LogEnv
    $pidFile = Join-Path $PidDir "$name.pid"
    $logFile = Join-Path $LogDir "$name.log"

    Write-Info "--- $name (port $port) ---"

    # Check if already running (via PID file)
    if (Test-Path $pidFile) {
        $existingPid = [int](Get-Content $pidFile -Raw).Trim()
        if (Test-ProcessAlive $existingPid) {
            Write-Warn "$name is already running (PID $existingPid). Skipping."
            $SkippedCount++
            Write-Host ""
            continue
        } else {
            Write-Warn "Stale PID file found for $name. Cleaning up."
            Remove-Item $pidFile -Force
        }
    }

    # Check if port is already in use
    $portPid = Get-PortPid -Port $port
    if ($portPid) {
        Write-Warn "Port $port is already in use by PID $portPid."
        Write-Warn "Killing existing process on port $port..."
        try {
            Stop-Process -Id $portPid -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        } catch {}

        $portPid = Get-PortPid -Port $port
        if ($portPid) {
            Write-Warn "Force-killing process on port $port..."
            try {
                Stop-Process -Id $portPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            } catch {}
        }

        $portPid = Get-PortPid -Port $port
        if ($portPid) {
            Write-Err "Cannot free port $port. Skipping $name."
            $FailedCount++
            Write-Host ""
            continue
        }
        Write-Info "Port $port freed."
    }

    # Set up virtual environment if missing or incomplete
    $needsInstall = $false
    $venvDir = Join-Path $dir ".venv"
    $entryExe = Join-Path $venvDir "Scripts\$entry.exe"

    if (-not (Test-Path $venvDir)) {
        $needsInstall = $true
    } elseif (-not (Test-Path $entryExe)) {
        Write-Warn "Virtual environment exists but $entry is not installed. Re-running poetry install..."
        $needsInstall = $true
    }

    if ($needsInstall) {
        Write-Info "Setting up virtual environment for $name (first run - this may take a few minutes)..."
        try {
            Push-Location $dir
            & poetry install
            if ($LASTEXITCODE -ne 0) { throw "poetry install failed" }
            Pop-Location
        } catch {
            Pop-Location
            Write-Err "Failed to set up virtual environment for $name. Skipping."
            $FailedCount++
            Write-Host ""
            continue
        }
    } else {
        Write-Info "Virtual environment ready for $name."
    }

    # Determine config file
    $localConfig = Join-Path $dir "$configDir\local_config.yaml"
    $defaultConfig = Join-Path $dir "$configDir\config.yaml"
    if (Test-Path $localConfig) {
        $configFile = "$configDir\local_config.yaml"
    } else {
        $configFile = "$configDir\config.yaml"
    }

    Write-Info "Config: $configFile"

    # Launch the server in the background.
    # We spawn a new powershell process that sets env vars and runs poetry run <entry> <config>.
    # Output is redirected to the log file.
    $launchCmd = @"
Set-Location '$dir'
`$env:MCP_PORT = '$port'
`$env:NVIDIA_API_KEY = '$($env:NVIDIA_API_KEY)'
`$env:$logEnv = 'false'
poetry run $entry $configFile
"@

    # Write the launch script to a temp file so Start-Process can run it
    $launchScript = Join-Path $PidDir "$name-launch.ps1"
    Set-Content -Path $launchScript -Value $launchCmd -Force

    $proc = Start-Process powershell -ArgumentList "-ExecutionPolicy", "Bypass", "-NoProfile", "-File", $launchScript `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError (Join-Path $LogDir "$name-err.log")

    $proc.Id | Out-File -FilePath $pidFile -NoNewline

    # Wait for the server to load indexes and bind its port
    Start-Sleep -Seconds 5

    # Find the actual process listening on the port
    $natPid = Get-PortPid -Port $port
    if ($natPid) {
        Write-Info "$name started (PID $natPid, port $port)"
        $natPid | Out-File -FilePath $pidFile -NoNewline
        $StartedCount++
    } elseif (Test-ProcessAlive $proc.Id) {
        # Process is alive but not yet listening - keep wrapper PID
        Write-Warn "$name process running (PID $($proc.Id)) but not yet listening on port $port."
        $StartedCount++
    } else {
        Write-Err "$name failed to start. Check log: $logFile"
        if (Test-Path $logFile) {
            Get-Content $logFile -Tail 15 | ForEach-Object { Write-Host "  $_" }
        }
        $errLog = Join-Path $LogDir "$name-err.log"
        if (Test-Path $errLog) {
            Write-Host "  --- stderr ---"
            Get-Content $errLog -Tail 15 | ForEach-Object { Write-Host "  $_" }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        $FailedCount++
    }

    Write-Host ""
}

# ---------------------------------------------------------------------------
# Step 6: Final health check and summary
# ---------------------------------------------------------------------------
$RunningCount = 0
$DeadCount = 0

Write-Host "========================================"
Write-Host "MCP Server Status Summary"
Write-Host "========================================"
Write-Host ""

$headerFmt = "  {0,-15} {1,-6} {2,-12} {3}"
Write-Host ($headerFmt -f "SERVER", "PORT", "STATUS", "LOG FILE") -ForegroundColor Cyan
Write-Host ($headerFmt -f "------", "----", "------", "--------")

foreach ($srv in $Servers) {
    $name = $srv.Name
    $port = $srv.Port
    $pidFile = Join-Path $PidDir "$name.pid"
    $logFile = Join-Path $LogDir "$name.log"

    if (Test-Path $pidFile) {
        $pid_ = [int](Get-Content $pidFile -Raw).Trim()
        if (Test-ProcessAlive $pid_) {
            Write-Host ("  {0,-15} {1,-6} {2,-12}" -f $name, $port, "UP ($pid_)") -ForegroundColor Green -NoNewline
            Write-Host " $logFile"
            $RunningCount++
        } else {
            Write-Host ("  {0,-15} {1,-6} {2,-12}" -f $name, $port, "DEAD") -ForegroundColor Red -NoNewline
            Write-Host " $logFile"
            $DeadCount++
        }
    } else {
        Write-Host ("  {0,-15} {1,-6} {2,-12}" -f $name, $port, "FAILED") -ForegroundColor Red -NoNewline
        Write-Host " $logFile"
        $DeadCount++
    }
}

Write-Host ""
if ($RunningCount -eq $Servers.Count) {
    Write-Info "All $RunningCount servers are running."
} elseif ($RunningCount -gt 0) {
    Write-Warn "$RunningCount/$($Servers.Count) servers running. $DeadCount failed - check logs above."
} else {
    Write-Err "No servers are running. Check logs for errors."
}
Write-Host ""
Write-Host "To stop all servers:     .\stop_all_mcps.ps1"
Write-Host "To view logs:            Get-Content $LogDir\<server-name>.log -Tail 50"
Write-Host "To register with Claude: .\configure_claude_mcps.ps1 add"
