#include "retry_frontend.h"

#include <math.h>
#include <stddef.h>

#define SAMPLE_RATE_HZ 16000.0
#define FRAME_LENGTH 512U
#define FRAME_HOP 320U
#define FRAME_COUNT 49U
#define MEL_BAND_COUNT 40U
#define SPECTRUM_BIN_COUNT 257U
#define PI_VALUE 3.14159265358979323846264338327950288
#define INPUT_SCALE 0.11699926712933709
#define INPUT_ZERO_POINT 29

typedef struct {
    double real;
    double imag;
} ComplexDouble;

/* Static storage keeps the Cortex-A9 stack small. */
static ComplexDouble fft_work[FRAME_LENGTH];
static double hamming_window[FRAME_LENGTH];
static double twiddle_cos[FRAME_LENGTH / 2U];
static double twiddle_sin[FRAME_LENGTH / 2U];
static uint16_t mel_bins[MEL_BAND_COUNT + 2U];
static int tables_ready;

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

static double hz_to_mel(double frequency_hz)
{
    return 2595.0 * log10(1.0 + frequency_hz / 700.0);
}

static double mel_to_hz(double mel_value)
{
    return 700.0 * (pow(10.0, mel_value / 2595.0) - 1.0);
}

static void initialize_tables(void)
{
    uint32_t index;
    double mel_first;
    double mel_last;

    if (tables_ready != 0) {
        return;
    }

    for (index = 0U; index < FRAME_LENGTH; ++index) {
        hamming_window[index] = 0.54 - 0.46 * cos(
            2.0 * PI_VALUE * (double)index / (double)(FRAME_LENGTH - 1U)
        );
    }
    for (index = 0U; index < FRAME_LENGTH / 2U; ++index) {
        double angle = 2.0 * PI_VALUE * (double)index / (double)FRAME_LENGTH;
        twiddle_cos[index] = cos(angle);
        twiddle_sin[index] = sin(angle);
    }

    mel_first = hz_to_mel(40.0);
    mel_last = hz_to_mel(8000.0);
    for (index = 0U; index < MEL_BAND_COUNT + 2U; ++index) {
        double mel = mel_first +
            (mel_last - mel_first) * (double)index /
            (double)(MEL_BAND_COUNT + 1U);
        double bin = floor(
            (double)FRAME_LENGTH * mel_to_hz(mel) / SAMPLE_RATE_HZ
        );
        if (bin < 0.0) {
            bin = 0.0;
        } else if (bin > (double)(SPECTRUM_BIN_COUNT - 1U)) {
            bin = (double)(SPECTRUM_BIN_COUNT - 1U);
        }
        mel_bins[index] = (uint16_t)bin;
    }
    tables_ready = 1;
}

static void fft_in_place(void)
{
    uint32_t index;
    uint32_t length;

    for (index = 0U; index < FRAME_LENGTH; ++index) {
        uint32_t reversed = reverse_bits(index, 9U);
        if (reversed > index) {
            ComplexDouble temporary = fft_work[index];
            fft_work[index] = fft_work[reversed];
            fft_work[reversed] = temporary;
        }
    }

    for (length = 2U; length <= FRAME_LENGTH; length <<= 1U) {
        uint32_t half = length >> 1U;
        uint32_t twiddle_step = FRAME_LENGTH / length;
        uint32_t base;

        for (base = 0U; base < FRAME_LENGTH; base += length) {
            uint32_t offset;
            for (offset = 0U; offset < half; ++offset) {
                uint32_t twiddle_index = offset * twiddle_step;
                double wr = twiddle_cos[twiddle_index];
                double wi = -twiddle_sin[twiddle_index];
                ComplexDouble even = fft_work[base + offset];
                ComplexDouble odd = fft_work[base + offset + half];
                double product_real = wr * odd.real - wi * odd.imag;
                double product_imag = wr * odd.imag + wi * odd.real;

                fft_work[base + offset].real = even.real + product_real;
                fft_work[base + offset].imag = even.imag + product_imag;
                fft_work[base + offset + half].real = even.real - product_real;
                fft_work[base + offset + half].imag = even.imag - product_imag;
            }
        }
    }
}

static int8_t quantize_ln(double value)
{
    double scaled = value / INPUT_SCALE;
    double rounded = scaled < 0.0
        ? -floor(-scaled + 0.5)
        : floor(scaled + 0.5);
    double quantized = rounded + (double)INPUT_ZERO_POINT;

    if (quantized < -128.0) {
        return -128;
    }
    if (quantized > 127.0) {
        return 127;
    }
    return (int8_t)quantized;
}

static double mel_energy(uint32_t band)
{
    uint32_t left = mel_bins[band];
    uint32_t center = mel_bins[band + 1U];
    uint32_t right = mel_bins[band + 2U];
    uint32_t bin;
    double energy = 0.0;

    if (center > left) {
        for (bin = left; bin < center; ++bin) {
            double weight =
                (double)(bin - left) / (double)(center - left);
            double real = fft_work[bin].real;
            double imag = fft_work[bin].imag;
            energy += (real * real + imag * imag) * weight;
        }
    }
    if (right > center) {
        for (bin = center; bin < right; ++bin) {
            double weight =
                (double)(right - bin) / (double)(right - center);
            double real = fft_work[bin].real;
            double imag = fft_work[bin].imag;
            energy += (real * real + imag * imag) * weight;
        }
    }
    return energy;
}

int retry_frontend_quantize_pcm(
    const int16_t pcm[RETRY_PCM_SAMPLE_COUNT],
    double gain,
    int8_t model_input[RETRY_MODEL_INPUT_COUNT]
)
{
    uint32_t frame;

    if ((pcm == NULL) || (model_input == NULL) ||
        (!isfinite(gain)) || (gain <= 0.0)) {
        return -1;
    }

    initialize_tables();

    for (frame = 0U; frame < FRAME_COUNT; ++frame) {
        uint32_t sample;
        uint32_t band;
        uint32_t frame_start = frame * FRAME_HOP;

        for (sample = 0U; sample < FRAME_LENGTH; ++sample) {
            double normalized =
                (double)pcm[frame_start + sample] * gain / 32767.0;
            if (normalized > 1.0) {
                normalized = 1.0;
            } else if (normalized < -1.0) {
                normalized = -1.0;
            }
            fft_work[sample].real = normalized * hamming_window[sample];
            fft_work[sample].imag = 0.0;
        }

        fft_in_place();

        for (band = 0U; band < MEL_BAND_COUNT; ++band) {
            double natural_log = log(mel_energy(band) + 1.0e-8);
            model_input[frame * MEL_BAND_COUNT + band] =
                quantize_ln(natural_log);
        }
    }

    return 0;
}
