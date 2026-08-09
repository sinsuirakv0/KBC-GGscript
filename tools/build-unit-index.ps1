[CmdletBinding()]
param(
    [string]$DataDirectory = (Join-Path $PSScriptRoot "..\data")
)

$ErrorActionPreference = "Stop"
$namesDirectory = Join-Path $DataDirectory "names"
$unitsDirectory = Join-Path $DataDirectory "units"
$outputPath = Join-Path $DataDirectory "unit-index.csv"

if (-not (Test-Path -LiteralPath $namesDirectory -PathType Container)) {
    throw "names フォルダが見つかりません: $namesDirectory"
}
if (-not (Test-Path -LiteralPath $unitsDirectory -PathType Container)) {
    throw "units フォルダが見つかりません: $unitsDirectory"
}

function ConvertTo-CsvField {
    param([string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

$sourceFiles = Get-ChildItem -LiteralPath $namesDirectory -File -Filter "Unit_Explanation*_ja.csv" |
    Where-Object { $_.Name -match '^Unit_Explanation(\d+)_ja\.csv$' } |
    Sort-Object { [int][regex]::Match($_.Name, '\d+').Value }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("unit_id,form_index,name")
$characterCount = 0
$formCount = 0

foreach ($sourceFile in $sourceFiles) {
    $sourceId = [int][regex]::Match($sourceFile.Name, '\d+').Value
    $unitId = $sourceId - 1
    $unitPath = Join-Path $unitsDirectory ("unit{0:D3}.csv" -f $unitId)
    if (-not (Test-Path -LiteralPath $unitPath -PathType Leaf)) {
        throw "対応するステータスCSVがありません: $unitPath"
    }

    $lastFormName = $null
    $formIndex = 0
    foreach ($line in [System.IO.File]::ReadAllLines($sourceFile.FullName)) {
        $columns = $line.Split(',')
        $formName = if ($columns.Count -gt 0) { $columns[0].Trim() } else { "" }
        $description = if ($columns.Count -gt 1) { $columns[1].Trim() } else { "" }
        if ($formName -match '^8\d\d[-_]\d+$' -and $description -match '^精霊[：:]') {
            $formName = "精霊"
        }
        if (-not $formName) {
            continue
        }
        # 同じ名前で埋められた末尾形態は実装済み形態として扱わない。
        if ($null -ne $lastFormName -and $formName -eq $lastFormName) {
            break
        }

        $lines.Add(("{0},{1},{2}" -f $unitId, $formIndex, (ConvertTo-CsvField -Value $formName)))
        $lastFormName = $formName
        $formIndex++
        $formCount++
    }

    if ($formIndex -eq 0) {
        throw "形態名がありません: $($sourceFile.FullName)"
    }
    $characterCount++
}

if ($characterCount -eq 0) {
    throw "索引へ追加できるキャラがありません。"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    $outputPath,
    (($lines -join [Environment]::NewLine) + [Environment]::NewLine),
    $utf8NoBom
)

Write-Host ("名前索引を生成しました: {0}キャラ、{1}形態" -f $characterCount, $formCount)
Write-Host "出力先: $outputPath"
