#include "direction_estimator.h"

#include <math.h>
#include <stddef.h>

#define SAMPLE_RATE_HZ 16000.0f
#define SOUND_SPEED_MPS 343.0f
#define EVENT_SAMPLES 4096U
#define FRAME_SAMPLES 512U
#define FFT_SIZE 8192U
#define FFT_HALF_SIZE (FFT_SIZE / 2U)
#define MAX_LAG_SAMPLES 6
#define MIN_EVENT_RMS 10.0f
#define MIN_CARDINAL_SCORE 0.55f
#define MIN_CARDINAL_MARGIN 0.05f
#define MIN_LEFT_CARDINAL_SCORE 0.45f
#define MIN_LEFT_CARDINAL_MARGIN 0.025f
#define MIN_SEARCH_MAGNITUDE 0.30f
#define MAX_SEARCH_MAGNITUDE 1.50f
#define SEARCH_MAGNITUDE_STEP 0.02f
#define ENERGY_FALLBACK_MIN_RMS 6.0f
#define ENERGY_FALLBACK_MIN_CONTRAST 0.035f
#define PI_VALUE 3.14159265358979323846f

typedef struct {
    float real;
    float imag;
} ComplexFloat;

static const uint8_t pair_first[STAGE22_DIRECTION_PAIRS] = {
    0U, 0U, 0U, 1U, 1U, 2U
};

static const uint8_t pair_second[STAGE22_DIRECTION_PAIRS] = {
    1U, 2U, 3U, 2U, 3U, 3U
};

/* CH0 rear-right, CH1 rear-left, CH2 front-right, CH3 front-left. */
static const float channel_x[STAGE22_DIRECTION_CHANNELS] = {
     0.030f, -0.030f,  0.030f, -0.030f
};

static const float channel_y[STAGE22_DIRECTION_CHANNELS] = {
    -0.030f, -0.030f,  0.030f,  0.030f
};

/* Static PS-DDR workspace: no heap and no large stack frame. */
static ComplexFloat channel_spectrum[STAGE22_DIRECTION_CHANNELS][FFT_SIZE];
static ComplexFloat fft_work[FFT_SIZE];
static float twiddle_cos[FFT_HALF_SIZE];
static float twiddle_sin[FFT_HALF_SIZE];
static float hann_window[EVENT_SAMPLES];
static float pair_curves[STAGE22_DIRECTION_PAIRS]
                        [(2 * MAX_LAG_SAMPLES) + 1];
static uint32_t tables_ready = 0U;

static uint32_t reverse_bits(uint32_t value, unsigned int bits)
{
    uint32_t reversed = 0U;
    unsigned int index;

    for (index = 0U; index < bits; ++index) {
        reversed = (reversed << 1U) | (value & 1U);
        value >>= 1U;
    }
    return reversed;
}

static void initialize_tables(void)
{
    uint32_t index;

    if (tables_ready != 0U) {
        return;
    }

    for (index = 0U; index < FFT_HALF_SIZE; ++index) {
        float angle = 2.0f * PI_VALUE * (float)index / (float)FFT_SIZE;
        twiddle_cos[index] = cosf(angle);
        twiddle_sin[index] = sinf(angle);
    }
    for (index = 0U; index < EVENT_SAMPLES; ++index) {
        hann_window[index] = 0.5f - 0.5f * cosf(
            2.0f * PI_VALUE * (float)index / (float)(EVENT_SAMPLES - 1U)
        );
    }
    tables_ready = 1U;
}

static void fft_in_place(ComplexFloat data[FFT_SIZE], int inverse)
{
    const unsigned int bits = 13U;
    uint32_t index;
    uint32_t length;

    for (index = 0U; index < FFT_SIZE; ++index) {
        uint32_t reversed = reverse_bits(index, bits);
        if (reversed > index) {
            ComplexFloat temporary = data[index];
            data[index] = data[reversed];
            data[reversed] = temporary;
        }
    }

    for (length = 2U; length <= FFT_SIZE; length <<= 1U) {
        uint32_t half = length >> 1U;
        uint32_t twiddle_step = FFT_SIZE / length;
        uint32_t base;

        for (base = 0U; base < FFT_SIZE; base += length) {
            uint32_t offset;
            for (offset = 0U; offset < half; ++offset) {
                uint32_t twiddle_index = offset * twiddle_step;
                float wr = twiddle_cos[twiddle_index];
                float wi = inverse ? twiddle_sin[twiddle_index]
                                   : -twiddle_sin[twiddle_index];
                ComplexFloat even = data[base + offset];
                ComplexFloat odd = data[base + offset + half];
                float product_real = wr * odd.real - wi * odd.imag;
                float product_imag = wr * odd.imag + wi * odd.real;

                data[base + offset].real = even.real + product_real;
                data[base + offset].imag = even.imag + product_imag;
                data[base + offset + half].real = even.real - product_real;
                data[base + offset + half].imag = even.imag - product_imag;
            }
        }
    }

    if (inverse != 0) {
        float scale = 1.0f / (float)FFT_SIZE;
        for (index = 0U; index < FFT_SIZE; ++index) {
            data[index].real *= scale;
            data[index].imag *= scale;
        }
    }
}

