param(
    [string]$HostName = "ssh.gantor.ir",
    [int]$Port = 22,
    [string]$UserName = "saman",
    [string]$RemoteDir = "/home/saman/workspaces/gantor-openhands",
    [string]$Password = $env:QADR_SSH_PASSWORD
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$archivePath = Join-Path $env:TEMP "gantor-openhands-qadr.tar.gz"
$askpassPath = Join-Path $env:TEMP "qadr-openhands-askpass.cmd"
$sshExe = (Get-Command ssh.exe).Source
$scpExe = (Get-Command scp.exe).Source
$tarExe = (Get-Command tar.exe).Source

if (-not $Password) {
    $secure = Read-Host "QADR SSH password" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

if (-not $Password) {
    throw "SSH password is required."
}

@"
@echo off
echo $Password
"@ | Set-Content -LiteralPath $askpassPath -Encoding ASCII

if (Test-Path $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

Push-Location $repoRoot
try {
    & $tarExe --exclude=".git" --exclude=".venv" --exclude="node_modules" --exclude=".env.qadr" -czf $archivePath .
} finally {
    Pop-Location
}

$env:SSH_ASKPASS = $askpassPath
$env:DISPLAY = "qadr-openhands"
$env:SSH_ASKPASS_REQUIRE = "force"

$remote = "$UserName@$HostName"
$sshOptions = @(
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=10",
    "-o", "ServerAliveCountMax=3"
)

try {
    & $sshExe -p $Port @sshOptions $remote "mkdir -p '$RemoteDir'"
    & $scpExe -P $Port @sshOptions $archivePath "${remote}:/tmp/gantor-openhands-qadr.tar.gz"
    & $sshExe -p $Port @sshOptions $remote @"
set -e
mkdir -p '$RemoteDir'
tar -xzf /tmp/gantor-openhands-qadr.tar.gz -C '$RemoteDir'
cd '$RemoteDir'
bash scripts/deploy-qadr-openhands.sh
"@
} finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $askpassPath -Force -ErrorAction SilentlyContinue
}
