#ifndef STAGE28_TJC_HMI_H
#define STAGE28_TJC_HMI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TJC_CLASS_COUNT          9U
#define TJC_CLASS_RECOGNIZING    8U
#define TJC_DIRECTION_UNKNOWN   8U
#define TJC_ALARM_ACTION_COUNT  4U

typedef int (*TjcHmiWrite)(const uint8_t *data,
                           size_t length,
                           void *context);

typedef struct {
    uint8_t class_id;
    uint8_t confidence_q8;
    uint8_t direction_valid;
    uint8_t direction_sector;
    uint8_t alarm_action;
    uint8_t motor_enabled;
} TjcHmiState;

typedef struct {
    TjcHmiWrite write;
    void *write_context;
    TjcHmiState last_state;
    uint8_t has_last_state;
    uint8_t acknowledge_rx_state;
} TjcHmi;

/*
 * The display page contains hidden numeric variables:
 *   va0 class_id          0..7 model classes, 8 means recognizing
 *   va1 confidence        0..100 percent
 *   va2 direction         0..7, 8 means unknown
 *   va3 alarm_action      0 idle, 1 blue, 2 yellow, 3 red
 *   va4 motor_enabled     0 off, 1 enabled
 */
void tjc_hmi_init(TjcHmi *hmi,
                  TjcHmiWrite write_function,
                  void *write_context);

/* Select page 0 and send the complete initial state. */
int tjc_hmi_begin(TjcHmi *hmi, const TjcHmiState *state);

/* Send changed variables only, unless force_refresh is non-zero. */
int tjc_hmi_publish(TjcHmi *hmi,
                    const TjcHmiState *state,
                    int force_refresh);

/*
 * Feed bytes received from the display. Returns 1 exactly once after the
 * b0 release-event packet 5A A5 01 01 is received; otherwise returns 0.
 */
int tjc_hmi_feed_rx(TjcHmi *hmi, uint8_t byte);

uint8_t tjc_hmi_confidence_percent(uint8_t confidence_q8);

#ifdef __cplusplus
}
#endif

#endif
