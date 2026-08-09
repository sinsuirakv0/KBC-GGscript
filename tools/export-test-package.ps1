[CmdletBinding()]
param(
    [string]$DestinationDirectory = (Join-Path $PSScriptRoot "..\dist\KBC-rakv0-status-script")
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$dataDirectory = Join-Path $repositoryRoot "data"
$scriptPath = Join-Path $repositoryRoot "lua\kbc-status-test.lua"

if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory "names\Unit_Explanation1_ja.csv"))) {
    throw "先に tools/build-data.ps1 を実行してください。"
}
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory "status-fields.csv"))) {
    throw "data/status-fields.csv が見つかりません。"
}
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory "unit-index.csv"))) {
    throw "data/unit-index.csv が見つかりません。tools/build-unit-index.ps1 を実行してください。"
}

New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $DestinationDirectory "lua") -Force | Out-Null
$destinationDataDirectory = Join-Path $DestinationDirectory "data"
$destinationUnitsDirectory = Join-Path $destinationDataDirectory "units"
$destinationNamesDirectory = Join-Path $destinationDataDirectory "names"
New-Item -ItemType Directory -Path $destinationUnitsDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $destinationNamesDirectory -Force | Out-Null
$legacyNameIndex = Join-Path $destinationDataDirectory "unit-names.csv"
if ([System.IO.File]::Exists($legacyNameIndex)) {
    [System.IO.File]::Delete($legacyNameIndex)
}

Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $DestinationDirectory "lua\kbc-status-test.lua") -Force
Copy-Item -LiteralPath (Join-Path $dataDirectory "status-fields.csv") -Destination (Join-Path $destinationDataDirectory "status-fields.csv") -Force
Copy-Item -LiteralPath (Join-Path $dataDirectory "unit-index.csv") -Destination (Join-Path $destinationDataDirectory "unit-index.csv") -Force
Get-ChildItem -LiteralPath (Join-Path $dataDirectory "units") -File -Filter "unit*.csv" |
    Copy-Item -Destination $destinationUnitsDirectory -Force
Get-ChildItem -LiteralPath (Join-Path $dataDirectory "names") -File -Filter "Unit_Explanation*_ja.csv" |
    Copy-Item -Destination $destinationNamesDirectory -Force

Write-Host "Androidへコピーするフォルダを作成しました: $DestinationDirectory"
