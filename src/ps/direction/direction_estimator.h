#ifndef STAGE22_DIRECTION_ESTIMATOR_H
#define STAGE22_DIRECTION_ESTIMATOR_H

#include <stdint.h>

#define STAGE22_DIRECTION_CHANNELS 4U
#define STAGE22_DIRECTION_PAIRS 6U

typedef struct {
    uint32_t valid;
    uint32_t sector;
    uint32_t event_start_sample;
    float angle_degrees;
    float vector_magnitude;
    float fit_residual_mm;
    float event_rms;
    float pair_lag_samples[STAGE22_DIRECTION_PAIRS];
    float pair_correlation[STAGE22_DIRECTION_PAIRS];
} Stage22DirectionResult;

/*
 * Channel layout for the fixed 60 mm square:
 *
 *             front (0 degrees)
 *          CH3               CH2
 *          CH1               CH0
 *             back (180 degrees)
 *
 * Angles increase clockwise: right is 90 degrees.
 */
int stage22_estimate_direction(
    const int16_t *const channels[STAGE22_DIRECTION_CHANNELS],
    uint32_t sample_count,
    Stage22DirectionResult *result
);

const char *stage22_direction_name(uint32_t sector);

#endif
