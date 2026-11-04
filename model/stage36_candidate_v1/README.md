# Stage36 Model Owner Candidate v1

This Stage36 candidate starts from the `dscnn_live_v1.pth` checkpoint whose SHA-256 matches the Stage36 `02_current_baremetal_int8/model.json` interface.

## Model policy

- Keeps eight output values and the original IDs: 0 silence, 1 unknown, 2 knock, 3 alarm_clock, 4 alarm_alert, 5 baby_cry, 6 glass_break placeholder, 7 kettle.
- Maps glass-break training/field audio to unknown (ID 1). The ID 6 classifier bias is forced low; it did not win any exported development or field vector.
- Fine-tunes from live_v1 with the original labeled training cards, teacher-preservation loss, and the 22 paired Stage36 field recordings.
- Uses each recording's PCM-derived feature and its Stage36-calibrated PL feature for fitting and separate C regression vectors. They are two views of one recording, not two independent recordings.

## Contents

- `c/`: bare-metal C inference engine and generated INT8 weights.
- `parameters/`, `model.json`, `classes.txt`: per-layer weights, quantization parameters, and fixed class map.
- `dscnn_stage36_model_owner_v1.pth`: FP32 candidate checkpoint.
- `train_stage36_model_owner.py`, `train_dscnn_v3.py`, `adapt_live_input.py`, `features.py`, `cards.csv`, and `ESC-50_LICENSE`: training source and the exact manifest used by this workspace run.
- `training_comparison.json`, `metrics.json`, `regression_results.json`, `demo_results.json`: fitting, development, field-vector, and screened-demo results.
- `c_validation.json` summarizes host C verification: 47 vectors matched across all 13 layers. `c/verify_host.c` is the verifier source; the per-layer vector dumps are omitted from this compact project copy.

## Results

The Stage36 live_v1 baseline predicted `unknown` for `external_baby_cry_right_01` and `kettle` for both alarm captures. The candidate predicts baby_cry on both PCM and PL views of both supplied baby recordings, and alarm_alert on both views of both supplied alarm recordings. The two alarm recordings and both baby recordings were used in fitting; these are fitting regressions, not independent field validation. Both screened five-second baby demo WAVs were correct in all five one-second windows, but the handoff marks those demos as post-selected.

On the reused source-overlapping development split, INT8 accuracy is 85.39% after mapping glass labels to unknown and reserving output 6. The original live_v1 C confusion matrix, remapped under the same policy, is 86.71%. In this comparison, alarm_alert recall changed from 91.38% to 84.48%, baby_cry from 83.33% to 81.67%, and silence from 89.29% to 75.00%. The candidate did not improve the reused development split over the remapped live_v1 baseline. Stage37 integrates it with additional product-level guards; see `docs/model_candidate_acceptance.md` for system-level acceptance evidence and remaining limitations.

One Stage36 regression still fails: `background_01` PCM is classified as knock after INT8 quantization; its paired PL input is silence. The other 43 of 44 paired Stage36 PCM/PL vectors pass. This is a specific remaining issue in the PCM and calibrated PL input agreement.

The C source compiled with the GCC bundled in Vivado. All 13 layers matched the Python integer reference on 47 vectors, development confusion matched, and input/PL conversion checks passed. This is host validation only: no ARM timing or Zynq run is included. Collect additional independent baby-cry and alarm/kettle captures and resolve the background PCM regression before accepting the model.

The ZIP does not bundle the approximately 1.3 GB source-audio corpus. The supplied training script uses the project-relative `sound_list/dataset_16k`, `sound_list/v3c_manifest`, and Stage36 handoff paths, so rerun it from the full project workspace or restore those assets at their existing paths first.
