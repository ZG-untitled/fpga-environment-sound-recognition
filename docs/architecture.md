# System architecture

## End-to-end data flow

```text
4 x INMP441
   | shared BCLK and WS, four SD lines
   v
PL I2S receive and channel alignment
   v
frame buffer -> Hamming window -> 512-point FFT
   v
power spectrum -> 40-band Mel -> unsigned Log2 Q8.8 matrix
   |                                         |
   | synchronized four-channel PCM           | 49 x 40 features
   v                                         v
PS direction estimator                 PS INT8 DS-CNN
   |                                         |
   +---------------- class and direction ----+
                          v
              confidence rejection and event latch
                          v
       TJC screen + WS2812 + 5 V motor + confirm key
```

## Hardware and software split

The PL performs continuous, deterministic sampling and feature extraction. This avoids software timing jitter and demonstrates a substantive FPGA role rather than using the device as a GPIO adapter. The PS performs quantized inference, direction scoring, event policy, display protocol, and acknowledgement handling because these stages benefit from flexible control flow and can be updated without rerouting the PL.

## Fixed signal parameters

| Parameter | Value |
|---|---:|
| Sample rate | 16 kHz |
| PCM channels | 4 |
| Analysis window | 1 second |
| Frame length | 512 samples |
| Frame hop | 320 samples |
| FFT size | 512 |
| Mel bands | 40 |
| Feature matrix | 49 x 40 |
| Model input | signed int8, frame-major |
| Model outputs | 8 logits |

## Event policy

Silence and unknown never drive the strip or motor. Normal events require repeated confirmation; the emergency alarm has a faster path. Once accepted, the class and direction are latched so an old direction is not displayed beside a new class. The screen confirmation command clears the event and outputs, followed by a short cooldown to prevent immediate retriggering.

