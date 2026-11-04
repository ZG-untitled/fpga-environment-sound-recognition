param(
    [ValidateSet('keyboard', 'door_latch', 'door_open_close', 'room_noise', 'all')]
    [string]$Category = 'all',

    [ValidateRange(1, 20)]
    [int]$Repetitions = 5
)

$ErrorActionPreference = 'Stop'

$stageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspaceRoot = Split-Path -Parent $stageRoot
$captureScript = Join-Path $workspaceRoot 'stage25_synchronized_frontend_capture\run_labeled_capture.ps1'

if (-not (Test-Path -LiteralPath $captureScript)) {
    throw "Stage 25 capture script is missing: $captureScript"
}

$categoryInstructions = [ordered]@{
    keyboard = '在 STAGE25_KNOCK_NOW 出现后，连续正常敲键盘约 1 秒；不要敲桌面。'
    door_latch = '在 STAGE25_KNOCK_NOW 出现后，操作一次门把手或门锁卡扣；不要敲门。'
    door_open_close = '在 STAGE25_KNOCK_NOW 出现后，正常开门或关门一次；不要故意撞门。'
    room_noise = '保持当前普通环境声约 1 秒，不播放任何目标声音。'
}

$selectedCategories = if ($Category -eq 'all') {
    @($categoryInstructions.Keys)
} else {
    @($Category)
}

Write-Host ''
Write-Host '========== Stage 38 hard-negative capture ==========' -ForegroundColor Cyan
Write-Host '这些样本全部是 unknown 负样本，不应触发灯带或马达。' -ForegroundColor Yellow
Write-Host "类别：$($selectedCategories -join ', ')；每类：$Repetitions 条"
Write-Host ''

foreach ($captureCategory in $selectedCategories) {
    Write-Host "--- $captureCategory ---" -ForegroundColor Cyan
    Write-Host $categoryInstructions[$captureCategory] -ForegroundColor Yellow

    for ($index = 1; $index -le $Repetitions; ++$index) {
        $label = 'hardneg_{0}_{1:d2}' -f $captureCategory, $index
        Write-Host ''
        Write-Host "准备采集 $label ($index/$Repetitions)" -ForegroundColor Green
        Read-Host '摆放完成后按 Enter；倒计时结束看到 STAGE25_KNOCK_NOW 再动作'

        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $captureScript `
            -Label $label `
            -NoPrompt

        if ($LASTEXITCODE -ne 0) {
            throw "Capture failed for $label with exit code $LASTEXITCODE"
        }
    }
}

Write-Host ''
Write-Host 'Stage 38负样本采集完成。请运行 package_hard_negatives.ps1 打包。' -ForegroundColor Green