static float correlation_magnitude_at_shift(int shift)
{
    uint32_t index =
        (shift >= 0) ? (uint32_t)shift : (FFT_SIZE - (uint32_t)(-shift));
    return fabsf(fft_work[index].real);
}

static float estimate_gcc_pair(
    uint32_t first,
    uint32_t second,
    float *peak_ratio,
    float normalized_curve[(2 * MAX_LAG_SAMPLES) + 1]
)
{
    float magnitudes[(2 * MAX_LAG_SAMPLES) + 1];
    float best = -1.0f;
    float second_best = 0.0f;
    float fractional = 0.0f;
    int best_shift = 0;
    int best_index = 0;
    int shift;
    uint32_t bin;

    for (bin = 0U; bin < FFT_SIZE; ++bin) {
        ComplexFloat reference = channel_spectrum[first][bin];
        ComplexFloat comparison = channel_spectrum[second][bin];
        float cross_real =
            reference.real * comparison.real +
            reference.imag * comparison.imag;
        float cross_imag =
            reference.imag * comparison.real -
            reference.real * comparison.imag;
        float magnitude = sqrtf(
            cross_real * cross_real + cross_imag * cross_imag
        );

        if (magnitude > 1.0e-12f) {
            fft_work[bin].real = cross_real / magnitude;
            fft_work[bin].imag = cross_imag / magnitude;
        } else {
            fft_work[bin].real = 0.0f;
            fft_work[bin].imag = 0.0f;
        }
    }

    fft_in_place(fft_work, 1);

    for (shift = -MAX_LAG_SAMPLES; shift <= MAX_LAG_SAMPLES; ++shift) {
        int array_index = shift + MAX_LAG_SAMPLES;
        float value = correlation_magnitude_at_shift(shift);
        magnitudes[array_index] = value;
        if (value > best) {
            best = value;
            best_shift = shift;
            best_index = array_index;
        }
    }

    if ((best_index > 0) &&
        (best_index < (2 * MAX_LAG_SAMPLES))) {
        float left = magnitudes[best_index - 1];
        float center = magnitudes[best_index];
        float right = magnitudes[best_index + 1];
        float denominator = left - 2.0f * center + right;
        if (fabsf(denominator) > 1.0e-12f) {
            fractional = 0.5f * (left - right) / denominator;
            if (fractional > 1.0f) {
                fractional = 1.0f;
            } else if (fractional < -1.0f) {
                fractional = -1.0f;
            }
        }
    }

    for (shift = 0; shift <= (2 * MAX_LAG_SAMPLES); ++shift) {
        if ((shift < best_index - 1) || (shift > best_index + 1)) {
            if (magnitudes[shift] > second_best) {
                second_best = magnitudes[shift];
            }
        }
    }
    *peak_ratio = best / ((second_best > 1.0e-12f) ? second_best : 1.0e-12f);

    for (shift = 0; shift <= (2 * MAX_LAG_SAMPLES); ++shift) {
        normalized_curve[shift] =
            magnitudes[shift] / ((best > 1.0e-12f) ? best : 1.0e-12f);
    }

    /* ref*conj(comparison) produces the negative of the arrival-time lag. */
    return -((float)best_shift + fractional);
}

static float interpolate_pair_curve(
    const float curve[(2 * MAX_LAG_SAMPLES) + 1],
    float shift
)
{
    float position = shift + (float)MAX_LAG_SAMPLES;
    uint32_t low;
    float fraction;

    if (position <= 0.0f) {
        return curve[0];
    }
    if (position >= (float)(2 * MAX_LAG_SAMPLES)) {
        return curve[2 * MAX_LAG_SAMPLES];
    }

    low = (uint32_t)position;
    fraction = position - (float)low;
    return curve[low] * (1.0f - fraction) + curve[low + 1U] * fraction;
}

