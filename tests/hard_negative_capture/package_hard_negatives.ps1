param(
    [string]$PackageName = 'stage38_hard_negatives_for_model_owner'
)

$ErrorActionPreference = 'Stop'

$stageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Split-Path -Parent $stageRoot
$captureOutput = Join-Path $workspaceRoot 'stage25_synchronized_frontend_capture\output'
$packageRoot = Join-Path $stageRoot $PackageName
$zipPath = "$packageRoot.zip"

$captures = @(
    Get-ChildItem -LiteralPath $captureOutput -Directory -Filter 'hardneg_*' -ErrorAction SilentlyContinue |
        Sort-Object Name
)

if ($captures.Count -eq 0) {
    throw '没有找到 hardneg_* 采集目录。请先运行 run_hard_negative_capture.ps1。'
}

if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

$records = @()
foreach ($capture in $captures) {
    $destination = Join-Path $packageRoot $capture.Name
    Copy-Item -LiteralPath $capture.FullName -Destination $destination -Recurse -Force

    $category = if ($capture.Name -match '^hardneg_(keyboard|door_latch|door_open_close|room_noise)_') {
        $Matches[1]
    } else {
        'unknown'
    }

    $records += [pscustomobject]@{
        sample_id = $capture.Name
        training_label = 'unknown'
        hard_negative_type = $category
        pcm_file = "$($capture.Name)_ch0_pcm.csv"
        pl_matrix_file = "$($capture.Name)_pl_matrix.csv"
        note = '不得标为 knock；用于压制机械瞬态误报'
    }
}

$records | Export-Csv `
    -LiteralPath (Join-Path $packageRoot 'manifest.csv') `
    -NoTypeInformation `
    -Encoding utf8

Copy-Item `
    -LiteralPath (Join-Path $stageRoot 'README_给乙.md') `
    -Destination (Join-Path $packageRoot 'README_给乙.md') `
    -Force

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath "$packageRoot\*" -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host ''
Write-Host "样本数：$($captures.Count)"
Write-Host "目录：$packageRoot"
Write-Host "ZIP：$zipPath" -ForegroundColor Green

