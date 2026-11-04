#include <stdint.h>
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xtime_l.h"
#include "xuartps.h"
#include "dscnn.h"
#include "direction_estimator.h"
#include "retry_frontend.h"
#include "tjc_hmi.h"

#define MATRIX_ROWS       49U
#define MATRIX_COLS       40U
#define MATRIX_WORDS      (MATRIX_ROWS * MATRIX_COLS)

#define RAW_SAMPLES       512U
#define RAW_BATCH_FRAMES  32U
#define DIRECTION_CAPTURE_FRAMES 32U
#define RAW_SIGNATURE     0x4D494334U
#define RAW_ADDR_SIGNATURE 2044U
#define RAW_ADDR_METADATA  2045U
#define RAW_ADDR_EXIT      2046U
#define RAW_ADDR_ENTER     2047U

/* Stage 25 synchronized PCM + feature capture bridge. */
#define PAIR_PAGE0_ADDRESS     2020U
#define PAIR_FEATURE_ADDRESS  2024U
#define PAIR_ARM_ADDRESS      2026U
#define PAIR_COUNTS_ADDRESS   2027U
#define PAIR_METADATA_ADDRESS 2028U
#define PAIR_SIGNATURE_ADDRESS 2029U
#define PAIR_EXIT_ADDRESS     2030U
#define PAIR_ENTER_ADDRESS    2031U
#define PAIR_SIGNATURE        0x50414952U
#define PAIR_PCM_WORDS_PER_PAGE 1984U
#define PAIR_PAGE_COUNT       4U
#define PAIR_READY_TIMEOUT_MS 5000U
#define PAIR_CHANNEL_PAGE_BASE 1960U

#define TJC_UART1_BASE_ADDRESS 0xE0001000U
#define TJC_UART_INPUT_CLOCK_HZ 100000000U
#define TJC_UART_BAUD_RATE 9600U

/*
 * The QSPI-capable fallback FSBL used for standalone boot was generated from
 * a board example that leaves UART1 clock-gated.  JTAG initialization enabled
 * UART1, which is why the exact same application worked when downloaded but
 * stopped forever in XUartPs_IsSending after a cold QSPI boot.  Enable only
 * the two UART1 clock gates here so both boot paths use identical peripherals.
 */
#define SLCR_LOCK_ADDRESS       0xF8000004U
#define SLCR_UNLOCK_ADDRESS     0xF8000008U
#define SLCR_APER_CLK_CTRL      0xF800012CU
#define SLCR_UART_CLK_CTRL      0xF8000154U
#define SLCR_LOCK_KEY           0x0000767BU
#define SLCR_UNLOCK_KEY         0x0000DF0DU
#define UART1_APER_CLK_ENABLE   0x00200000U
#define UART1_REF_CLK_ENABLE    0x00000002U

/* Keep short events readable on the single-page serial display. */
#define DISPLAY_EVENT_HOLD_MS 8000U

/* Direction capture costs about one second, so do not restart it every frame. */
#define DIRECTION_REFRESH_MS 3000U
#define DIRECTION_DISPLAY_HOLD_MS DISPLAY_EVENT_HOLD_MS
#define DIRECTION_ACTIVITY_PEAK_Q8_8 4000U
#define DIRECTION_ACTIVITY_RANGE_Q8_8 600U

/* Stage 17 PS-to-PL visual alarm commands on unused read addresses. */
#define ALARM_COMMAND_BASE   2000U
#define ALARM_ACTION_IDLE    0U
#define ALARM_ACTION_BLUE    1U
#define ALARM_ACTION_YELLOW  2U
#define ALARM_ACTION_RED     3U
#define ALARM_VISUAL_RED_COMMAND 2004U
#define DIRECTION_COMMAND_BASE 2010U

#define ALARM_STATE_IDLE       0U
#define ALARM_STATE_CANDIDATE  1U
#define ALARM_STATE_CONFIRMED  2U

#define ALARM_CLASS_COUNT             8U
#define DIRECTION_PROVISIONAL_CLASS_ID ALARM_CLASS_COUNT
#define ALARM_POST_VIBRATION_COOLDOWN_MS 8000U
#define ALARM_ACK_MIN_HOLD_MS 1000U
#define ALARM_ACK_COOLDOWN_MS 8000U

/*
 * Temporary live-input activity gate.  The v3c model was trained with
 * per-recording peak normalization, while the board front end currently has
 * no matching AGC.  A 30-second noisy-room baseline peaked at 4906 Q8.8
 * counts and a controlled knock reached 6619.  Keep low-activity matrices out
 * of the model until the model owner supplies a live-input-compatible
 * checkpoint.
 */
#define MODEL_ACTIVITY_PEAK_FRAME_MEAN_Q8_8 4200U
#define MODEL_ACTIVITY_FRAME_MEAN_RANGE_Q8_8 300U

/*
 * Do not present a weak softmax winner as a definite sound class.  Field
 * background captures produced glass_break winners up to 152/255 even when
 * no target sound was playing.  Use conservative per-class acceptance
 * thresholds; rejected audible results become unknown instead of causing a
 * misleading label or alarm.  The Stage36 candidate's saved field regression
 * contains one real background window misclassified as knock at 167/255.
 * The first board soak still found a noise sequence at 225 then 193, whereas
 * the controlled three-knock test repeatedly reached 243..255.  Use 220/255
 * together with the PCM transient gate; this deliberately favors low false
 * alarms in the finished product over very weak single knocks.
 */
#define MODEL_ACCEPT_KNOCK_Q8          220U
#define MODEL_ACCEPT_BABY_CRY_Q8       145U
#define MODEL_ACCEPT_ORDINARY_Q8       170U
#define MODEL_ACCEPT_EMERGENCY_Q8      180U
#define MODEL_ACCEPT_GLASS_BREAK_Q8    180U

/*
 * A knock must be both a DS-CNN winner and a short PCM transient.  Continuous
 * room noise can look knock-like in Log-Mel space, but its one-second waveform
 * does not have the concentrated frame energy of a real impact.
 */
#define KNOCK_MIN_PEAK_TO_MEAN_Q8      384U /* 1.50x */
#define KNOCK_MAX_ACTIVE_FRAMES        12U
#define KNOCK_MIN_PCM_PEAK_MEAN_ABS    64U
#define KNOCK_MIN_PCM_MEAN_ABS         12U

/* 64x amplitude in the power domain is an additive 2*ln(64) Log-Mel shift. */
#define MODEL_GAIN_RETRY_LN_OFFSET 8.317766166719343

#define GPIO_DATA_OFFSET  0x00U
#define GPIO_TRI_OFFSET   0x04U
#define GPIO_DATA2_OFFSET 0x08U
#define GPIO_TRI2_OFFSET  0x0CU

#define JTAG_STATUS_WAIT  0x57414954U /* "WAIT" */
#define JTAG_STATUS_READY 0x52454144U /* "READ" */
#define JTAG_STATUS_ERROR 0x45525221U /* "ERR!" */

/* Zynq-7000 global timer runs at half the Cortex-A9 core clock. */
#define MODEL_TIMER_COUNTS_PER_SECOND (XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2U)

#if defined(XPAR_AXI_GPIO_0_BASEADDR)
#define MATRIX_GPIO_BASE XPAR_AXI_GPIO_0_BASEADDR
#elif defined(XPAR_XGPIO_0_BASEADDR)
#define MATRIX_GPIO_BASE XPAR_XGPIO_0_BASEADDR
#elif defined(XPAR_SYSTEM_AXI_GPIO_0_BASEADDR)
#define MATRIX_GPIO_BASE XPAR_SYSTEM_AXI_GPIO_0_BASEADDR
#else
#error "AXI GPIO base-address macro was not found in xparameters.h"
#endif

/*
 * These symbols remain global and volatile so XSCT can locate them directly
 * in the ELF and copy their contents through JTAG.
 */
volatile uint32_t jtag_capture_status = JTAG_STATUS_WAIT;

volatile uint32_t jtag_raw_status = JTAG_STATUS_WAIT;
volatile uint32_t jtag_raw_signature = 0U;
volatile uint32_t jtag_raw_sequence = 0U;
volatile uint32_t jtag_raw_count = 0U;
volatile int16_t jtag_raw_ch0[RAW_SAMPLES];
volatile int16_t jtag_raw_ch1[RAW_SAMPLES];
volatile int16_t jtag_raw_ch2[RAW_SAMPLES];
volatile int16_t jtag_raw_ch3[RAW_SAMPLES];

/* Stage 11 geometry-independent multi-frame JTAG cache. */
volatile uint32_t jtag_raw_batch_status = JTAG_STATUS_WAIT;
volatile uint32_t jtag_raw_batch_count = 0U;
volatile uint32_t jtag_raw_batch_sequences[RAW_BATCH_FRAMES];
volatile int16_t jtag_raw_batch_ch0[RAW_BATCH_FRAMES][RAW_SAMPLES];
volatile int16_t jtag_raw_batch_ch1[RAW_BATCH_FRAMES][RAW_SAMPLES];
volatile int16_t jtag_raw_batch_ch2[RAW_BATCH_FRAMES][RAW_SAMPLES];
volatile int16_t jtag_raw_batch_ch3[RAW_BATCH_FRAMES][RAW_SAMPLES];

volatile uint32_t jtag_matrix_sequence = 0U;
volatile uint32_t jtag_matrix_count = 0U;
volatile uint16_t jtag_matrix_cache[MATRIX_WORDS];

/* Stage 17 state is exported for JTAG inspection without a UART terminal. */
volatile uint32_t jtag_alarm_state = ALARM_STATE_IDLE;
volatile uint32_t jtag_alarm_action = ALARM_ACTION_IDLE;
volatile uint32_t jtag_alarm_class_id = 0U;
volatile uint32_t jtag_alarm_confidence_q8 = 0U;
volatile uint32_t jtag_alarm_timestamp_ms = 0U;
volatile uint32_t jtag_alarm_event_count = 0U;

