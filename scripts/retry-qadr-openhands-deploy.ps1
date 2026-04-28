param(
    [int]$DurationMinutes = -1,
    [int]$IntervalMinutes = 5,
    [string]$Password = "",
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $repoRoot "output"
$null = New-Item -ItemType Directory -Force -Path $logDir
if (-not $LogPath) {
    $LogPath = Join-Path $logDir ("openhands-retry-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
}

if (-not $Password) {
    $helperPath = "C:\Users\MSI\Documents\New project\QADR\qadr_askpass_syncfinal.cmd"
    if (Test-Path $helperPath) {
        $Password = ((Get-Content $helperPath -Raw) -replace '@echo\s*', '').Trim()
    }
}

$targets = @(
    @{ Host = "ssh.gantor.ir"; Port = 22 },
    @{ Host = "5.235.208.128"; Port = 22 },
    @{ Host = "ssh.freegpt.ir"; Port = 22 },
    @{ Host = "10.66.66.1"; Port = 22 },
    @{ Host = "192.168.1.200"; Port = 22 },
    @{ Host = "5.235.208.128"; Port = 2222 },
    @{ Host = "5.235.208.128"; Port = 22022 },
    @{ Host = "ssh.gantor.ir"; Port = 2222 },
    @{ Host = "ssh.gantor.ir"; Port = 22022 }
)

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $line | Tee-Object -FilePath $logPath -Append
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(4000, $false)
        if ($ok -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Invoke-Validation {
    $results = [ordered]@{}
    try {
        $results["health"] = (curl.exe -sS -o NUL -w "%{http_code}" https://hands.gantor.ir/health)
    } catch {
        $results["health"] = "ERROR: $($_.Exception.Message)"
    }
    try {
        $results["auth_session_status"] = (curl.exe -sS -o NUL -w "%{http_code}" https://hands.gantor.ir/auth/session)
    } catch {
        $results["auth_session_status"] = "ERROR: $($_.Exception.Message)"
    }
    try {
        $results["root_status"] = (curl.exe -sS -o NUL -w "%{http_code}" https://hands.gantor.ir/)
    } catch {
        $results["root_status"] = "ERROR: $($_.Exception.Message)"
    }
    try {
        $results["auth_login_status"] = (curl.exe -sS -o NUL -w "%{http_code}" https://hands.gantor.ir/auth/login)
    } catch {
        $results["auth_login_status"] = "ERROR: $($_.Exception.Message)"
    }
    try {
        $results["settings_status"] = (curl.exe -sS -o NUL -w "%{http_code}" https://hands.gantor.ir/api/settings)
    } catch {
        $results["settings_status"] = "ERROR: $($_.Exception.Message)"
    }
    $results.GetEnumerator() | ForEach-Object { Write-Log ("validation {0}={1}" -f $_.Key, $_.Value) }
    return (
        $results["health"] -eq "200" -and
        ($results["auth_session_status"] -eq "401" -or $results["auth_session_status"] -eq "200") -and
        $results["auth_login_status"] -eq "200" -and
        $results["settings_status"] -eq "401" -and
        ($results["root_status"] -eq "302" -or $results["root_status"] -eq "307")
    )
}

if (-not $Password) {
    Write-Log "No SSH password available; retry worker cannot continue."
    exit 1
}

$deadline = $null
if ($DurationMinutes -gt 0) {
    $deadline = (Get-Date).AddMinutes($DurationMinutes)
    Write-Log ("Retry worker started. Deadline={0}" -f $deadline.ToString("yyyy-MM-dd HH:mm:ss"))
} else {
    Write-Log "Retry worker started. Deadline=none"
}

while ($true) {
    if ($deadline -and (Get-Date) -ge $deadline) {
        break
    }
    foreach ($target in $targets) {
        $hostName = [string]$target.Host
        $port = [int]$target.Port
        Write-Log ("probe {0}:{1}" -f $hostName, $port)
        if (-not (Test-TcpPort -HostName $hostName -Port $port)) {
            Write-Log ("closed {0}:{1}" -f $hostName, $port)
            continue
        }

        Write-Log ("open {0}:{1}; starting deploy" -f $hostName, $port)
        try {
            & (Join-Path $PSScriptRoot "publish-to-qadr.ps1") -HostName $hostName -Port $port -Password $Password
            Write-Log ("deploy succeeded via {0}:{1}" -f $hostName, $port)
            if (Invoke-Validation) {
                Write-Log "validation passed; stopping retry worker"
                exit 0
            }
            Write-Log "validation failed after deploy; will retry after interval"
        } catch {
            Write-Log ("deploy failed via {0}:{1} :: {2}" -f $hostName, $port, $_.Exception.Message)
        }
    }

    if ($deadline -and (Get-Date).AddMinutes($IntervalMinutes) -ge $deadline) {
        break
    }

    Write-Log ("sleeping {0} minutes before next retry" -f $IntervalMinutes)
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}

Write-Log "Retry worker finished without a successful deployment."
exit 2
