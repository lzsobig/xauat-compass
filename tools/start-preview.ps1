param([switch]$OpenBrowser)

$ErrorActionPreference = 'Stop'
$compassWorkspace = Split-Path -Parent $PSScriptRoot
$compassPort = 4173
$compassEnvFile = Join-Path $compassWorkspace '.env'
if (Test-Path -LiteralPath $compassEnvFile) {
    $compassPortLine = Get-Content -LiteralPath $compassEnvFile | Where-Object { $_ -match '^PORT=\d+$' } | Select-Object -First 1
    if ($compassPortLine) { $compassPort = [int]($compassPortLine.Split('=')[1]) }
}
$compassAddress = "http://127.0.0.1:$compassPort"
$compassListener = Get-NetTCPConnection -State Listen -LocalPort $compassPort -ErrorAction SilentlyContinue | Select-Object -First 1
if ($compassListener) {
    $compassExisting = Get-CimInstance Win32_Process -Filter "ProcessId = $($compassListener.OwningProcess)"
    if ($compassExisting.CommandLine -notmatch 'server[/\\]index\.mjs') {
        throw "Port $compassPort is occupied by another application."
    }
} else {
    $compassNodePath = (Get-Command node -ErrorAction Stop).Source
    $compassStartup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $compassCommand = '"' + $compassNodePath + '" --env-file-if-exists=.env "server/index.mjs"'
    $compassResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $compassCommand
        CurrentDirectory = $compassWorkspace
        ProcessStartupInformation = $compassStartup
    }
    if ($compassResult.ReturnValue -ne 0) { throw "Could not start preview (Windows result $($compassResult.ReturnValue))." }
}

$compassReady = $false
for ($compassAttempt = 0; $compassAttempt -lt 15; $compassAttempt++) {
    try {
        $compassResponse = Invoke-WebRequest -Uri "$compassAddress/api/capabilities" -TimeoutSec 2
        if ($compassResponse.StatusCode -eq 200) { $compassReady = $true; break }
    } catch { Start-Sleep -Milliseconds 300 }
}
if (-not $compassReady) { throw 'Preview started but did not respond. Run npm start in the project directory to inspect the error.' }
Write-Output "Compass preview ready: $compassAddress"
if ($OpenBrowser) { Start-Process "$compassAddress/#home" }