/*
 * Use a global logical clock for policy/display timing.  The synchronized
 * front-end produces one new one-second matrix per loop, so this clock is
 * deterministic and cannot be damaged by the direction estimator's large
 * workspace/stack activity.
 */
static uint32_t live_timestamp_ms = 0U;

/* Stage 20 live INT8 inference state, exported for XSCT inspection. */
volatile uint32_t jtag_model_status = JTAG_STATUS_WAIT;
volatile uint32_t jtag_model_sequence = 0U;
volatile uint32_t jtag_model_inference_count = 0U;
volatile uint32_t jtag_model_class_id = 0U;
volatile uint32_t jtag_model_confidence_q8 = 0U;
volatile uint32_t jtag_model_last_inference_us = 0U;
volatile uint32_t jtag_model_max_inference_us = 0U;
volatile uint32_t jtag_model_min_inference_us = 0xFFFFFFFFU;
volatile int8_t jtag_model_logits[ALARM_CLASS_COUNT];
volatile uint32_t jtag_model_activity_peak_frame_mean_q8_8 = 0U;
volatile uint32_t jtag_model_activity_frame_mean_range_q8_8 = 0U;
volatile uint32_t jtag_model_raw_class_id = 0U;
volatile uint32_t jtag_model_raw_confidence_q8 = 0U;
volatile uint32_t jtag_model_rejection_count = 0U;
volatile uint32_t jtag_knock_pcm_peak_mean_abs = 0U;
volatile uint32_t jtag_knock_pcm_mean_abs = 0U;
volatile uint32_t jtag_knock_pcm_peak_to_mean_q8 = 0U;
volatile uint32_t jtag_knock_pcm_active_frames = 0U;
volatile uint32_t jtag_knock_transient_rejection_count = 0U;

/* Stage 29 unknown->knock conditional retry diagnostics. */
volatile uint32_t jtag_retry_trigger_count = 0U;
volatile uint32_t jtag_retry_knock_count = 0U;
volatile uint32_t jtag_retry_first_class_id = 0U;
volatile uint32_t jtag_retry_second_class_id = 0U;
volatile uint32_t jtag_retry_second_confidence_q8 = 0U;
volatile uint32_t jtag_retry_first_inference_us = 0U;
volatile uint32_t jtag_retry_feature_us = 0U;
volatile uint32_t jtag_retry_inference_us = 0U;
volatile uint32_t jtag_retry_total_us = 0U;

/* Stage 22 live four-microphone direction result, in JTAG-friendly units. */
volatile uint32_t jtag_direction_status = JTAG_STATUS_WAIT;
volatile uint32_t jtag_direction_valid = 0U;
volatile uint32_t jtag_direction_sector = 0U;
volatile uint32_t jtag_direction_angle_mdeg = 0U;
volatile uint32_t jtag_direction_magnitude_q16 = 0U;
volatile uint32_t jtag_direction_residual_um = 0U;
volatile uint32_t jtag_direction_rms_q8 = 0U;
volatile uint32_t jtag_direction_event_start = 0U;
volatile uint32_t jtag_direction_inference_us = 0U;
volatile uint32_t jtag_direction_capture_phase = 0U;
volatile int32_t jtag_direction_pair_lag_q12[STAGE22_DIRECTION_PAIRS];
volatile uint32_t jtag_direction_pair_ratio_q12[STAGE22_DIRECTION_PAIRS];

static DscnnWorkspace model_workspace;
static int16_t model_log2_q8_8[MATRIX_WORDS];
static float model_calibrated_ln[MATRIX_WORDS];
static int8_t model_input[DSCNN_INPUT_COUNT];
static int8_t model_output[ALARM_CLASS_COUNT];
static int8_t retry_model_input[DSCNN_INPUT_COUNT];
static int8_t retry_model_output[ALARM_CLASS_COUNT];
static int16_t paired_pcm[RETRY_PCM_SAMPLE_COUNT];
static Stage22DirectionResult direction_result;
static XUartPs display_uart;
static TjcHmi display_hmi;
static uint8_t display_ready;
static uint8_t display_held_class_id;
static uint8_t display_held_confidence_q8;
static uint8_t display_candidate_class_id;
static uint8_t display_candidate_count;
static uint32_t display_hold_until_ms;
static uint32_t direction_last_attempt_ms;
static uint32_t direction_last_valid_ms;
static uint8_t direction_stable_valid;
static uint8_t direction_stable_sector;
static uint8_t direction_candidate_sector;
static uint8_t direction_candidate_count;
static uint32_t direction_stable_angle_mdeg;
static uint8_t direction_event_class_id;

static void pair_capture_end(void);
static void pair_capture_read_direction_pcm(void);

static void stage32_enable_uart1_clock(void)
{
    uint32_t value;

    Xil_Out32(SLCR_UNLOCK_ADDRESS, SLCR_UNLOCK_KEY);

    value = Xil_In32(SLCR_UART_CLK_CTRL);
    Xil_Out32(SLCR_UART_CLK_CTRL, value | UART1_REF_CLK_ENABLE);

    value = Xil_In32(SLCR_APER_CLK_CTRL);
    Xil_Out32(SLCR_APER_CLK_CTRL, value | UART1_APER_CLK_ENABLE);

    Xil_Out32(SLCR_LOCK_ADDRESS, SLCR_LOCK_KEY);
}

static int display_uart_write(const uint8_t *data,
                              size_t length,
                              void *context)
{
    XUartPs *uart = (XUartPs *)context;
    size_t sent = 0U;

    while (sent < length) {
        unsigned int chunk = XUartPs_Send(
            uart,
            (uint8_t *)&data[sent],
            (unsigned int)(length - sent)
        );
        if (chunk == 0U) {
            return -1;
        }
        sent += chunk;
    }
    while (XUartPs_IsSending(uart) != 0) {
    }
    return 0;
}

static int display_initialize(void)
{
    XUartPs_Config config = {
        1U,
        TJC_UART1_BASE_ADDRESS,
        TJC_UART_INPUT_CLOCK_HZ,
        0
    };
    TjcHmiState initial = {
        0U, 0U, 0U, TJC_DIRECTION_UNKNOWN, 0U, 0U
    };
    int status;

    stage32_enable_uart1_clock();

    status = XUartPs_CfgInitialize(
        &display_uart,
        &config,
        TJC_UART1_BASE_ADDRESS
    );
    if (status != XST_SUCCESS) {
        return status;
    }
    XUartPs_SetOperMode(&display_uart, XUARTPS_OPER_MODE_NORMAL);
    status = XUartPs_SetBaudRate(&display_uart, TJC_UART_BAUD_RATE);
    if (status != XST_SUCCESS) {
        return status;
    }

    tjc_hmi_init(&display_hmi, display_uart_write, &display_uart);
    status = tjc_hmi_begin(&display_hmi, &initial);
    if (status == 0) {
        display_ready = 1U;
    }
    return status;
}

static void display_show_direction_pending(void)
{
    static const uint8_t value_command[] = {
        'v', 'a', '2', '.', 'v', 'a', 'l', '=', '8',
        0xFFU, 0xFFU, 0xFFU
    };
    static const uint8_t text_command[] = {
        't', '6', '.', 't', 'x', 't', '=', '"',
        0xB6U, 0xA8U, /* 定 */
        0xCEU, 0xBBU, /* 位 */
        0xD6U, 0xD0U, /* 中 */
        '"', 0xFFU, 0xFFU, 0xFFU
    };

    if (display_ready == 0U) {
        return;
    }

    (void)display_uart_write(
        value_command,
        sizeof(value_command),
        &display_uart
    );
    (void)display_uart_write(
        text_command,
        sizeof(text_command),
        &display_uart
    );

    /* The next normal publish must replace the temporary text unconditionally. */
    display_hmi.has_last_state = 0U;
}

static int time_before(uint32_t now_ms, uint32_t deadline_ms)
{
    return ((int32_t)(now_ms - deadline_ms) < 0);
}

static void display_clear_hold(void)
{
    display_held_class_id = 0U;
    display_held_confidence_q8 = 0U;
    display_candidate_class_id = 0U;
    display_candidate_count = 0U;
    display_hold_until_ms = 0U;
}

