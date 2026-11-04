$ErrorActionPreference = 'Stop'

$stage = $PSScriptRoot
$gcc = 'D:\FPGA\2025.2\tps\mingw\10.0.0\win64.o\nt\bin\gcc.exe'
$model = Join-Path $stage 'model'
$sampleRoot = Join-Path $stage '..\stage25_synchronized_frontend_capture\output'
$exe = Join-Path $stage 'host_retry_validation.exe'
$report = Join-Path $stage 'host_regression.csv'

& $gcc `
    -std=c99 -O2 -Wall -Wextra `
    -I $stage -I $model `
    (Join-Path $stage 'host_retry_validation.c') `
    (Join-Path $stage 'retry_frontend.c') `
    (Join-Path $model 'dscnn.c') `
    -lm -o $exe
if ($LASTEXITCODE -ne 0) {
    throw "Host validation build failed: $LASTEXITCODE"
}

$cases = [ordered]@{
    external_silence_right_01       = 0
    external_unknown_right_01       = 1
    external_knock_strong_repeat_01 = 2
    external_alarm_clock_right_01   = 3
    external_alarm_alert_right_01   = 4
    external_baby_cry_right_02      = 5
    # Stage36 candidate reserves class 6 and maps glass-break audio to unknown.
    external_glass_break_right_01   = 1
    external_kettle_right_01        = 7
}

function Get-Value {
    param([string[]]$Lines, [string]$Name)
    $line = $Lines | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if ($null -eq $line) {
        throw "Missing $Name in validator output"
    }
    return ($line -split '=', 2)[1]
}

$rows = foreach ($entry in $cases.GetEnumerator()) {
    $name = $entry.Key
    $directory = Join-Path $sampleRoot $name
    $pcm = Join-Path $directory "${name}_ch0_pcm.csv"
    $baseGolden = Join-Path $directory 'analysis\python_model_input_gain_1x_i8.txt'
    if (-not (Test-Path -LiteralPath $baseGolden)) {
        $baseGolden = Join-Path $directory 'analysis\python_model_input_i8.txt'
    }
    $retryGolden = Join-Path $directory 'analysis\python_model_input_gain_2x_i8.txt'

    [string[]]$baseOutput = & $exe $pcm 1.0 $baseGolden
    if ($LASTEXITCODE -ne 0) { throw "Base validation failed: $name" }
    [string[]]$retryOutput = & $exe $pcm 2.0 $retryGolden
    if ($LASTEXITCODE -ne 0) { throw "Retry validation failed: $name" }

    $baseClass = [int](Get-Value $baseOutput 'CLASS_ID')
    $retryClass = [int](Get-Value $retryOutput 'CLASS_ID')
    $finalClass = if ($baseClass -eq 1 -and $retryClass -eq 2) {
        2
    } else {
        $baseClass
    }

    [pscustomobject]@{
        sample = $name
        expected_class = $entry.Value
        base_class = $baseClass
        retry_class = $retryClass
        final_class = $finalClass
        base_confidence_q8 = [int](Get-Value $baseOutput 'CONFIDENCE_Q8')
        retry_confidence_q8 = [int](Get-Value $retryOutput 'CONFIDENCE_Q8')
        base_golden_mismatches = [int](Get-Value $baseOutput 'GOLDEN_MISMATCH_COUNT')
        retry_golden_mismatches = [int](Get-Value $retryOutput 'GOLDEN_MISMATCH_COUNT')
        pass = $finalClass -eq $entry.Value
    }
}

$rows | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding utf8
$rows | Format-Table -AutoSize

if (($rows | Where-Object { -not $_.pass }).Count -ne 0) {
    throw 'Stage 29 conditional-retry regression failed.'
}
if (($rows | Measure-Object base_golden_mismatches -Sum).Sum -ne 0 -or
    ($rows | Measure-Object retry_golden_mismatches -Sum).Sum -ne 0) {
    throw 'Stage 29 C frontend differs from one or more Python golden vectors.'
}

Write-Host 'STAGE37_HOST_REGRESSION_STATUS=Complete'
Write-Host "STAGE37_REPORT=$report"
