[CmdletBinding()]
param(
    [string]$SourceDirectory = "D:\storage\にゃんこ大戦争 data\にゃんこ大戦争 v.15.5.1\decrypt\DataLocal",
    [string]$DestinationDirectory = (Join-Path $PSScriptRoot "..\data")
)

$ErrorActionPreference = "Stop"

# unit*.csv のCSV列番号。ネイティブ側の0x1d4バイトのレコードに合わせる。
$recordColumnCount = 117
$recordDefaults = @{
    55  = -1
    57  = -1
    63  = 1
    66  = -1
    110 = -1
}
$recordMultipliers = @{
    2  = 2
    4  = 2
    5  = 4
    6  = 100
    7  = 2
    9  = 4
    44 = 4
    45 = 4
}

function Convert-UnitRow {
    param([string]$Line)

    $rawPart = ($Line -split "//", 2)[0]
    $rawValues = $rawPart.Split(",")
    $values = New-Object System.Collections.Generic.List[int]

    for ($column = 0; $column -lt $recordColumnCount; $column++) {
        $value = if ($recordDefaults.ContainsKey($column)) { $recordDefaults[$column] } else { 0 }
        if ($column -lt $rawValues.Count) {
            $parsedValue = 0
            $sourceValue = $rawValues[$column].Trim()
            if ($sourceValue -and [int]::TryParse($sourceValue, [ref]$parsedValue)) {
                $value = $parsedValue
            }
        }
        if ($recordMultipliers.ContainsKey($column)) {
            $value *= $recordMultipliers[$column]
        }
        $values.Add($value)
    }

    return ($values -join ",")
}

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "DataLocal が見つかりません: $SourceDirectory"
}

$unitsDirectory = Join-Path $DestinationDirectory "units"
$namesDirectory = Join-Path $DestinationDirectory "names"
New-Item -ItemType Directory -Path $unitsDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $namesDirectory -Force | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$localizedDirectory = Join-Path (Split-Path -Parent $SourceDirectory) "resLocal"
$explanationCount = 0
$sourceFiles = Get-ChildItem -LiteralPath $SourceDirectory -File |
    Where-Object { $_.Name -match '^unit\d+\.csv$' } |
    Sort-Object { [int][regex]::Match($_.BaseName, '\d+').Value }

foreach ($sourceFile in $sourceFiles) {
    $sourceId = [int][regex]::Match($sourceFile.BaseName, '\d+').Value
    $unitId = $sourceId - 1
    $targetName = "unit{0:D3}.csv" -f $unitId
    $targetPath = Join-Path $unitsDirectory $targetName
    $sourceLines = [System.IO.File]::ReadAllLines($sourceFile.FullName, $utf8NoBom)
    if ($sourceLines.Count -eq 0) {
        continue
    }

    $explanationName = "Unit_Explanation{0}_ja.csv" -f $sourceId
    $explanationPath = Join-Path $localizedDirectory $explanationName
    if (-not (Test-Path -LiteralPath $explanationPath -PathType Leaf)) {
        throw "形態名ファイルが見つかりません: $explanationPath"
    }
    Copy-Item -LiteralPath $explanationPath -Destination (Join-Path $namesDirectory $explanationName) -Force
    $explanationCount++

    $convertedRows = New-Object System.Collections.Generic.List[string]
    for ($form = 0; $form -lt $sourceLines.Count; $form++) {
        if (-not $sourceLines[$form].Trim()) {
            continue
        }
        $convertedRows.Add((Convert-UnitRow -Line $sourceLines[$form]))
    }

    [System.IO.File]::WriteAllText($targetPath, (($convertedRows -join [Environment]::NewLine) + [Environment]::NewLine), $utf8NoBom)
}

& (Join-Path $PSScriptRoot "build-unit-index.ps1") -DataDirectory $DestinationDirectory

Write-Host ("変換完了: {0} ユニット、{1} 名前ファイル" -f $sourceFiles.Count, $explanationCount)
Write-Host "出力先: $DestinationDirectory"
