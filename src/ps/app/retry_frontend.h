#ifndef RETRY_FRONTEND_H
#define RETRY_FRONTEND_H

#include <stdint.h>

#define RETRY_PCM_SAMPLE_COUNT 15872U
#define RETRY_MODEL_INPUT_COUNT 1960U

/*
 * Recreates the model owner's NumPy frontend:
 *   16 kHz PCM -> 49 x 512 frames, hop 320 -> Hamming -> RFFT power
 *   -> 40 Mel bands (40..8000 Hz) -> ln(mel + 1e-8) -> INT8.
 *
 * gain is applied to normalized PCM and clipped to [-1, 1] before framing.
 * The short-term knock policy calls this with gain=2.0 only after the normal
 * PL/model result is unknown.
 */
int retry_frontend_quantize_pcm(
    const int16_t pcm[RETRY_PCM_SAMPLE_COUNT],
    double gain,
    int8_t model_input[RETRY_MODEL_INPUT_COUNT]
);

#endif
