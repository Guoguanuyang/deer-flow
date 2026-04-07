param(
    [switch]$FullTest,
    [switch]$TestsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$backendDir = Join-Path $repoRoot "backend"
$frontendDir = Join-Path $repoRoot "frontend"
$logsDir = Join-Path $repoRoot "logs"

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ""
    Write-Host "==> $Name"
    & $Action
}

function Wait-Port {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSec = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $listener = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq $Port } |
            Select-Object -First 1
        if ($null -ne $listener) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

Push-Location $repoRoot
try {
    Invoke-Step -Name "Run backend tests" -Action {
        Push-Location $backendDir
        try {
            if ($FullTest) {
                uv run pytest -q
            }
            else {
                uv run pytest tests/test_lead_agent_model_resolution.py -q
            }
        }
        finally {
            Pop-Location
        }
    }

    Invoke-Step -Name "Run frontend checks" -Action {
        Push-Location $frontendDir
        try {
            pnpm run check
        }
        finally {
            Pop-Location
        }
    }

    if ($TestsOnly) {
        Write-Host ""
        Write-Host "OK: tests passed. TestsOnly set, skip restart."
        return
    }

    Invoke-Step -Name "Stop old DeerFlow processes" -Action {
        $patterns = @(
            "uvicorn app.gateway.app:app",
            "langgraph dev",
            "next dev",
            "next start",
            "nginx.local.conf"
        )

        $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*deer-flow*" }

        foreach ($proc in $processes) {
            $matched = $false
            foreach ($pat in $patterns) {
                if ($proc.CommandLine -like "*$pat*") {
                    $matched = $true
                    break
                }
            }
            if ($matched) {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 2
    }

    Invoke-Step -Name "Start DeerFlow services" -Action {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

        Start-Process -FilePath "uv" `
            -ArgumentList @("run", "langgraph", "dev", "--no-browser", "--allow-blocking", "--server-log-level", "info", "--no-reload") `
            -WorkingDirectory $backendDir `
            -RedirectStandardOutput (Join-Path $logsDir "langgraph.log") `
            -RedirectStandardError (Join-Path $logsDir "langgraph.err.log") `
            -WindowStyle Hidden

        Start-Process -FilePath "uv" `
            -ArgumentList @("run", "uvicorn", "app.gateway.app:app", "--host", "0.0.0.0", "--port", "8001", "--reload") `
            -WorkingDirectory $backendDir `
            -RedirectStandardOutput (Join-Path $logsDir "gateway.log") `
            -RedirectStandardError (Join-Path $logsDir "gateway.err.log") `
            -WindowStyle Hidden

        Start-Process -FilePath "pnpm.cmd" `
            -ArgumentList @("run", "dev") `
            -WorkingDirectory $frontendDir `
            -RedirectStandardOutput (Join-Path $logsDir "frontend.log") `
            -RedirectStandardError (Join-Path $logsDir "frontend.err.log") `
            -WindowStyle Hidden

        $nginxConf = Join-Path $repoRoot "docker/nginx/nginx.local.conf"
        Start-Process -FilePath "nginx" `
            -ArgumentList @("-g", '"daemon off;"', "-c", $nginxConf, "-p", $repoRoot) `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput (Join-Path $logsDir "nginx.log") `
            -RedirectStandardError (Join-Path $logsDir "nginx.err.log") `
            -WindowStyle Hidden
    }

    Invoke-Step -Name "Wait for ports" -Action {
        $checks = @(
            @{ Name = "LangGraph"; Port = 2024; TimeoutSec = 90 },
            @{ Name = "Gateway"; Port = 8001; TimeoutSec = 60 },
            @{ Name = "Frontend"; Port = 3000; TimeoutSec = 180 },
            @{ Name = "Nginx"; Port = 2026; TimeoutSec = 30 }
        )

        foreach ($check in $checks) {
            if (-not (Wait-Port -Port $check.Port -TimeoutSec $check.TimeoutSec)) {
                throw "$($check.Name) startup timeout on port $($check.Port)."
            }
        }
    }

    Write-Host ""
    Write-Host "OK: tests passed and services are running."
    Write-Host "URL: http://localhost:2026"
    Write-Host "Logs: $logsDir"
}
finally {
    Pop-Location
}