static void display_publish_prediction(uint8_t class_id,
                                       uint8_t confidence_q8,
                                       uint32_t timestamp_ms)
{
    TjcHmiState state;
    uint8_t held_active;
    uint8_t required_confirmations;

    if (display_ready == 0U) {
        return;
    }

    /*
     * Once any acoustic event has reached the confirmed alarm state, make
     * the HMI a true acknowledgement latch: class, confidence, direction,
     * LED action and motor action remain associated with that event until
     * the user presses the TJC confirm button.  In particular, later silence
     * or motor self-noise must not make the page fall back to recognizing.
     */
    if ((jtag_alarm_state == ALARM_STATE_CONFIRMED) &&
        (jtag_alarm_class_id >= 2U) &&
        (jtag_alarm_class_id < ALARM_CLASS_COUNT)) {
        display_held_class_id = (uint8_t)jtag_alarm_class_id;
        display_held_confidence_q8 =
            (uint8_t)jtag_alarm_confidence_q8;
        held_active = 1U;
    } else {
        held_active = ((display_held_class_id >= 2U) &&
                       time_before(timestamp_ms, display_hold_until_ms))
            ? 1U
            : 0U;
    }
    if ((display_held_class_id != 0U) && (held_active == 0U)) {
        display_held_class_id = 0U;
        display_held_confidence_q8 = 0U;
        display_hold_until_ms = 0U;
    }

    if (class_id >= 2U) {
        if (((class_id == 6U) &&
             (confidence_q8 >= MODEL_ACCEPT_GLASS_BREAK_Q8)) ||
            ((class_id == 4U) &&
             (confidence_q8 >= MODEL_ACCEPT_EMERGENCY_Q8))) {
            display_held_class_id = class_id;
            display_held_confidence_q8 = confidence_q8;
            display_hold_until_ms = timestamp_ms + DISPLAY_EVENT_HOLD_MS;
            display_candidate_class_id = 0U;
            display_candidate_count = 0U;
        } else if ((held_active != 0U) &&
            (class_id == display_held_class_id)) {
            display_held_confidence_q8 = confidence_q8;
            display_hold_until_ms = timestamp_ms + DISPLAY_EVENT_HOLD_MS;
            display_candidate_class_id = 0U;
            display_candidate_count = 0U;
        } else {
            if (class_id == display_candidate_class_id) {
                if (display_candidate_count < 255U) {
                    display_candidate_count++;
                }
            } else {
                display_candidate_class_id = class_id;
                display_candidate_count = 1U;
            }

            required_confirmations = (held_active != 0U) ? 3U : 2U;
            if (display_candidate_count >= required_confirmations) {
                display_held_class_id = class_id;
                display_held_confidence_q8 = confidence_q8;
                display_hold_until_ms = timestamp_ms + DISPLAY_EVENT_HOLD_MS;
                display_candidate_class_id = 0U;
                display_candidate_count = 0U;
            } else if (held_active != 0U) {
                class_id = display_held_class_id;
                confidence_q8 = display_held_confidence_q8;
            } else {
                class_id = TJC_CLASS_RECOGNIZING;
                confidence_q8 = 0U;
            }
        }
    } else if (class_id == 1U) {
        display_candidate_class_id = 0U;
        display_candidate_count = 0U;
        if (held_active != 0U) {
            class_id = display_held_class_id;
            confidence_q8 = display_held_confidence_q8;
        } else if ((jtag_model_raw_class_id >= 2U) &&
                   (jtag_model_raw_class_id < ALARM_CLASS_COUNT)) {
            class_id = TJC_CLASS_RECOGNIZING;
            confidence_q8 = 0U;
        }
    } else {
        display_candidate_class_id = 0U;
        display_candidate_count = 0U;
        if (held_active != 0U) {
            class_id = display_held_class_id;
            confidence_q8 = display_held_confidence_q8;
        } else if ((jtag_direction_valid != 0U) &&
                   (direction_event_class_id >= 2U) &&
                   (direction_event_class_id <=
                    DIRECTION_PROVISIONAL_CLASS_ID)) {
            /*
             * A short transient can end before the semantic class reaches its
             * confirmation count.  Keep the independently valid bearing on
             * screen as "recognizing" until its normal direction hold expires
             * instead of erasing it on the very next silence frame.
             */
            class_id = TJC_CLASS_RECOGNIZING;
            confidence_q8 = 0U;
        } else {
            display_clear_hold();
        }
    }

    state.class_id = class_id;
    state.confidence_q8 = confidence_q8;
    /*
     * Direction is an independent result: a short transient may localize
     * reliably even when the semantic model still says recognizing/unknown.
     * Keep the event-class association for confirmed labels so a held old
     * class can never inherit the bearing of a new candidate event.
     */
    /*
     * alarm_confirm() has already verified that this bearing belongs to the
     * confirmed acoustic event.  Do not apply a second class-association
     * filter here, because it can hide an otherwise valid direction.
     */
    state.direction_valid =
        ((jtag_alarm_state == ALARM_STATE_CONFIRMED) &&
         (jtag_direction_valid != 0U))
        ? 1U
        : 0U;
    state.direction_sector = (uint8_t)jtag_direction_sector;
    state.alarm_action = (uint8_t)jtag_alarm_action;
    state.motor_enabled = (jtag_alarm_action != ALARM_ACTION_IDLE) ? 1U : 0U;
    (void)tjc_hmi_publish(&display_hmi, &state, 0);
}

static int display_poll_acknowledge(void)
{
    uint8_t byte;

    if (display_ready == 0U) {
        return 0;
    }
    while (XUartPs_Recv(&display_uart, &byte, 1U) == 1U) {
        if (tjc_hmi_feed_rx(&display_hmi, byte) != 0) {
            return 1;
        }
    }
    return 0;
}

typedef struct {
    uint32_t timestamp_ms;
    uint8_t valid;
    uint8_t class_id;
    uint8_t confidence_q8;
} PredictionResult;

typedef struct {
    const char *name;
    uint8_t action;
    uint8_t threshold_q8;
    uint8_t confirmations;
    uint8_t emergency;
} AlarmPolicy;

static const AlarmPolicy alarm_policy[ALARM_CLASS_COUNT] = {
    {"silence",     ALARM_ACTION_IDLE,   0U,   1U, 0U},
    {"unknown",     ALARM_ACTION_IDLE,   0U,   1U, 0U},
    /*
     * Keep the actuator thresholds identical to the model acceptance
     * thresholds.  Otherwise a prediction can be accepted and held on the
     * display while the alarm state machine silently rejects it, producing a
     * visible alert with no WS2812/motor action.
     */
    {"knock",       ALARM_ACTION_BLUE,   MODEL_ACCEPT_KNOCK_Q8,       2U, 0U},
    {"alarm_clock", ALARM_ACTION_YELLOW, MODEL_ACCEPT_ORDINARY_Q8,    2U, 0U},
    /* Noisy-room soak produced a two-window 248/255 false emergency burst. */
    {"alarm_alert", ALARM_ACTION_RED,    MODEL_ACCEPT_EMERGENCY_Q8,   3U, 1U},
    {"baby_cry",    ALARM_ACTION_YELLOW, MODEL_ACCEPT_BABY_CRY_Q8,    2U, 0U},
    /* Class 6 remains in the 8-logit ABI but is disabled in this product. */
    {"glass_break", ALARM_ACTION_IDLE,   255U,                         255U, 0U},
    {"kettle",      ALARM_ACTION_BLUE,   MODEL_ACCEPT_ORDINARY_Q8,    2U, 0U}
};

static uint8_t alarm_candidate_class = 0U;
static uint8_t alarm_candidate_count = 0U;
static uint8_t alarm_confirmed_class = 0U;
static uint8_t alarm_confirmed_emergency = 0U;
static uint32_t alarm_confirmed_at_ms = 0U;
static uint32_t alarm_cooldown_until_ms = 0U;

static int alarm_direction_ready(uint8_t class_id)
{
    /*
     * A product-visible event is atomic: its semantic class and bearing must
     * come from the same acoustic event.  A provisional bearing is allowed to
     * adopt the first accepted semantic class, but an old/different class can
     * never borrow it.
     */
    return ((jtag_direction_valid != 0U) &&
            ((direction_event_class_id == class_id) ||
             (direction_event_class_id ==
              DIRECTION_PROVISIONAL_CLASS_ID))) ? 1 : 0;
}

static void alarm_write_action(uint8_t action)
{
    if (action > ALARM_ACTION_RED) {
        action = ALARM_ACTION_IDLE;
    }

    Xil_Out32(
        MATRIX_GPIO_BASE + GPIO_DATA_OFFSET,
        ALARM_COMMAND_BASE + (uint32_t)action
    );

    jtag_alarm_action = (uint32_t)action;
    Xil_DCacheFlush();
}

static void alarm_enter_idle(void)
{
    jtag_alarm_state = ALARM_STATE_IDLE;
    alarm_candidate_class = 0U;
    alarm_candidate_count = 0U;
    alarm_confirmed_class = 0U;
    alarm_confirmed_emergency = 0U;
    alarm_confirmed_at_ms = 0U;
    alarm_write_action(ALARM_ACTION_IDLE);
}

static void alarm_confirm(uint8_t class_id,
                          uint8_t confidence_q8,
                          uint32_t timestamp_ms)
{
    const AlarmPolicy *policy = &alarm_policy[class_id];

    jtag_alarm_state = ALARM_STATE_CONFIRMED;
    jtag_alarm_class_id = class_id;
    jtag_alarm_confidence_q8 = confidence_q8;
    alarm_confirmed_class = class_id;
    alarm_confirmed_emergency = policy->emergency;
    alarm_confirmed_at_ms = timestamp_ms;
    alarm_candidate_count = 0U;

    /*
     * Keep the user-visible result and physical outputs atomic.  At 9600 baud
     * the old ordering could start the strip and motor while the HMI was still
     * blank.  Queue the complete label/direction update before enabling the
     * actuator action.
     */
    display_publish_prediction(class_id, confidence_q8, timestamp_ms);
    alarm_write_action(policy->action);

    xil_printf(
        "ALARM_CONFIRMED,time=%u,class=%s,confidence_q8=%u,action=%u\r\n",
        (unsigned int)timestamp_ms,
        policy->name,
        (unsigned int)confidence_q8,
        (unsigned int)policy->action
    );
}

