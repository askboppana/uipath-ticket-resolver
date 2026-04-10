#!/usr/bin/env pwsh
# setup-runner-windows.ps1 - Set up a GitHub Actions self-hosted runner on Windows
# Downloads the runner, configures it, and installs it as a Windows service.

param(
    [Parameter(Mandatory=$true)]
    [string]$Url,

    [Parameter(Mandatory=$true)]
    [string]$Token,

    [Parameter(Mandatory=$false)]
    [string]$Name = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [string]$Labels = "self-hosted,windows,x64"
)

$ErrorActionPreference = "Stop"

$RunnerVersion = if ($env:RUNNER_VERSION) { $env:RUNNER_VERSION } else { "2.319.1" }
$RunnerDir = if ($env:RUNNER_DIR) { $env:RUNNER_DIR } else { "C:\actions-runner" }

Write-Host "[INFO] Runner configuration:"
Write-Host "  URL:     $Url"
Write-Host "  Name:    $Name"
Write-Host "  Labels:  $Labels"
Write-Host "  Version: $RunnerVersion"
Write-Host "  Dir:     $RunnerDir"
Write-Host ""

# --- Create runner directory ---
Write-Host "[INFO] Creating runner directory: $RunnerDir"
if (-not (Test-Path $RunnerDir)) {
    New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
}
Set-Location $RunnerDir

# --- Download runner ---
Write-Host "[INFO] Downloading GitHub Actions runner..."
$RunnerZip = "actions-runner-win-x64-$RunnerVersion.zip"
$RunnerUrl = "https://github.com/actions/runner/releases/download/v$RunnerVersion/$RunnerZip"

Write-Host "[INFO] Download URL: $RunnerUrl"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $RunnerUrl -OutFile $RunnerZip -UseBasicParsing
    Write-Host "[PASS] Runner downloaded successfully"
} catch {
    Write-Host "[FAIL] Failed to download runner: $_"
    exit 1
}

# --- Extract runner ---
Write-Host "[INFO] Extracting runner..."
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory(
        (Join-Path $RunnerDir $RunnerZip),
        $RunnerDir
    )
    Remove-Item $RunnerZip -Force
    Write-Host "[PASS] Runner extracted successfully"
} catch {
    Write-Host "[FAIL] Failed to extract runner: $_"
    exit 1
}

# --- Configure runner ---
Write-Host "[INFO] Configuring runner..."
try {
    $configArgs = @(
        "--url", $Url,
        "--token", $Token,
        "--name", $Name,
        "--labels", $Labels,
        "--unattended",
        "--replace"
    )
    & "$RunnerDir\config.cmd" @configArgs
    if ($LASTEXITCODE -ne 0) {
        throw "config.cmd exited with code $LASTEXITCODE"
    }
    Write-Host "[PASS] Runner configured successfully"
} catch {
    Write-Host "[FAIL] Runner configuration failed: $_"
    exit 1
}

# --- Install as Windows service ---
Write-Host "[INFO] Installing runner as Windows service..."
try {
    $svcScript = Join-Path $RunnerDir "svc.cmd"

    # Install the service
    & $svcScript install
    if ($LASTEXITCODE -ne 0) {
        throw "Service install failed with exit code $LASTEXITCODE"
    }
    Write-Host "[PASS] Runner service installed"

    # Start the service
    & $svcScript start
    if ($LASTEXITCODE -ne 0) {
        throw "Service start failed with exit code $LASTEXITCODE"
    }
    Write-Host "[PASS] Runner service started"
} catch {
    Write-Host "[FAIL] Service installation failed: $_"
    Write-Host "[INFO] You can start the runner manually with: $RunnerDir\run.cmd"
    exit 1
}

# --- Verify setup ---
Write-Host ""
Write-Host "=== Setup Complete ==="
Write-Host "[INFO] Runner name:   $Name"
Write-Host "[INFO] Runner labels: $Labels"
Write-Host "[INFO] Runner dir:    $RunnerDir"
Write-Host ""

# Check service status
try {
    $serviceName = "actions.runner.*"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host "[INFO] Service name:   $($service.Name)"
        Write-Host "[INFO] Service status: $($service.Status)"
        if ($service.Status -eq "Running") {
            Write-Host "[PASS] Runner service is running"
        } else {
            Write-Host "[FAIL] Runner service is not running"
        }
    } else {
        Write-Host "[INFO] Could not query service status (wildcard lookup)"
    }
} catch {
    Write-Host "[INFO] Could not verify service status: $_"
}

Write-Host ""
Write-Host "[PASS] Windows self-hosted runner setup complete"
exit 0
