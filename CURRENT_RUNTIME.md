# 当前运行版本说明

## 推荐演示组合

| 项目 | 文件 | 状态 |
|---|---|---|
| PL bitstream | `build/artifacts/stage29_retry_tjc.bit` | 已实现、满足时序 |
| PS ELF | `build/artifacts/stage37_model_candidate.elf` | 最新板测版本 |
| PS 源码 | `src/ps/app/main_stage29.c` | 与最新 ELF 对应 |
| 模型 | `src/ps/model/dscnn_model_data.h` | Stage36 乙回传候选的板端导出 |
| QSPI 启动镜像 | `board/boot/BOOT_QSPI_FINAL.BIN` | 包内日志记录 Stage29 + Stage37 写入及冷启动验证；上传后以校验清单核对 |
| SD 备用镜像 | `board/boot/BOOT_SD_FINAL.BIN` | BIF 定义为 Stage29 + Stage37；复制到 FAT32 卡时改名为 `BOOT.BIN` |
| JTAG 恢复脚本 | `board/jtag/load_latest_elf.tcl` | 仅用于开发和故障恢复 |

## 最新验证证据

- `data/regression/stage37_host_regression.csv`：8/8。
- `data/stability/noise_soak_after_emergency_fix_60s.log`：120 次监测，非零动作 0。
- `build/reports/`：WNS 11.184 ns，TNS 0 ns。
- `board/boot/stage37_qspi_program_verify.log`：QSPI 写入与逐块回读校验成功。
- `board/boot/stage37_qspi_cold_boot_verify.log`：断电重启后状态为 READY，推理计数持续增加。

## BOOT 镜像说明

`board/boot/stage37_qspi.bif` 与 `stage37_sd.bif` 指定 Stage29 bitstream 和 Stage37 ELF。包内 QSPI 日志记录了写入、回读及断电冷启动状态。所有文件哈希以根目录 `SHA256SUMS.txt` 为准。