static void alarm_handle_prediction(const PredictionResult *result)
{
    const AlarmPolicy *policy;

    jtag_alarm_timestamp_ms = result->timestamp_ms;
    jtag_alarm_event_count++;

    /*
     * Preserve the confirmed event payload as well as its physical action.
     * Background inference continues for diagnostics, but must not overwrite
     * the class/confidence that the acknowledgement-latched HMI publishes.
     */
    if (jtag_alarm_state == ALARM_STATE_CONFIRMED) {
        return;
    }

    jtag_alarm_class_id = result->class_id;
    jtag_alarm_confidence_q8 = result->confidence_q8;

    if ((!result->valid) || (result->class_id >= ALARM_CLASS_COUNT)) {
        alarm_candidate_count = 0U;
        return;
    }

    policy = &alarm_policy[result->class_id];

    xil_printf(
        "PREDICTION,time=%u,class=%s,confidence_q8=%u\r\n",
        (unsigned int)result->timestamp_ms,
        policy->name,
        (unsigned int)result->confidence_q8
    );

    /*
     * Do not let vibration from an active alarm feed back into the
     * microphones and retrigger the classifier.  Every confirmed event is
     * intentionally held until the TJC acknowledgement clears the output.
     */
    /* Allow the one-second feature window to become free of motor noise. */
    if ((int32_t)(result->timestamp_ms - alarm_cooldown_until_ms) < 0) {
        alarm_candidate_count = 0U;
        return;
    }

    if (result->class_id == 0U) {
        alarm_candidate_count = 0U;

        if (!alarm_confirmed_emergency) {
            alarm_enter_idle();
        }
        return;
    }

    if (result->class_id == 1U) {
        alarm_candidate_count = 0U;
        return;
    }

    if (result->confidence_q8 < policy->threshold_q8) {
        alarm_candidate_count = 0U;

        if (jtag_alarm_state == ALARM_STATE_CANDIDATE) {
            jtag_alarm_state = ALARM_STATE_IDLE;
        }
        return;
    }

    /*
     * Emergency events used to bypass the confirmation counter as soon as a
     * direction was available.  That made a single noisy alarm_alert winner
     * start the red strip and motor even though its policy requested three
     * consecutive windows.  All actionable classes now share the same
     * confirmation path; the emergency flag only describes the latched event
     * after confirmation.
     */
    if ((alarm_candidate_count == 0U) ||
        (alarm_candidate_class != result->class_id)) {
        alarm_candidate_class = result->class_id;
        alarm_candidate_count = 1U;
    } else if (alarm_candidate_count < 255U) {
        alarm_candidate_count++;
    }

    jtag_alarm_state = ALARM_STATE_CANDIDATE;

    if ((alarm_candidate_count >= policy->confirmations) &&
        alarm_direction_ready(result->class_id)) {
        alarm_confirm(
            result->class_id,
            result->confidence_q8,
            result->timestamp_ms
        );
    }
}

static void alarm_check_timeout(uint32_t timestamp_ms)
{
    /*
     * Deliberately no automatic release.  All six actionable classes use
     * the same operator-acknowledged lifecycle so a short sound cannot vanish
     * from the display and ordinary alarms cannot return to green by timeout.
     */
    (void)timestamp_ms;
}

static uint32_t matrix_read_word(uint32_t address)
{
    uint32_t value;

    Xil_Out32(MATRIX_GPIO_BASE + GPIO_DATA_OFFSET, address);

    /*
     * The PL path now contains the original registered Log-Mel read port plus
     * the Stage 9 registered bridge. Three reads provide ample settling time.
     */
    (void)Xil_In32(MATRIX_GPIO_BASE + GPIO_DATA2_OFFSET);
    (void)Xil_In32(MATRIX_GPIO_BASE + GPIO_DATA2_OFFSET);
    value = Xil_In32(MATRIX_GPIO_BASE + GPIO_DATA2_OFFSET);

    return value;
}

static void leave_raw_mode(void)
{
    (void)matrix_read_word(RAW_ADDR_EXIT);
    usleep(100U);
}

static int capture_raw_snapshot(uint32_t expected_sequence,
                                int accept_any_sequence)
{
    uint32_t index;
    uint32_t pair01;
    uint32_t pair23;
    uint32_t metadata;

    /*
     * Stage 12 does not use a fixed frame delay. Enter raw mode briefly,
     * inspect the completed-frame sequence, and read the snapshot only
     * when it is the exact frame requested by capture_raw_batch().
     */
    (void)matrix_read_word(RAW_ADDR_ENTER);
    usleep(100U);

    jtag_raw_signature = matrix_read_word(RAW_ADDR_SIGNATURE);

    if (jtag_raw_signature != RAW_SIGNATURE) {
        leave_raw_mode();
        return 0;
    }

    metadata = matrix_read_word(RAW_ADDR_METADATA);
    jtag_raw_sequence = metadata >> 16;

    if ((jtag_raw_sequence == 0U) ||
        ((!accept_any_sequence) &&
         (jtag_raw_sequence != expected_sequence))) {
        leave_raw_mode();
        return 0;
    }

    for (index = 0U; index < RAW_SAMPLES; ++index) {
        pair01 = matrix_read_word(index);
        pair23 = matrix_read_word(RAW_SAMPLES + index);

        jtag_raw_ch0[index] = (int16_t)(pair01 & 0xFFFFU);
        jtag_raw_ch1[index] = (int16_t)((pair01 >> 16) & 0xFFFFU);
        jtag_raw_ch2[index] = (int16_t)(pair23 & 0xFFFFU);
        jtag_raw_ch3[index] = (int16_t)((pair23 >> 16) & 0xFFFFU);
    }

    jtag_raw_count = RAW_SAMPLES;
    jtag_raw_status = JTAG_STATUS_READY;

    leave_raw_mode();
    return 1;
}

static int capture_raw_batch(uint32_t frame_count)
{
    uint32_t frame;
    uint32_t index;
    uint32_t last_sequence = 0U;
    uint32_t expected_sequence;
    unsigned int attempt;

    jtag_raw_batch_status = JTAG_STATUS_WAIT;
    jtag_raw_batch_count = 0U;

    if ((frame_count == 0U) || (frame_count > RAW_BATCH_FRAMES)) {
        jtag_raw_batch_status = JTAG_STATUS_ERROR;
        Xil_DCacheFlush();
        return 0;
    }

    for (frame = 0U; frame < frame_count; ++frame) {
        expected_sequence =
            (frame == 0U)
                ? 0U
                : ((last_sequence + 1U) & 0xFFFFU);

        for (attempt = 0U; attempt < 128U; ++attempt) {
            if (capture_raw_snapshot(
                    expected_sequence,
                    frame == 0U)) {
                break;
            }

            usleep(1000U);
        }

        if (attempt == 128U) {
            jtag_raw_batch_status = JTAG_STATUS_ERROR;
            Xil_DCacheFlush();
            return 0;
        }

        jtag_raw_batch_sequences[frame] = jtag_raw_sequence;

        for (index = 0U; index < RAW_SAMPLES; ++index) {
            jtag_raw_batch_ch0[frame][index] = jtag_raw_ch0[index];
            jtag_raw_batch_ch1[frame][index] = jtag_raw_ch1[index];
            jtag_raw_batch_ch2[frame][index] = jtag_raw_ch2[index];
            jtag_raw_batch_ch3[frame][index] = jtag_raw_ch3[index];
        }

        last_sequence = jtag_raw_sequence;
        jtag_raw_batch_count = frame + 1U;
        Xil_DCacheFlush();
    }

    jtag_raw_batch_status = JTAG_STATUS_READY;
    Xil_DCacheFlush();
    return 1;
}

static int estimate_captured_direction(void)
{
    const int16_t *channels[STAGE22_DIRECTION_CHANNELS];
    XTime start_ticks;
    XTime end_ticks;
    uint64_t elapsed_us;
    uint32_t index;
    int status;

    channels[0] = (const int16_t *)&jtag_raw_batch_ch0[0][0];
    channels[1] = (const int16_t *)&jtag_raw_batch_ch1[0][0];
    channels[2] = (const int16_t *)&jtag_raw_batch_ch2[0][0];
    channels[3] = (const int16_t *)&jtag_raw_batch_ch3[0][0];

    jtag_direction_status = JTAG_STATUS_WAIT;
    Xil_DCacheFlush();
    XTime_GetTime(&start_ticks);
    status = stage22_estimate_direction(
        channels,
        jtag_raw_batch_count * RAW_SAMPLES,
        &direction_result
    );
    XTime_GetTime(&end_ticks);

    elapsed_us =
        ((uint64_t)(end_ticks - start_ticks) * UINT64_C(1000000)) /
        (uint64_t)MODEL_TIMER_COUNTS_PER_SECOND;
    if (elapsed_us > UINT32_MAX) {
        elapsed_us = UINT32_MAX;
    }
    jtag_direction_inference_us = (uint32_t)elapsed_us;

    if (status != 0) {
        jtag_direction_status = JTAG_STATUS_ERROR;
        Xil_DCacheFlush();
        xil_printf("DIRECTION_ERROR,status=%d\r\n", status);
        return status;
    }

    if (direction_result.valid != 0U) {
        uint32_t raw_angle_mdeg =
            (uint32_t)(direction_result.angle_degrees * 1000.0f + 0.5f);

        if (direction_stable_valid == 0U) {
            direction_stable_valid = 1U;
            direction_stable_sector = direction_result.sector;
            direction_stable_angle_mdeg = raw_angle_mdeg;
            direction_candidate_count = 0U;
        } else if (direction_result.sector == direction_stable_sector) {
            direction_stable_angle_mdeg = raw_angle_mdeg;
            direction_candidate_count = 0U;
        } else {
            if (direction_result.sector == direction_candidate_sector) {
                if (direction_candidate_count < 255U) {
                    direction_candidate_count++;
                }
            } else {
                direction_candidate_sector = direction_result.sector;
                direction_candidate_count = 1U;
            }

            if (direction_candidate_count >= 2U) {
                direction_stable_sector = direction_result.sector;
                direction_stable_angle_mdeg = raw_angle_mdeg;
                direction_candidate_count = 0U;
            }
        }

        jtag_direction_valid = 1U;
        jtag_direction_sector = direction_stable_sector;
        jtag_direction_angle_mdeg = direction_stable_angle_mdeg;
    }
    jtag_direction_magnitude_q16 =
        (uint32_t)(direction_result.vector_magnitude * 65536.0f + 0.5f);
    jtag_direction_residual_um =
        (uint32_t)(direction_result.fit_residual_mm * 1000.0f + 0.5f);
    jtag_direction_rms_q8 =
        (uint32_t)(direction_result.event_rms * 256.0f + 0.5f);
    jtag_direction_event_start = direction_result.event_start_sample;

    for (index = 0U; index < STAGE22_DIRECTION_PAIRS; ++index) {
        float lag_q12 = direction_result.pair_lag_samples[index] * 4096.0f;
        jtag_direction_pair_lag_q12[index] =
            (int32_t)(lag_q12 + ((lag_q12 >= 0.0f) ? 0.5f : -0.5f));
        jtag_direction_pair_ratio_q12[index] = (uint32_t)(
            direction_result.pair_correlation[index] * 4096.0f + 0.5f
        );
    }

    jtag_direction_status = JTAG_STATUS_READY;
    if (jtag_direction_valid != 0U) {
        Xil_Out32(
            MATRIX_GPIO_BASE + GPIO_DATA_OFFSET,
            DIRECTION_COMMAND_BASE + jtag_direction_sector
        );
    }
    Xil_DCacheFlush();
    xil_printf(
        "DIRECTION,valid=%u,sector=%u,name=%s,angle_mdeg=%u,"
        "magnitude_q16=%u,residual_um=%u,rms_q8=%u,time_us=%u\r\n",
        (unsigned int)jtag_direction_valid,
        (unsigned int)jtag_direction_sector,
        stage22_direction_name(jtag_direction_sector),
        (unsigned int)jtag_direction_angle_mdeg,
        (unsigned int)jtag_direction_magnitude_q16,
        (unsigned int)jtag_direction_residual_um,
        (unsigned int)jtag_direction_rms_q8,
        (unsigned int)jtag_direction_inference_us
    );
    return 0;
}

