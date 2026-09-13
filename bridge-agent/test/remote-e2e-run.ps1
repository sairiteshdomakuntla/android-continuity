# End-to-end runner for the remote-input (trackpad) pipeline.
# Run from bridge-agent/:  pwsh test/remote-e2e-run.ps1
#
# What it does:
#   1. Rebuilds the app (vite build)
#   2. Temporarily sets aside paired_devices.enc so the app boots UNPAIRED
#      (plaintext socket mode — what the phone produces after AES decryption).
#      The file is always restored afterwards.
#   3. Launches the real Electron app, runs test/remote-e2e-client.mjs
#      (synthetic phone: moves, coalescing, scroll, clicks)
#   4. Asserts click dispatch + native init from the app log
#
# Requirements: nothing else may be listening on port 4000, and the Bridge
# app should not be running.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$realFile = Join-Path $env:APPDATA 'Bridge Agent\paired_devices.enc'
if (-not (Test-Path $realFile)) { throw "paired_devices.enc not found at $realFile" }
$backup = "$realFile.e2e-backup"
if (Test-NetConnection -ComputerName 127.0.0.1 -Port 4000 -InformationLevel Quiet -WarningAction SilentlyContinue) {
  throw 'Port 4000 already in use - stop the running Bridge app first.'
}

Write-Output '== building app =='
npx vite build | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'vite build failed' }

$tempRoot = Join-Path $env:TEMP 'bridge-remote-e2e'
if (Test-Path $tempRoot) { Remove-Item -Recurse -Force $tempRoot }
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$outLog = "$tempRoot\app-stdout.log"
$errLog = "$tempRoot\app-stderr.log"
$clientExit = 1

try {
  Move-Item -LiteralPath $realFile -Destination $backup
  Write-Output 'paired_devices.enc set aside for isolated E2E run'

  $electron = Join-Path $root 'node_modules\electron\dist\electron.exe'
  $p = Start-Process -FilePath $electron -ArgumentList '.', '--enable-logging' -WorkingDirectory $root -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
  Write-Output "launched electron pid=$($p.Id)"

  $up = $false
  foreach ($i in 1..60) {
    try { $t = New-Object Net.Sockets.TcpClient('127.0.0.1', 4000); $t.Close(); $up = $true; break } catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $up) { throw 'App never opened port 4000' }
  Write-Output 'socket server is up'

  node test/remote-e2e-client.mjs
  $clientExit = $LASTEXITCODE
  Write-Output "client exit=$clientExit"

  Start-Sleep -Milliseconds 500
  taskkill /PID $p.Id /T /F 2>&1 | Out-Null
  Start-Sleep -Milliseconds 800
} finally {
  if (Test-Path $backup) { Move-Item -LiteralPath $backup -Destination $realFile -Force; Write-Output 'paired_devices.enc restored' }
}

# App-log assertions (only RemoteInput lines count as failures; the app has a
# pre-existing benign warning about a missing electron-vite.svg icon)
$allLog = @(Get-Content $outLog) + @(Get-Content $errLog)
$native = ($allLog | Select-String -SimpleMatch '[RemoteInput] nut-js native input layer ready').Count
$clickL = ($allLog | Select-String -SimpleMatch '[RemoteInput] Click: left').Count
$clickR = ($allLog | Select-String -SimpleMatch '[RemoteInput] Click: right').Count
$keys   = ($allLog | Select-String -SimpleMatch '[RemoteInput] Key input:').Count
$specials = ($allLog | Select-String -SimpleMatch '[RemoteInput] Key: ').Count
$media  = ($allLog | Select-String -SimpleMatch '[RemoteInput] Media: ').Count
$fails  = ($allLog | Select-String -Pattern '\[RemoteInput\].*failed').Count
Write-Output "app-log assertions: native-ready=$native click-left=$clickL click-right=$clickR key-input=$keys key-special=$specials media=$media remoteinput-failures=$fails"
Write-Output '=== APP LOG (filtered) ==='
$allLog | Where-Object { $_ -match 'RemoteInput|Main\]|Dropping|Decryption' } | Select-Object -First 40

if ($clientExit -ne 0 -or $native -lt 1 -or $clickL -lt 1 -or $clickR -lt 1 -or $keys -lt 1 -or $specials -lt 3 -or $media -lt 6 -or $fails -gt 0) {
  Write-Output 'E2E: FAILED'
  exit 1
}
Write-Output 'E2E: PASSED'
exit 0
