$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $root 'SHA256SUMS.txt'

$records = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $_.FullName -ne $output -and
        $_.Extension -ne '.zip' -and
        $_.FullName -notmatch '\\report\\rendered'
    } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        "$hash  $relative"
    }

$records | Set-Content -LiteralPath $output -Encoding utf8
Write-Host "SHA-256 清单已生成：$output" -ForegroundColor Green
Write-Host "文件数：$($records.Count)"