static void update_direction_for_event(uint32_t timestamp_ms)
{
    int status;

    if ((direction_last_attempt_ms != 0U) &&
        time_before(timestamp_ms,
                    direction_last_attempt_ms + DIRECTION_REFRESH_MS)) {
        return;
    }

    direction_last_attempt_ms = timestamp_ms;
    jtag_direction_capture_phase = 1U;
    Xil_DCacheFlush();

    /*
     * Read all four microphones from the same frozen 15,872-sample interval
     * that produced the classified 49x40 matrix.  The previous implementation
     * started a new raw capture only after classification, so short events had
     * already ended and direction was estimated from later room noise.
     */
    pair_capture_read_direction_pcm();
    jtag_direction_capture_phase = 2U;
    Xil_DCacheFlush();
    status = estimate_captured_direction();
    if (status != 0) {
        jtag_direction_capture_phase = 4U;
        jtag_direction_status = JTAG_STATUS_ERROR;
        Xil_DCacheFlush();
        xil_printf("DIRECTION_CAPTURE_ERROR,status=%d\r\n", status);
    } else {
        jtag_direction_capture_phase = 3U;
        if (direction_result.valid != 0U) {
            direction_last_valid_ms = timestamp_ms;
        } else {
            /* An ambiguous noise window must not own the next real event. */
            direction_event_class_id = 0U;
            direction_last_attempt_ms = 0U;
        }
        Xil_DCacheFlush();
    }

}

static uint16_t wait_for_next_matrix(void)
{
    uint16_t old_sequence;
    uint16_t new_sequence;

    old_sequence = (uint16_t)(matrix_read_word(0U) >> 16);

    do {
        new_sequence = (uint16_t)(matrix_read_word(0U) >> 16);
    } while (new_sequence == old_sequence);

    return new_sequence;
}

static int capture_matrix(uint16_t expected_sequence)
{
    uint32_t address;
    uint32_t word;
    uint16_t final_sequence;

    for (address = 0U; address < MATRIX_WORDS; ++address) {
        word = matrix_read_word(address);
        jtag_matrix_cache[address] = (uint16_t)(word & 0xFFFFU);
    }

    final_sequence =
        (uint16_t)(matrix_read_word(MATRIX_WORDS - 1U) >> 16);

    return final_sequence == expected_sequence;
}

static uint32_t elapsed_microseconds(XTime start_ticks, XTime end_ticks)
{
    uint64_t elapsed_us =
        ((uint64_t)(end_ticks - start_ticks) * UINT64_C(1000000)) /
        (uint64_t)MODEL_TIMER_COUNTS_PER_SECOND;
    return (elapsed_us > UINT32_MAX) ? UINT32_MAX : (uint32_t)elapsed_us;
}

static int pair_capture_begin(void)
{
    uint32_t metadata = 0U;
    uint32_t signature = 0U;
    uint32_t waited_ms;

    (void)matrix_read_word(PAIR_ENTER_ADDRESS);
    (void)matrix_read_word(PAIR_ARM_ADDRESS);

    for (waited_ms = 0U; waited_ms < PAIR_READY_TIMEOUT_MS; ++waited_ms) {
        signature = matrix_read_word(PAIR_SIGNATURE_ADDRESS);
        metadata = matrix_read_word(PAIR_METADATA_ADDRESS);
        if ((signature == PAIR_SIGNATURE) && ((metadata & 1U) != 0U)) {
            break;
        }
        usleep(1000U);
    }

    if ((signature != PAIR_SIGNATURE) || ((metadata & 1U) == 0U) ||
        ((metadata & 2U) != 0U)) {
        (void)matrix_read_word(PAIR_EXIT_ADDRESS);
        return -1;
    }
    if (matrix_read_word(PAIR_COUNTS_ADDRESS) !=
        ((RETRY_PCM_SAMPLE_COUNT << 16U) | MATRIX_WORDS)) {
        (void)matrix_read_word(PAIR_EXIT_ADDRESS);
        return -2;
    }

    jtag_matrix_sequence = (metadata >> 16U) & 0xFFFFU;
    return 0;
}

static void pair_capture_read_matrix(void)
{
    uint32_t address;

    (void)matrix_read_word(PAIR_FEATURE_ADDRESS);
    for (address = 0U; address < MATRIX_WORDS; ++address) {
        jtag_matrix_cache[address] =
            (uint16_t)(matrix_read_word(address) & 0xFFFFU);
    }
    jtag_matrix_count = MATRIX_WORDS;
}

static void pair_capture_read_pcm(void)
{
    uint32_t page;
    uint32_t address;
    uint32_t sample_index = 0U;

    for (page = 0U; page < PAIR_PAGE_COUNT; ++page) {
        (void)matrix_read_word(PAIR_PAGE0_ADDRESS + page);
        for (address = 0U; address < PAIR_PCM_WORDS_PER_PAGE; ++address) {
            uint32_t word = matrix_read_word(address);
            paired_pcm[sample_index++] = (int16_t)(word & 0xFFFFU);
            paired_pcm[sample_index++] = (int16_t)((word >> 16U) & 0xFFFFU);
        }
    }
}

static int knock_pcm_is_transient(void)
{
    uint32_t frame;
    uint32_t sample;
    uint32_t peak_frame_mean_abs = 0U;
    uint32_t active_frames = 0U;
    uint64_t total_abs = 0U;
    int64_t dc_sum = 0;
    int32_t dc_mean;
    uint32_t mean_abs;
    uint32_t ratio_q8;

    for (sample = 0U; sample < RETRY_PCM_SAMPLE_COUNT; ++sample) {
        dc_sum += (int64_t)paired_pcm[sample];
    }
    dc_mean = (int32_t)(dc_sum / (int64_t)RETRY_PCM_SAMPLE_COUNT);

    for (frame = 0U;
         frame < (RETRY_PCM_SAMPLE_COUNT / RAW_SAMPLES);
         ++frame) {
        uint64_t frame_abs = 0U;
        uint32_t frame_mean_abs;

        for (sample = 0U; sample < RAW_SAMPLES; ++sample) {
            int32_t centered =
                (int32_t)paired_pcm[frame * RAW_SAMPLES + sample] - dc_mean;
            uint32_t magnitude =
                (uint32_t)((centered < 0) ? -centered : centered);
            frame_abs += magnitude;
        }
        frame_mean_abs = (uint32_t)(frame_abs / RAW_SAMPLES);
        total_abs += frame_abs;
        if (frame_mean_abs > peak_frame_mean_abs) {
            peak_frame_mean_abs = frame_mean_abs;
        }
    }

    mean_abs = (uint32_t)(total_abs / RETRY_PCM_SAMPLE_COUNT);
    ratio_q8 = (mean_abs == 0U)
        ? 0U
        : (uint32_t)(((uint64_t)peak_frame_mean_abs * 256U) / mean_abs);

    if (peak_frame_mean_abs != 0U) {
        for (frame = 0U;
             frame < (RETRY_PCM_SAMPLE_COUNT / RAW_SAMPLES);
             ++frame) {
            uint64_t frame_abs = 0U;
            uint32_t frame_mean_abs;

            for (sample = 0U; sample < RAW_SAMPLES; ++sample) {
                int32_t centered =
                    (int32_t)paired_pcm[frame * RAW_SAMPLES + sample] -
                    dc_mean;
                uint32_t magnitude =
                    (uint32_t)((centered < 0) ? -centered : centered);
                frame_abs += magnitude;
            }
            frame_mean_abs = (uint32_t)(frame_abs / RAW_SAMPLES);
            if (((uint64_t)frame_mean_abs * 2U) >= peak_frame_mean_abs) {
                active_frames++;
            }
        }
    }

    jtag_knock_pcm_peak_mean_abs = peak_frame_mean_abs;
    jtag_knock_pcm_mean_abs = mean_abs;
    jtag_knock_pcm_peak_to_mean_q8 = ratio_q8;
    jtag_knock_pcm_active_frames = active_frames;

    return (peak_frame_mean_abs >= KNOCK_MIN_PCM_PEAK_MEAN_ABS) &&
           (mean_abs >= KNOCK_MIN_PCM_MEAN_ABS) &&
           (ratio_q8 >= KNOCK_MIN_PEAK_TO_MEAN_Q8) &&
           (active_frames <= KNOCK_MAX_ACTIVE_FRAMES);
}

