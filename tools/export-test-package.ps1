[CmdletBinding()]
param(
    [string]$DestinationDirectory = (Join-Path $PSScriptRoot "..\dist\KBC-rakv0-status-script")
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$dataDirectory = Join-Path $repositoryRoot "data"
$scriptPath = Join-Path $repositoryRoot "lua\kbc-status-test.lua"

if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory "unit-names.csv"))) {
    throw "先に tools/build-data.ps1 を実行してください。"
}

New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $DestinationDirectory "lua") -Force | Out-Null
$destinationDataDirectory = Join-Path $DestinationDirectory "data"
$destinationUnitsDirectory = Join-Path $destinationDataDirectory "units"
New-Item -ItemType Directory -Path $destinationUnitsDirectory -Force | Out-Null

Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $DestinationDirectory "lua\kbc-status-test.lua") -Force
Copy-Item -LiteralPath (Join-Path $dataDirectory "unit-names.csv") -Destination (Join-Path $destinationDataDirectory "unit-names.csv") -Force
Get-ChildItem -LiteralPath (Join-Path $dataDirectory "units") -File -Filter "unit*.csv" |
    Copy-Item -Destination $destinationUnitsDirectory -Force

Write-Host "Androidへコピーするフォルダを作成しました: $DestinationDirectory"
