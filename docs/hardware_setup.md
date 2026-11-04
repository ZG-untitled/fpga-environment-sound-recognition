# Hardware setup

## Board signals

| Function | FPGA package pin | Electrical note |
|---|---|---|
| System clock | U18 | LVCMOS33, 50 MHz |
| Reset | N16 | Active low, pull-up |
| Microphone BCLK | R14 | Shared output |
| Microphone WS | V13 | Shared output, 16 kHz |
| Microphone SD0 | U14 | Input, pull-down |
| Microphone SD1 | W13 | Input, pull-down |
| Microphone SD2 | V12 | Input, pull-down |
| Microphone SD3 | Y14 | Input, pull-down |
| Board status LED | H15 | Active-low board LED |
| WS2812 data | F20 | 3.3 V logic; use a 74HCT level shifter if the strip is unreliable |

## Microphone geometry

The microphones form a 60 mm square:

```text
front
CH3 ---------------- CH2
 |                    |
 |       60 mm        |
 |                    |
CH1 ---------------- CH0
rear
```

The firmware geometry is CH0 rear-right, CH1 rear-left, CH2 front-right, CH3 front-left. Changing the physical order without changing `direction_estimator_gcc.c` causes rotated or mirrored directions.

## Vibration motor

Use the three-pin MOSFET driver module already tested with the product:

- VCC -> regulated 5 V.
- GND -> board ground and external 5 V ground.
- IN -> assigned PL control output in the final hardware design.

The module must share ground with the Zynq board. Do not power the motor directly from an FPGA IO pin. Disconnect motor power when debugging direction to prevent structure-borne vibration from reaching the microphones.

## WS2812 strip

- Power the strip from 5 V with adequate current capacity.
- Connect strip ground to board ground.
- Connect DIN, not DOUT, to F20.
- Keep the data wire short; add a 74HCT125 or 74HCT245 level shifter if 3.3 V drive is marginal.
- Limit brightness unless using an external supply.

## TJC serial screen

- Resolution: 800 x 480.
- Baud rate: 9600.
- Connect TX and RX crossed, and share ground.
- Confirmation packet expected by firmware: `5A A5 01 01`.

