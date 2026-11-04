# Reproduction guide

## Requirements

- Windows 10 or 11.
- Vivado and Vitis 2025.2.
- Digilent/Xilinx JTAG cable driver.
- Zynq-7020 board matching the supplied XDC.

## FPGA build

The frozen bitstream is already provided. To rebuild, open `src/vivado/project_re.xpr`, ensure `mic_ps_top` is the top, verify the source paths, then run the synthesis and implementation Tcl scripts in `scripts/`. The supplied scripts retain the original absolute project path and are evidence of the actual build; update the two path variables when moving the repository.

## PS build

The final ELF targets Cortex-A9. The ELF and corresponding PS source are included. Rebuilding it requires the exported XSA and matching Vitis standalone BSP; those platform files are not part of this source package. Create a PS7 Cortex-A9 standalone platform from the Vivado design, then add the supplied PS sources and model C files to the application.

## JTAG run

1. Power the board and connect JTAG.
2. Program `build/artifacts/stage29_retry_tjc.bit`.
3. Run `board/jtag/run_latest_elf.ps1`, or reset Cortex-A9 core 0 and download `build/artifacts/stage37_model_candidate.elf`.
4. Run the core.
5. Confirm that the screen updates and the four microphones produce activity.

## Standalone boot

The supplied `board/boot/BOOT_SD_FINAL.BIN` and `BOOT_QSPI_FINAL.BIN` are the Stage29 + Stage37 standalone images. The BIF files describe their inputs, and the QSPI program/readback and cold-boot logs record the board verification. Check the root `SHA256SUMS.txt` before use. For JTAG development, follow the steps above instead.

## Acceptance test

1. Start the recommended Stage29 bitstream + Stage37 ELF combination and verify the idle screen.
2. Play one sample from each enabled class from a fixed distance.
3. Record actual sound, predicted class, confidence, direction, strip color, motor state, and confirmation result.
4. Confirm silence and unknown do not trigger physical alarms.
5. Confirm class 6 is not exposed as a product result.
6. Press the screen confirmation button and verify strip and motor clear.
7. Run for at least two hours and record microphone dropouts, false alarms, or output latch failures.