int stage22_estimate_direction(
    const int16_t *const channels[STAGE22_DIRECTION_CHANNELS],
    uint32_t sample_count,
    Stage22DirectionResult *result
)
{
    double global_means[STAGE22_DIRECTION_CHANNELS] = {0.0, 0.0, 0.0, 0.0};
    double event_means[STAGE22_DIRECTION_CHANNELS] = {0.0, 0.0, 0.0, 0.0};
    double best_frame_energy = -1.0;
    double total_event_energy = 0.0;
    double channel_event_energy[STAGE22_DIRECTION_CHANNELS] =
        {0.0, 0.0, 0.0, 0.0};
    static const double channel_energy_scale[STAGE22_DIRECTION_CHANNELS] = {
        1.0012, 0.9401, 1.1425, 0.9359
    };
    float cardinal_scores[4] = {-1.0f, -1.0f, -1.0f, -1.0f};
    float cardinal_magnitudes[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    static const float cardinal_x[4] = {0.0f, 1.0f, 0.0f, -1.0f};
    static const float cardinal_y[4] = {1.0f, 0.0f, -1.0f, 0.0f};
    float direction_x;
    float direction_y;
    float magnitude;
    float residual_sum = 0.0f;
    float best_cardinal_score = -1.0f;
    float second_cardinal_score = -1.0f;
    float event_rms;
    uint32_t gcc_valid;
    uint32_t energy_fallback_valid = 0U;
    uint32_t best_cardinal = 0U;
    uint32_t frame_count;
    uint32_t best_frame = 0U;
    uint32_t event_start;
    uint32_t channel;
    uint32_t index;
    uint32_t pair;

    if ((channels == NULL) || (result == NULL) ||
        (sample_count < EVENT_SAMPLES)) {
        return -1;
    }
    for (channel = 0U; channel < STAGE22_DIRECTION_CHANNELS; ++channel) {
        if (channels[channel] == NULL) {
            return -1;
        }
    }

    initialize_tables();

    for (channel = 0U; channel < STAGE22_DIRECTION_CHANNELS; ++channel) {
        double sum = 0.0;
        for (index = 0U; index < sample_count; ++index) {
            sum += (double)channels[channel][index];
        }
        global_means[channel] = sum / (double)sample_count;
    }

    frame_count = sample_count / FRAME_SAMPLES;
    for (index = 0U; index < frame_count; ++index) {
        uint32_t sample;
        double energy = 0.0;
        for (channel = 0U; channel < STAGE22_DIRECTION_CHANNELS; ++channel) {
            for (sample = 0U; sample < FRAME_SAMPLES; ++sample) {
                double centered =
                    (double)channels[channel][index * FRAME_SAMPLES + sample] -
                    global_means[channel];
                energy += centered * centered;
            }
        }
        if (energy > best_frame_energy) {
            best_frame_energy = energy;
            best_frame = index;
        }
    }

    if ((best_frame * FRAME_SAMPLES + FRAME_SAMPLES / 2U) >
        (EVENT_SAMPLES / 2U)) {
        event_start =
            best_frame * FRAME_SAMPLES + FRAME_SAMPLES / 2U -
            EVENT_SAMPLES / 2U;
    } else {
        event_start = 0U;
    }
    if (event_start > sample_count - EVENT_SAMPLES) {
        event_start = sample_count - EVENT_SAMPLES;
    }

    for (channel = 0U; channel < STAGE22_DIRECTION_CHANNELS; ++channel) {
        double sum = 0.0;
        for (index = 0U; index < EVENT_SAMPLES; ++index) {
            sum += (double)channels[channel][event_start + index];
        }
        event_means[channel] = sum / (double)EVENT_SAMPLES;
    }

    for (channel = 0U; channel < STAGE22_DIRECTION_CHANNELS; ++channel) {
        for (index = 0U; index < EVENT_SAMPLES; ++index) {
            float centered =
                (float)((double)channels[channel][event_start + index] -
                        event_means[channel]);
            channel_spectrum[channel][index].real =
                centered * hann_window[index];
            channel_spectrum[channel][index].imag = 0.0f;
            total_event_energy += (double)centered * (double)centered;
            channel_event_energy[channel] +=
                (double)centered * (double)centered *
                channel_energy_scale[channel];
        }
        for (index = EVENT_SAMPLES; index < FFT_SIZE; ++index) {
            channel_spectrum[channel][index].real = 0.0f;
            channel_spectrum[channel][index].imag = 0.0f;
        }
        fft_in_place(channel_spectrum[channel], 0);
    }

    for (pair = 0U; pair < STAGE22_DIRECTION_PAIRS; ++pair) {
        uint32_t first = pair_first[pair];
        uint32_t second = pair_second[pair];
        float lag = estimate_gcc_pair(
            first,
            second,
            &result->pair_correlation[pair],
            pair_curves[pair]
        );

        result->pair_lag_samples[pair] = lag;
    }

    /*
     * Score only the four directions shown by the product UI.  Each candidate
     * predicts all six GCC shifts at once, so a reflected peak from one pair
     * cannot independently pull a least-squares angle into an invalid result.
     */
    for (index = 0U; index < 4U; ++index) {
        float candidate_magnitude;
        for (candidate_magnitude = MIN_SEARCH_MAGNITUDE;
             candidate_magnitude <= MAX_SEARCH_MAGNITUDE + 0.001f;
             candidate_magnitude += SEARCH_MAGNITUDE_STEP) {
            float candidate_x = cardinal_x[index] * candidate_magnitude;
            float candidate_y = cardinal_y[index] * candidate_magnitude;
            float score = 0.0f;

            for (pair = 0U; pair < STAGE22_DIRECTION_PAIRS; ++pair) {
                uint32_t first = pair_first[pair];
                uint32_t second = pair_second[pair];
                float baseline_x = channel_x[second] - channel_x[first];
                float baseline_y = channel_y[second] - channel_y[first];
                float expected_shift =
                    (baseline_x * candidate_x + baseline_y * candidate_y) *
                    SAMPLE_RATE_HZ / SOUND_SPEED_MPS;
                score += interpolate_pair_curve(
                    pair_curves[pair],
                    expected_shift
                );
            }
            score /= (float)STAGE22_DIRECTION_PAIRS;

            if (score > cardinal_scores[index]) {
                cardinal_scores[index] = score;
                cardinal_magnitudes[index] = candidate_magnitude;
            }
        }

        if (cardinal_scores[index] > best_cardinal_score) {
            second_cardinal_score = best_cardinal_score;
            best_cardinal_score = cardinal_scores[index];
            best_cardinal = index;
        } else if (cardinal_scores[index] > second_cardinal_score) {
            second_cardinal_score = cardinal_scores[index];
        }
    }

    event_rms = (float)sqrt(
        total_event_energy /
        (double)(STAGE22_DIRECTION_CHANNELS * EVENT_SAMPLES)
    );

    gcc_valid =
        (event_rms >= MIN_EVENT_RMS) &&
        (best_cardinal_score >=
         ((best_cardinal == 3U) ?
          MIN_LEFT_CARDINAL_SCORE : MIN_CARDINAL_SCORE)) &&
        ((best_cardinal_score - second_cardinal_score) >=
         ((best_cardinal == 3U) ?
          MIN_LEFT_CARDINAL_MARGIN : MIN_CARDINAL_MARGIN));

    if ((gcc_valid == 0U) &&
        (event_rms >= ENERGY_FALLBACK_MIN_RMS)) {
        double left_energy =
            channel_event_energy[1] + channel_event_energy[3];
        double right_energy =
            channel_event_energy[0] + channel_event_energy[2];
        double front_energy =
            channel_event_energy[2] + channel_event_energy[3];
        double back_energy =
            channel_event_energy[0] + channel_event_energy[1];
        float left_right_contrast =
            (float)((left_energy - right_energy) /
                    (left_energy + right_energy + 1.0));
        float front_back_contrast =
            (float)((front_energy - back_energy) /
                    (front_energy + back_energy + 1.0));

        if ((fabsf(left_right_contrast) >=
             fabsf(front_back_contrast)) &&
            (fabsf(left_right_contrast) >=
             ENERGY_FALLBACK_MIN_CONTRAST)) {
            best_cardinal =
                (left_right_contrast > 0.0f) ? 3U : 1U;
            energy_fallback_valid = 1U;
        } else if (fabsf(front_back_contrast) >=
                   ENERGY_FALLBACK_MIN_CONTRAST) {
            best_cardinal =
                (front_back_contrast > 0.0f) ? 0U : 2U;
            energy_fallback_valid = 1U;
        }
    }
    magnitude = cardinal_magnitudes[best_cardinal];
    direction_x = cardinal_x[best_cardinal] * magnitude;
    direction_y = cardinal_y[best_cardinal] * magnitude;

    for (pair = 0U; pair < STAGE22_DIRECTION_PAIRS; ++pair) {
        uint32_t first = pair_first[pair];
        uint32_t second = pair_second[pair];
        float baseline_x = channel_x[second] - channel_x[first];
        float baseline_y = channel_y[second] - channel_y[first];
        float distance =
            -SOUND_SPEED_MPS *
            (result->pair_lag_samples[pair] / SAMPLE_RATE_HZ);
        float error =
            baseline_x * direction_x + baseline_y * direction_y - distance;
        residual_sum += error * error;
    }

    result->event_start_sample = event_start;
    result->angle_degrees = (float)best_cardinal * 90.0f;
    result->sector = best_cardinal << 1U;
    result->vector_magnitude = magnitude;
    result->fit_residual_mm =
        sqrtf(residual_sum / (float)STAGE22_DIRECTION_PAIRS) * 1000.0f;
    result->event_rms = event_rms;
    result->valid =
        ((gcc_valid != 0U) || (energy_fallback_valid != 0U));

    return 0;
}

const char *stage22_direction_name(uint32_t sector)
{
    static const char *const names[8] = {
        "front", "front-right", "right", "back-right",
        "back", "back-left", "left", "front-left"
    };
    return names[sector & 7U];
}