static void pair_capture_read_pcm_channel(
    uint32_t channel,
    volatile int16_t *destination
)
{
    uint32_t page;
    uint32_t address;
    uint32_t sample_index = 0U;

    for (page = 0U; page < PAIR_PAGE_COUNT; ++page) {
        (void)matrix_read_word(
            PAIR_CHANNEL_PAGE_BASE + channel * PAIR_PAGE_COUNT + page
        );
        for (address = 0U; address < PAIR_PCM_WORDS_PER_PAGE; ++address) {
            uint32_t word = matrix_read_word(address);
            destination[sample_index++] = (int16_t)(word & 0xFFFFU);
            destination[sample_index++] =
                (int16_t)((word >> 16U) & 0xFFFFU);
        }
    }
}

static void pair_capture_read_direction_pcm(void)
{
    pair_capture_read_pcm_channel(
        0U,
        &jtag_raw_batch_ch0[0][0]
    );
    pair_capture_read_pcm_channel(
        1U,
        &jtag_raw_batch_ch1[0][0]
    );
    pair_capture_read_pcm_channel(
        2U,
        &jtag_raw_batch_ch2[0][0]
    );
    pair_capture_read_pcm_channel(
        3U,
        &jtag_raw_batch_ch3[0][0]
    );
    jtag_raw_batch_count = RETRY_PCM_SAMPLE_COUNT / RAW_SAMPLES;
}

static void pair_capture_end(void)
{
    (void)matrix_read_word(PAIR_EXIT_ADDRESS);
}

static int quantize_calibrated_pl_matrix_to(
    double natural_log_offset,
    int8_t output[DSCNN_INPUT_COUNT]
)
{
    uint32_t index;

    /* Stage25 paired-data fit from unsigned PL Log2 Q8.8 to model ln. */
    for (index = 0U; index < MATRIX_WORDS; ++index) {
        model_calibrated_ln[index] = (float)(
            (double)model_log2_q8_8[index] * 0.002755681736090 +
            (-21.011273721790065) + natural_log_offset
        );
    }
    return dscnn_quantize_ln(model_calibrated_ln, output);
}

static int quantize_calibrated_pl_matrix(void)
{
    return quantize_calibrated_pl_matrix_to(0.0, model_input);
}

static int classify_current_matrix(uint16_t sequence,
                                   uint32_t timestamp_ms,
                                   PredictionResult *prediction)
{
    DscnnResult result;
    XTime start_ticks;
    XTime end_ticks;
    uint64_t elapsed_us;
    uint32_t frame;
    uint32_t band;
    uint32_t frame_sum;
    uint32_t frame_mean;
    uint32_t activity_min_frame_mean = UINT32_MAX;
    uint32_t activity_peak_frame_mean = 0U;
    uint32_t activity_frame_mean_range;
    uint32_t index;
    int status;

    if (prediction == 0) {
        return -1;
    }

    for (frame = 0U; frame < MATRIX_ROWS; ++frame) {
        frame_sum = 0U;

        for (band = 0U; band < MATRIX_COLS; ++band) {
            index = frame * MATRIX_COLS + band;
            model_log2_q8_8[index] = (int16_t)jtag_matrix_cache[index];
            frame_sum += (uint32_t)jtag_matrix_cache[index];
        }

        frame_mean = frame_sum / MATRIX_COLS;
        if (frame_mean > activity_peak_frame_mean) {
            activity_peak_frame_mean = frame_mean;
        }
        if (frame_mean < activity_min_frame_mean) {
            activity_min_frame_mean = frame_mean;
        }
    }

    activity_frame_mean_range =
        activity_peak_frame_mean - activity_min_frame_mean;
    jtag_model_activity_peak_frame_mean_q8_8 = activity_peak_frame_mean;
    jtag_model_activity_frame_mean_range_q8_8 = activity_frame_mean_range;

    if ((activity_peak_frame_mean < MODEL_ACTIVITY_PEAK_FRAME_MEAN_Q8_8) &&
        (activity_frame_mean_range <
         MODEL_ACTIVITY_FRAME_MEAN_RANGE_Q8_8)) {
        prediction->timestamp_ms = timestamp_ms;
        prediction->valid = 1U;
        prediction->class_id = 0U;
        prediction->confidence_q8 = 255U;

        jtag_model_sequence = (uint32_t)sequence;
        jtag_model_class_id = 0U;
        jtag_model_confidence_q8 = 255U;
        jtag_model_last_inference_us = 0U;
        jtag_model_inference_count++;

        for (index = 0U; index < ALARM_CLASS_COUNT; ++index) {
            jtag_model_logits[index] = 0;
        }

        jtag_model_status = JTAG_STATUS_READY;
        Xil_DCacheFlush();
        return 0;
    }

    XTime_GetTime(&start_ticks);

    status = quantize_calibrated_pl_matrix();
    if (status != 0) {
        return status;
    }

    status = dscnn_infer(
        model_input,
        model_output,
        &model_workspace,
        0,
        0
    );
    if (status != 0) {
        return status;
    }

    result = dscnn_result(model_output);
    XTime_GetTime(&end_ticks);

    elapsed_us =
        ((uint64_t)(end_ticks - start_ticks) * UINT64_C(1000000)) /
        (uint64_t)MODEL_TIMER_COUNTS_PER_SECOND;
    if (elapsed_us > UINT32_MAX) {
        elapsed_us = UINT32_MAX;
    }

    jtag_model_last_inference_us = (uint32_t)elapsed_us;
    if (jtag_model_last_inference_us > jtag_model_max_inference_us) {
        jtag_model_max_inference_us = jtag_model_last_inference_us;
    }
    if (jtag_model_last_inference_us < jtag_model_min_inference_us) {
        jtag_model_min_inference_us = jtag_model_last_inference_us;
    }

    prediction->timestamp_ms = timestamp_ms;
    prediction->valid = 1U;
    prediction->class_id = result.class_id;
    prediction->confidence_q8 = result.confidence_q8;

    jtag_model_sequence = (uint32_t)sequence;
    jtag_model_class_id = (uint32_t)result.class_id;
    jtag_model_confidence_q8 = (uint32_t)result.confidence_q8;
    jtag_model_inference_count++;

    for (index = 0U; index < ALARM_CLASS_COUNT; ++index) {
        jtag_model_logits[index] = model_output[index];
    }

    jtag_model_status = JTAG_STATUS_READY;
    Xil_DCacheFlush();
    return 0;
}

/*
 * The training script peak-normalized each recording, but a global live AGC
 * damages already-correct glass/kettle/silence decisions.  Stage25 paired
 * captures showed a safer policy: only retry a real model inference whose
 * first result is silence/unknown, add the fixed 64x power-domain Log-Mel
 * shift, and accept only the two classes that improved consistently (knock
 * and baby_cry).  The activity-gate silence shortcut has inference_us == 0
 * and is deliberately excluded so room noise is never amplified.
 */
static int apply_low_level_event_retry(PredictionResult *prediction)
{
    DscnnResult retry_result;
    XTime feature_start;
    XTime feature_end;
    XTime inference_start;
    XTime inference_end;
    uint32_t index;
    int status;
    int accept_retry;

    if (prediction == 0) {
        return -1;
    }
    if (((prediction->class_id != 0U) && (prediction->class_id != 1U)) ||
        (jtag_model_last_inference_us == 0U)) {
        return 0;
    }

    jtag_retry_first_class_id = prediction->class_id;
    jtag_retry_first_inference_us = jtag_model_last_inference_us;
    jtag_retry_second_class_id = UINT32_MAX;
    jtag_retry_second_confidence_q8 = 0U;
    jtag_retry_feature_us = 0U;
    jtag_retry_inference_us = 0U;
    jtag_retry_total_us = jtag_retry_first_inference_us;
    jtag_retry_trigger_count++;

    XTime_GetTime(&feature_start);
    status = quantize_calibrated_pl_matrix_to(
        MODEL_GAIN_RETRY_LN_OFFSET,
        retry_model_input
    );
    XTime_GetTime(&feature_end);
    jtag_retry_feature_us = elapsed_microseconds(feature_start, feature_end);
    if (status != 0) {
        return status;
    }

    XTime_GetTime(&inference_start);
    status = dscnn_infer(
        retry_model_input,
        retry_model_output,
        &model_workspace,
        0,
        0
    );
    XTime_GetTime(&inference_end);
    jtag_retry_inference_us =
        elapsed_microseconds(inference_start, inference_end);
    if (status != 0) {
        return status;
    }

    retry_result = dscnn_result(retry_model_output);
    jtag_retry_second_class_id = retry_result.class_id;
    jtag_retry_second_confidence_q8 = retry_result.confidence_q8;
    jtag_retry_total_us =
        jtag_retry_first_inference_us +
        jtag_retry_feature_us +
        jtag_retry_inference_us;

    accept_retry =
        ((retry_result.class_id == 2U) &&
         (retry_result.confidence_q8 >= MODEL_ACCEPT_KNOCK_Q8)) ||
        ((retry_result.class_id == 5U) &&
         (retry_result.confidence_q8 >= MODEL_ACCEPT_BABY_CRY_Q8));

    if (accept_retry) {
        prediction->class_id = retry_result.class_id;
        prediction->confidence_q8 = retry_result.confidence_q8;
        jtag_model_class_id = retry_result.class_id;
        jtag_model_confidence_q8 = retry_result.confidence_q8;
        if (retry_result.class_id == 2U) {
            jtag_retry_knock_count++;
        }
        for (index = 0U; index < ALARM_CLASS_COUNT; ++index) {
            jtag_model_logits[index] = retry_model_output[index];
        }
    }

    xil_printf(
        "GAIN_RETRY,first=%u,second=%u,confidence_q8=%u,final=%u\r\n",
        (unsigned int)jtag_retry_first_class_id,
        (unsigned int)jtag_retry_second_class_id,
        (unsigned int)jtag_retry_second_confidence_q8,
        (unsigned int)prediction->class_id
    );
    Xil_DCacheFlush();
    return 0;
}

