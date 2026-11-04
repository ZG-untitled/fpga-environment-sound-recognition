#include "tjc_hmi.h"

#include <stdio.h>
#include <string.h>

#define TJC_COMMAND_BUFFER_SIZE 48U

static int tjc_write_all(TjcHmi *hmi,
                         const uint8_t *data,
                         size_t length)
{
    if ((hmi == NULL) || (hmi->write == NULL) ||
        ((data == NULL) && (length != 0U))) {
        return -1;
    }

    return hmi->write(data, length, hmi->write_context);
}

static int tjc_send_command(TjcHmi *hmi, const char *command)
{
    static const uint8_t command_end[3] = {0xFFU, 0xFFU, 0xFFU};
    size_t length;

    if (command == NULL) {
        return -1;
    }

    length = strlen(command);
    if (tjc_write_all(hmi, (const uint8_t *)command, length) != 0) {
        return -1;
    }

    return tjc_write_all(hmi, command_end, sizeof(command_end));
}

static int tjc_send_value(TjcHmi *hmi,
                          const char *variable_name,
                          unsigned int value)
{
    char command[TJC_COMMAND_BUFFER_SIZE];
    int count;

    count = snprintf(
        command,
        sizeof(command),
        "%s.val=%u",
        variable_name,
        value
    );

    if ((count < 0) || ((size_t)count >= sizeof(command))) {
        return -1;
    }

    return tjc_send_command(hmi, command);
}

static int tjc_send_text(TjcHmi *hmi,
                         const char *component_name,
                         const char *text)
{
    char command[TJC_COMMAND_BUFFER_SIZE];
    int count;

    count = snprintf(
        command,
        sizeof(command),
        "%s.txt=\"%s\"",
        component_name,
        text
    );

    if ((count < 0) || ((size_t)count >= sizeof(command))) {
        return -1;
    }

    return tjc_send_command(hmi, command);
}

static int tjc_send_attribute(TjcHmi *hmi,
                              const char *attribute_name,
                              unsigned int value)
{
    char command[TJC_COMMAND_BUFFER_SIZE];
    int count;

    count = snprintf(command, sizeof(command), "%s=%u",
                     attribute_name, value);
    if ((count < 0) || ((size_t)count >= sizeof(command))) {
        return -1;
    }
    return tjc_send_command(hmi, command);
}

static const char *const tjc_class_text[TJC_CLASS_COUNT] = {
    "\xB0\xB2\xBE\xB2",                         /* 安静 */
    "\xCE\xB4\xD6\xAA",                         /* 未知 */
    "\xC7\xC3\xC3\xC5",                         /* 敲门 */
    "\xC4\xD6\xD6\xD3",                         /* 闹钟 */
    "\xBE\xAF\xB1\xA8",                         /* 警报 */
    "\xD3\xA4\xB6\xF9\xBF\xDE",               /* 婴儿哭 */
    "\xB2\xA3\xC1\xA7\xC6\xC6\xCB\xE9",     /* 玻璃破碎 */
    "\xCB\xAE\xB7\xD0\xCC\xDA",               /* 水沸腾 */
    "\xCA\xB6\xB1\xF0\xD6\xD0"                /* 识别中 */
};

static const unsigned int tjc_class_color[TJC_CLASS_COUNT] = {
    2016U, 33840U, 65504U, 64800U,
    63488U, 63519U, 63488U, 2047U, 33840U
};

static const char *const tjc_direction_text[TJC_DIRECTION_UNKNOWN + 1U] = {
    "\xC7\xB0\xB7\xBD",                         /* 前方 */
    "\xD3\xD2\xC7\xB0",                         /* 右前 */
    "\xD3\xD2\xB2\xE0",                         /* 右侧 */
    "\xD3\xD2\xBA\xF3",                         /* 右后 */
    "\xBA\xF3\xB7\xBD",                         /* 后方 */
    "\xD7\xF3\xBA\xF3",                         /* 左后 */
    "\xD7\xF3\xB2\xE0",                         /* 左侧 */
    "\xD7\xF3\xC7\xB0",                         /* 左前 */
    "\xCE\xB4\xD6\xAA"                          /* 未知 */
};

static const char *const tjc_led_text[TJC_ALARM_ACTION_COUNT] = {
    "\xC2\xCC\xC9\xAB",                         /* 绿色 */
    "\xC0\xB6\xC9\xAB",                         /* 蓝色 */
    "\xBB\xC6\xC9\xAB",                         /* 黄色 */
    "\xBA\xEC\xC9\xAB"                          /* 红色 */
};

static const char *const tjc_motor_text[TJC_ALARM_ACTION_COUNT] = {
    "\xB9\xD8\xB1\xD5",                         /* 关闭 */
    "\xB5\xA5\xB4\xCE",                         /* 单次 */
    "\xCB\xAB\xB4\xCE",                         /* 双次 */
    "\xB3\xD6\xD0\xF8"                          /* 持续 */
};

static TjcHmiState tjc_sanitize_state(const TjcHmiState *state)
{
    TjcHmiState clean = *state;

    if (clean.class_id >= TJC_CLASS_COUNT) {
        clean.class_id = 1U; /* unknown */
    }

    if ((clean.direction_valid == 0U) ||
        (clean.direction_sector >= TJC_DIRECTION_UNKNOWN)) {
        clean.direction_valid = 0U;
        clean.direction_sector = TJC_DIRECTION_UNKNOWN;
    } else {
        clean.direction_valid = 1U;
    }

    if (clean.alarm_action >= TJC_ALARM_ACTION_COUNT) {
        clean.alarm_action = 0U;
    }

    clean.motor_enabled = (clean.motor_enabled != 0U) ? 1U : 0U;
    return clean;
}

