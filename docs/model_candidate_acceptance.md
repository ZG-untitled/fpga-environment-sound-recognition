# Stage36 model candidate acceptance record

## Candidate identity

- Package: `stage36_model_owner_v1_baremetal_int8_candidate`
- Returned: 2026-11-02
- Classes: 0 silence, 1 unknown, 2 knock, 3 alarm_clock, 4 alarm_alert,
  5 baby_cry, 6 reserved, 7 kettle
- Product policy: class 6 is not exposed; glass-break input is trained as unknown.

## Checks completed on 2026-11-03

| Check | Result |
|---|---|
| Supplied C layer vectors | 47 / 47 pass; every vector matches all 13 layers |
| Candidate fixed host regression | 8 / 8 pass |
| Alarm field sample | alarm_alert, no longer kettle |
| Baby-cry field sample | baby_cry |
| Glass-break product behavior | unknown |
| Cortex-A9 bare-metal build | pass; ELF size 277660 bytes |
| Zynq JTAG runtime | READY; inference count advanced from 37 to 39 |

## Product integration decision

The model-owner README originally marked this package as a candidate. The supplied 44-view regression has 43 passes and one failure:
`stage36_pcm_background_01` is predicted as knock, while the paired PL view is silence.
The 22 field recordings were used for fine-tuning, so those successes are fitting
checks rather than independent validation. Under the model owner's same-policy
comparison, candidate INT8 development accuracy is 85.39%, versus 86.71% for the
remapped live-v1 baseline; candidate silence recall is 75.00%.

The final Stage37 firmware integrates this candidate together with product-level
guards: knock requires 220/255 confidence plus PCM transient checks, alarm_alert
requires three consecutive confirmations, and the emergency branch no longer bypasses
the confirmation counter. The resulting fixed host regression is 8/8. A 60-second
static monitor sampled 120 states and observed zero non-idle actions.

## Final deployment decision

- Use `build/artifacts/stage37_model_candidate.elf` as the recommended JTAG demo ELF.
- The supplied SD/QSPI images use the Stage29 + Stage37 combination; BIF files and
  QSPI verification logs are included under `board/boot/`.
- Continue collecting independent keyboard, door-latch, speech, baby-cry,
  alarm/kettle, and room-noise samples; the existing development accuracy is not a
  claim of live-field accuracy.