static int apply_unknown_knock_retry(PredictionResult *prediction)
{
    DscnnResult retry_result;
    XTime feature_start;
    XTime feature_end;
    XTime inference_start;
    XTime inference_end;
    uint64_t total_us;
    uint32_t index;
    int status;

    if (prediction == 0) {
        return -1;
    }

    jtag_retry_first_class_id = prediction->class_id;
    jtag_retry_first_inference_us = jtag_model_last_inference_us;
    jtag_retry_second_class_id = UINT32_MAX;
    jtag_retry_second_confidence_q8 = 0U;
    jtag_retry_feature_us = 0U;
    jtag_retry_inference_us = 0U;
    jtag_retry_total_us = jtag_retry_first_inference_us;

    if (prediction->class_id != 1U) {
        return 0;
    }

    jtag_retry_trigger_count++;
    XTime_GetTime(&feature_start);
    status = retry_frontend_quantize_pcm(
        paired_pcm,
        2.0,
        retry_model_input
    );
    XTime_GetTime(&feature_end);
    jtag_retry_feature_us = elapsed_microseconds(feature_start, feature_end);
    if (status != 0) {
        return status;
    }

    XTime_GetTime(&inference_start);
    status = dscnn_infer(
        retry_model_input,
        retry_model_output,
        &model_workspace,
        0,
        0
    );
    if (status != 0) {
        return status;
    }
    retry_result = dscnn_result(retry_model_output);
    XTime_GetTime(&inference_end);
    jtag_retry_inference_us =
        elapsed_microseconds(inference_start, inference_end);
    jtag_retry_second_class_id = retry_result.class_id;
    jtag_retry_second_confidence_q8 = retry_result.confidence_q8;

    total_us =
        (uint64_t)jtag_retry_first_inference_us +
        (uint64_t)jtag_retry_feature_us +
        (uint64_t)jtag_retry_inference_us;
    jtag_retry_total_us =
        (total_us > UINT32_MAX) ? UINT32_MAX : (uint32_t)total_us;

    /*
     * The old path promoted every PCM retry whose winner was knock, even at
     * very low confidence.  That bypassed both the normal class threshold and
     * the activity gate, which is why steady room noise could become a blue
     * knock alarm.  Apply the same calibrated threshold at this entry point.
     */
    if ((retry_result.class_id == 2U) &&
        (retry_result.confidence_q8 >= MODEL_ACCEPT_KNOCK_Q8)) {
        prediction->class_id = retry_result.class_id;
        prediction->confidence_q8 = retry_result.confidence_q8;
        jtag_model_class_id = retry_result.class_id;
        jtag_model_confidence_q8 = retry_result.confidence_q8;
        jtag_retry_knock_count++;
        for (index = 0U; index < ALARM_CLASS_COUNT; ++index) {
            jtag_model_logits[index] = retry_model_output[index];
        }
    }

    xil_printf(
        "RETRY,first=%u,second=%u,final=%u,first_us=%u," 
        "feature_us=%u,retry_us=%u,total_us=%u\r\n",
        (unsigned int)jtag_retry_first_class_id,
        (unsigned int)jtag_retry_second_class_id,
        (unsigned int)prediction->class_id,
        (unsigned int)jtag_retry_first_inference_us,
        (unsigned int)jtag_retry_feature_us,
        (unsigned int)jtag_retry_inference_us,
        (unsigned int)jtag_retry_total_us
    );
    Xil_DCacheFlush();
    return 0;
}

static uint8_t model_acceptance_threshold(uint8_t class_id)
{
    switch (class_id) {
    case 2U:
        return MODEL_ACCEPT_KNOCK_Q8;
    case 6U:
        return 255U;
    case 4U:
        return MODEL_ACCEPT_EMERGENCY_Q8;
    case 3U:
    case 7U:
        return MODEL_ACCEPT_ORDINARY_Q8;
    case 5U:
        return MODEL_ACCEPT_BABY_CRY_Q8;
    default:
        return 0U;
    }
}

static void reject_uncertain_prediction(PredictionResult *prediction)
{
    uint8_t threshold;

    if ((prediction == 0) || (prediction->class_id >= ALARM_CLASS_COUNT)) {
        return;
    }

    jtag_model_raw_class_id = prediction->class_id;
    jtag_model_raw_confidence_q8 = prediction->confidence_q8;

    /*
     * Glass-break is intentionally removed from the product demonstration.
     * Preserve the model's 8-output ABI, but expose class 6 only as unknown
     * and never allow it to drive the HMI, WS2812, or vibration motor.
     */
    if (prediction->class_id == 6U) {
        prediction->class_id = 1U;
        jtag_model_class_id = 1U;
        jtag_model_confidence_q8 = prediction->confidence_q8;
        jtag_model_rejection_count++;
        Xil_DCacheFlush();
        return;
    }

    threshold = model_acceptance_threshold(prediction->class_id);

    if ((threshold != 0U) && (prediction->confidence_q8 < threshold)) {
        prediction->class_id = 1U;
        jtag_model_class_id = 1U;
        jtag_model_confidence_q8 = prediction->confidence_q8;
        jtag_model_rejection_count++;

        xil_printf(
            "MODEL_REJECT,raw_class=%u,confidence_q8=%u,threshold=%u\r\n",
            (unsigned int)jtag_model_raw_class_id,
            (unsigned int)jtag_model_raw_confidence_q8,
            (unsigned int)threshold
        );
    }
}

