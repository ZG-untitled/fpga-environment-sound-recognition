# v1.0-final

最终运行组合：

- PL：`build/artifacts/stage29_retry_tjc.bit`
- PS：`build/artifacts/stage37_model_candidate.elf`
- QSPI：`board/boot/BOOT_QSPI_FINAL.BIN`

验收状态：8/8 固定样本主机回归通过；60 秒静态环境 120 次采样无非零动作；路由后 WNS 11.184 ns、TNS 0 ns；QSPI 已完成写入、回读和断电冷启动验证。

已知边界：83.8158% 为开发/回归样本指标，不代表独立现场准确率；方向结果会受房间反射和阵列安装误差影响；类别 6 仅保留 ABI，产品出口映射为 unknown。
