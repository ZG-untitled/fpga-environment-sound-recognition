param(
    [string]$Xsct = 'D:\FPGA\2025.2\Vitis\bin\xsct.bat'
)

$ErrorActionPreference = 'Stop'
$tcl = Join-Path $PSScriptRoot 'load_latest_elf.tcl'

if (-not (Test-Path -LiteralPath $Xsct)) {
    throw "XSCT 不存在：$Xsct"
}

& $Xsct $tcl
if ($LASTEXITCODE -ne 0) {
    throw "Stage37 ELF 下载失败，退出代码：$LASTEXITCODE"
}

Write-Host 'Stage37 最新 ELF 已下载并运行。' -ForegroundColor Green