static void run_live_inference(uint16_t first_sequence)
{
    PredictionResult prediction;
    uint16_t sequence;
    uint8_t direction_activity;
    uint8_t direction_trigger_class;
    uint8_t paired_pcm_ready;
    int acknowledge_requested;
    int status;

    (void)first_sequence;

    alarm_enter_idle();
    jtag_model_status = JTAG_STATUS_WAIT;
    jtag_model_inference_count = 0U;
    live_timestamp_ms = 0U;
    Xil_DCacheFlush();

    xil_printf("STAGE29_SYNCHRONIZED_RETRY_BEGIN\r\n");

    while (1) {
        paired_pcm_ready = 0U;
        status = pair_capture_begin();
        if (status != 0) {
            jtag_model_status = JTAG_STATUS_ERROR;
            Xil_DCacheFlush();
            xil_printf("MODEL_ERROR,pair_capture_begin=%d\r\n", status);
            pair_capture_end();
            leave_raw_mode();
            usleep(50000U);
            jtag_model_status = JTAG_STATUS_READY;
            Xil_DCacheFlush();
            continue;
        }
        pair_capture_read_matrix();
        sequence = (uint16_t)jtag_matrix_sequence;

        live_timestamp_ms += 1000U;

        status = classify_current_matrix(
            sequence,
            live_timestamp_ms,
            &prediction
        );
        if (status != 0) {
            pair_capture_end();
            jtag_model_status = JTAG_STATUS_ERROR;
            Xil_DCacheFlush();
            xil_printf("MODEL_ERROR,status=%d\r\n", status);
            return;
        }

        status = apply_low_level_event_retry(&prediction);
        if (status != 0) {
            pair_capture_end();
            jtag_model_status = JTAG_STATUS_ERROR;
            Xil_DCacheFlush();
            xil_printf("MODEL_ERROR,gain_retry=%d\r\n", status);
            return;
        }

        if ((prediction.class_id == 1U) ||
            (prediction.class_id == 2U) ||
            (jtag_model_raw_class_id == 2U)) {
            pair_capture_read_pcm();
            paired_pcm_ready = 1U;
        }
        status = apply_unknown_knock_retry(&prediction);
        if (status != 0) {
            pair_capture_end();
            jtag_model_status = JTAG_STATUS_ERROR;
            Xil_DCacheFlush();
            xil_printf("MODEL_ERROR,retry=%d\r\n", status);
            return;
        }

        reject_uncertain_prediction(&prediction);

        if ((prediction.class_id == 2U) &&
            ((paired_pcm_ready == 0U) || !knock_pcm_is_transient())) {
            prediction.class_id = 1U;
            jtag_model_class_id = 1U;
            jtag_model_confidence_q8 = prediction.confidence_q8;
            jtag_model_rejection_count++;
            jtag_knock_transient_rejection_count++;
            xil_printf(
                "KNOCK_TRANSIENT_REJECT,confidence_q8=%u,ratio_q8=%u,"
                "active_frames=%u\r\n",
                (unsigned int)prediction.confidence_q8,
                (unsigned int)jtag_knock_pcm_peak_to_mean_q8,
                (unsigned int)jtag_knock_pcm_active_frames
            );
        }

        /*
         * Drain display RX before a new prediction is allowed to confirm an
         * alarm.  This prevents a stale release packet from page start-up from
         * cancelling the alarm in the same loop that created it.  A real
         * acknowledgement is accepted only after the confirmed output has
         * remained visible for at least one logical second.
         */
        acknowledge_requested = display_poll_acknowledge();
        if ((acknowledge_requested != 0) &&
            (jtag_alarm_state == ALARM_STATE_CONFIRMED) &&
            !time_before(live_timestamp_ms,
                         alarm_confirmed_at_ms + ALARM_ACK_MIN_HOLD_MS)) {
            alarm_cooldown_until_ms =
                live_timestamp_ms + ALARM_ACK_COOLDOWN_MS;
            pair_capture_end();
            alarm_enter_idle();
            display_clear_hold();
            jtag_direction_valid = 0U;
            jtag_direction_status = JTAG_STATUS_WAIT;
            direction_stable_valid = 0U;
            direction_event_class_id = 0U;
            display_publish_prediction(0U, 0U, live_timestamp_ms);
            xil_printf("DISPLAY_ACKNOWLEDGE,time=%u\r\n",
                       (unsigned int)live_timestamp_ms);
            Xil_DCacheFlush();
            continue;
        }

        /*
         * A confirmed alarm deliberately suppresses new direction captures
         * because the vibration motor contaminates all four microphones.
         * Keep the last pre-motor bearing visible for the whole confirmed
         * alarm; otherwise its old five-second timeout turns the HMI back to
         * "unknown" even though the estimate was valid.  Once the alarm is
         * cleared, the normal age rule removes the stale bearing.
         */
        if ((jtag_direction_valid != 0U) &&
            (jtag_alarm_state != ALARM_STATE_CONFIRMED) &&
            !time_before(live_timestamp_ms,
                         direction_last_valid_ms +
                         DIRECTION_DISPLAY_HOLD_MS)) {
            jtag_direction_valid = 0U;
            jtag_direction_status = JTAG_STATUS_WAIT;
            direction_stable_valid = 0U;
            direction_event_class_id = 0U;
        }

        /*
         * Localization is independent of semantic acceptance.  Strong audio
         * starts a provisional direction event even if the DS-CNN still says
         * silence/unknown; a later accepted class adopts the same bearing.
         */
        direction_activity =
            ((jtag_model_activity_peak_frame_mean_q8_8 >=
              DIRECTION_ACTIVITY_PEAK_Q8_8) ||
             (jtag_model_activity_frame_mean_range_q8_8 >=
              DIRECTION_ACTIVITY_RANGE_Q8_8)) ? 1U : 0U;

        direction_trigger_class = 0U;
        if ((direction_activity != 0U) &&
            (prediction.class_id >= 2U) &&
            (prediction.class_id < ALARM_CLASS_COUNT)) {
            direction_trigger_class = prediction.class_id;
        } else if ((direction_activity != 0U) &&
                   (jtag_model_raw_class_id >= 2U) &&
                   (jtag_model_raw_class_id != 6U) &&
                   (jtag_model_raw_class_id < ALARM_CLASS_COUNT)) {
            direction_trigger_class =
                (uint8_t)jtag_model_raw_class_id;
        } else if (direction_activity != 0U) {
            direction_trigger_class = DIRECTION_PROVISIONAL_CLASS_ID;
        }

        if ((direction_trigger_class >= 2U) &&
            (jtag_alarm_state != ALARM_STATE_CONFIRMED) &&
            !time_before(live_timestamp_ms, alarm_cooldown_until_ms)) {
            if ((direction_event_class_id ==
                 DIRECTION_PROVISIONAL_CLASS_ID) &&
                (direction_trigger_class < ALARM_CLASS_COUNT)) {
                /* Adopt a provisional acoustic bearing without recapturing. */
                direction_event_class_id = direction_trigger_class;
            } else if ((direction_event_class_id == 0U) ||
                       ((direction_trigger_class < ALARM_CLASS_COUNT) &&
                        (direction_event_class_id !=
                         direction_trigger_class))) {
            /*
             * A direction belongs to one acoustic event only.  Do not seed a
             * new event with the previous event's stable sector: doing so
             * made the display show the old bearing until a second capture
             * confirmed the replacement.  The first valid estimate of this
             * event is now accepted immediately; later refreshes within the
             * same event still use the existing two-sample sector debounce.
             */
            direction_event_class_id = direction_trigger_class;
            direction_stable_valid = 0U;
            direction_candidate_sector = 0U;
            direction_candidate_count = 0U;
            direction_stable_angle_mdeg = 0U;
            /* A genuinely new event must not inherit the refresh throttle. */
            direction_last_attempt_ms = 0U;
            jtag_direction_valid = 0U;
            jtag_direction_status = JTAG_STATUS_WAIT;
            Xil_DCacheFlush();
            }
        }

        /*
         * Stage 32 full-system ordering: estimate direction before confirming
         * an alarm.  alarm_confirm() starts the vibration motor, whose strong
         * structure-borne noise otherwise pollutes the four microphones and
         * makes the residual test reject an otherwise valid bearing.
         *
         * Do not refresh direction after an alarm is already confirmed: at
         * that point the motor may be running.  The first accepted event still
         * drives direction, display, WS2812 and vibration in one transaction;
         * only the physical alarm output is delayed until localization ends.
         */
        /* Keep the previous display while localization runs; do not flash an
         * artificial "unknown" between a sound and its validated bearing. */

        if ((direction_trigger_class >= 2U) &&
            (jtag_alarm_state != ALARM_STATE_CONFIRMED) &&
            !time_before(live_timestamp_ms, alarm_cooldown_until_ms)) {
            update_direction_for_event(live_timestamp_ms);
        }
        pair_capture_end();

        /*
         * Localization is the longest call in this loop.  Reconstruct the
         * accepted prediction from the JTAG-visible latch before dispatching
         * the alarm so the output decision cannot depend on a stale/corrupted
         * stack copy after the direction workspace has been exercised.
         */
        prediction.timestamp_ms = live_timestamp_ms;
        prediction.valid = 1U;
        prediction.class_id = (uint8_t)jtag_model_class_id;
        prediction.confidence_q8 = (uint8_t)jtag_model_confidence_q8;

        alarm_handle_prediction(&prediction);
        alarm_check_timeout(live_timestamp_ms);
        if (jtag_alarm_state == ALARM_STATE_CONFIRMED) {
            display_publish_prediction(
                (uint8_t)jtag_alarm_class_id,
                (uint8_t)jtag_alarm_confidence_q8,
                live_timestamp_ms
            );
        } else {
            /* Candidates remain visually blank until the alarm is final. */
            display_publish_prediction(0U, 0U, live_timestamp_ms);
        }
        Xil_DCacheFlush();
    }
}

int main(void)
{
    /* AXI GPIO channel 1 is an output; channel 2 is an input. */
    Xil_Out32(MATRIX_GPIO_BASE + GPIO_TRI_OFFSET, 0x00000000U);
    Xil_Out32(MATRIX_GPIO_BASE + GPIO_TRI2_OFFSET, 0xFFFFFFFFU);

    jtag_capture_status = JTAG_STATUS_WAIT;
    jtag_raw_status = JTAG_STATUS_WAIT;
    jtag_raw_signature = 0U;
    jtag_raw_sequence = 0U;
    jtag_raw_count = 0U;
    jtag_raw_batch_status = JTAG_STATUS_WAIT;
    jtag_raw_batch_count = 0U;
    jtag_matrix_sequence = 0U;
    jtag_matrix_count = 0U;
    jtag_model_status = JTAG_STATUS_WAIT;
    jtag_model_sequence = 0U;
    jtag_model_inference_count = 0U;
    jtag_model_class_id = 0U;
    jtag_model_confidence_q8 = 0U;
    jtag_model_last_inference_us = 0U;
    jtag_model_max_inference_us = 0U;
    jtag_model_min_inference_us = 0xFFFFFFFFU;
    jtag_model_activity_peak_frame_mean_q8_8 = 0U;
    jtag_model_activity_frame_mean_range_q8_8 = 0U;
    jtag_model_raw_class_id = 0U;
    jtag_model_raw_confidence_q8 = 0U;
    jtag_model_rejection_count = 0U;
    jtag_retry_trigger_count = 0U;
    jtag_retry_knock_count = 0U;
    jtag_retry_first_class_id = 0U;
    jtag_retry_second_class_id = UINT32_MAX;
    jtag_retry_second_confidence_q8 = 0U;
    jtag_retry_first_inference_us = 0U;
    jtag_retry_feature_us = 0U;
    jtag_retry_inference_us = 0U;
    jtag_retry_total_us = 0U;
    jtag_direction_status = JTAG_STATUS_WAIT;
    jtag_direction_valid = 0U;
    jtag_direction_sector = 0U;
    jtag_direction_angle_mdeg = 0U;
    jtag_direction_inference_us = 0U;
    jtag_direction_capture_phase = 0U;
    alarm_cooldown_until_ms = 0U;
    display_ready = 0U;
    display_clear_hold();
    direction_last_attempt_ms = 0U;
    direction_last_valid_ms = 0U;
    direction_stable_valid = 0U;
    direction_stable_sector = 0U;
    direction_candidate_sector = 0U;
    direction_candidate_count = 0U;
    direction_stable_angle_mdeg = 0U;
    direction_event_class_id = 0U;
    Xil_DCacheFlush();

    if (display_initialize() == 0) {
        xil_printf("STAGE29_TJC_DISPLAY_STATUS=Ready\r\n");
    } else {
        xil_printf("STAGE29_TJC_DISPLAY_STATUS=Unavailable\r\n");
    }

    xil_printf("\r\nMIC_STAGE29_RETRY_TJC_READY\r\n");
    xil_printf("GPIO_BASE=0x%08x\r\n",
               (unsigned int)MATRIX_GPIO_BASE);
    xil_printf("Starting synchronized inference, conditional knock retry, "
               "alarm output, and TJC display.\r\n");

    run_live_inference(0U);

    while (1) {
    }

    return 0;
}
