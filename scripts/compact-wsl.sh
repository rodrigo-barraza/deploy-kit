#!/bin/bash
# Start compaction in Windows, outside the WSL instance that will be stopped.
set -euo pipefail
for command in powershell.exe iconv base64; do
  command -v "$command" >/dev/null || { echo "Cannot compact WSL: $command is unavailable" >&2; exit 1; }
done
payload=$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds 8
$disk = Get-ChildItem -Path "$env:LOCALAPPDATA\Docker\wsl" -Filter '*.vhdx' -Recurse -ErrorAction Stop | Select-Object -First 1 -ExpandProperty FullName
if (-not $disk) { throw 'Docker VHDX not found' }
wsl.exe --shutdown
if ($LASTEXITCODE -ne 0) { throw 'WSL shutdown failed' }
Optimize-VHD -Path $disk -Mode Full
Write-Host "Compacted $disk"
POWERSHELL
)
encoded=$(printf '%s' "$payload" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
# The encoded payload survives WSL shutdown; no script file on a WSL share is
# accessed by the detached Windows process. Its window retains any error.
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-NoExit','-EncodedCommand','$encoded'"
echo 'Compaction scheduled in a separate Windows window; WSL will shut down in 8 seconds.'