uint8_t tjc_hmi_confidence_percent(uint8_t confidence_q8)
{
    return (uint8_t)(
        (((uint32_t)confidence_q8 * 100U) + 127U) / 255U
    );
}

void tjc_hmi_init(TjcHmi *hmi,
                  TjcHmiWrite write_function,
                  void *write_context)
{
    if (hmi == NULL) {
        return;
    }

    memset(hmi, 0, sizeof(*hmi));
    hmi->write = write_function;
    hmi->write_context = write_context;
}

int tjc_hmi_begin(TjcHmi *hmi, const TjcHmiState *state)
{
    if ((hmi == NULL) || (state == NULL)) {
        return -1;
    }

    /* Disable ordinary command-return packets; b0's printh packet remains. */
    if (tjc_send_command(hmi, "bkcmd=0") != 0) {
        return -1;
    }
    if (tjc_send_command(hmi, "page 0") != 0) {
        return -1;
    }

    hmi->has_last_state = 0U;
    return tjc_hmi_publish(hmi, state, 1);
}

int tjc_hmi_publish(TjcHmi *hmi,
                    const TjcHmiState *state,
                    int force_refresh)
{
    char confidence_text[8];
    TjcHmiState clean;
    uint8_t confidence_percent;
    uint8_t show_result;
    int send_all;

    if ((hmi == NULL) || (state == NULL) || (hmi->write == NULL)) {
        return -1;
    }

    clean = tjc_sanitize_state(state);
    confidence_percent =
        tjc_hmi_confidence_percent(clean.confidence_q8);
    /*
     * A candidate, silence, unknown, or disabled glass-break output is not a
     * product result.  Clear the value fields instead of showing an old or
     * provisional answer that looks like a recognition error.
     */
    show_result =
        ((clean.class_id >= 2U) &&
         (clean.class_id < TJC_CLASS_RECOGNIZING) &&
         (clean.class_id != 6U)) ? 1U : 0U;
    send_all = (force_refresh != 0) || (hmi->has_last_state == 0U);

    /*
     * Send direction and physical-output fields before revealing the class.
     * At 9600 baud this makes the visible answer appear only after the rest of
     * the same result is already on the page.
     */
    if (send_all ||
        (clean.direction_valid != hmi->last_state.direction_valid) ||
        (clean.direction_sector != hmi->last_state.direction_sector)) {
        if (tjc_send_value(hmi, "va2", clean.direction_sector) != 0) {
            return -1;
        }
        if (tjc_send_text(
                hmi,
                "t6",
                ((show_result != 0U) && (clean.direction_valid != 0U))
                    ? tjc_direction_text[clean.direction_sector]
                    : ""
            ) != 0) {
            return -1;
        }
    }

    if (send_all ||
        (clean.alarm_action != hmi->last_state.alarm_action)) {
        if (tjc_send_value(hmi, "va3", clean.alarm_action) != 0) {
            return -1;
        }
        if (tjc_send_text(hmi, "t8",
                          tjc_led_text[clean.alarm_action]) != 0) {
            return -1;
        }
        if (tjc_send_text(hmi, "t10",
                          tjc_motor_text[clean.alarm_action]) != 0) {
            return -1;
        }
    }

    if (send_all ||
        (clean.motor_enabled != hmi->last_state.motor_enabled)) {
        if (tjc_send_value(hmi, "va4", clean.motor_enabled) != 0) {
            return -1;
        }
    }

    if (send_all || (clean.class_id != hmi->last_state.class_id)) {
        if (tjc_send_value(hmi, "va0", clean.class_id) != 0) {
            return -1;
        }
        if (tjc_send_text(hmi, "t2",
                          (show_result != 0U)
                              ? tjc_class_text[clean.class_id]
                              : "") != 0) {
            return -1;
        }
        if (tjc_send_attribute(hmi, "t2.bco",
                               (show_result != 0U)
                                   ? tjc_class_color[clean.class_id]
                                   : tjc_class_color[TJC_CLASS_RECOGNIZING]) != 0) {
            return -1;
        }
    }

    if (send_all ||
        (clean.confidence_q8 != hmi->last_state.confidence_q8)) {
        if (tjc_send_value(hmi, "va1", confidence_percent) != 0) {
            return -1;
        }
        if (show_result != 0U) {
            (void)snprintf(confidence_text, sizeof(confidence_text),
                           "%u%%", (unsigned int)confidence_percent);
        } else {
            confidence_text[0] = '\0';
        }
        if (tjc_send_text(hmi, "t4", confidence_text) != 0) {
            return -1;
        }
    }

    hmi->last_state = clean;
    hmi->has_last_state = 1U;
    return 0;
}

int tjc_hmi_feed_rx(TjcHmi *hmi, uint8_t byte)
{
    static const uint8_t acknowledge_packet[4] = {
        0x5AU, 0xA5U, 0x01U, 0x01U
    };

    if (hmi == NULL) {
        return 0;
    }

    if (byte == acknowledge_packet[hmi->acknowledge_rx_state]) {
        hmi->acknowledge_rx_state++;
        if (hmi->acknowledge_rx_state == sizeof(acknowledge_packet)) {
            hmi->acknowledge_rx_state = 0U;
            return 1;
        }
    } else {
        hmi->acknowledge_rx_state =
            (byte == acknowledge_packet[0]) ? 1U : 0U;
    }

    return 0;
}
