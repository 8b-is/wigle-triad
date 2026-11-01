/* ============================================================================
 * FlugOS — ESP-Mosaico Multi-Function Interaction Module (Board ID 0x16) Driver
 * ============================================================================
 * Supports automatic I2C AT24C02 EEPROM slot discovery (`0x50` Left Slot H2 /
 * `0x51` Right Slot H1 rotated 180 deg), GL5506 photoresistor (LDR), AS312 PIR
 * motion sensor, AO3400A 38 kHz NEC infrared transmitter, 6x WS2812 RGB LEDs,
 * dual mechanical/capacitive-touch pads, and the Hysteresis-Guarded Entropy's
 * Edge Quiescence Gate (\Gamma(t) \in {0, 1}) bridging Waking Mode (Yamada) and
 * UltraDreamState (Tayama).
 * ============================================================================ */

#ifndef FLUGOS_MOSAICO_H
#define FLUGOS_MOSAICO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FLUGOS_MOSAICO_BOARD_ID_INTERACTION 0x16U
#define FLUGOS_MOSAICO_I2C_SDA_GPIO         0U
#define FLUGOS_MOSAICO_I2C_SCL_GPIO         1U

#define FLUGOS_MOSAICO_EEPROM_ADDR_LEFT_H2  0x50U
#define FLUGOS_MOSAICO_EEPROM_ADDR_RIGHT_H1 0x51U

#define FLUGOS_MOSAICO_WS2812_COUNT         6U

typedef enum {
    FLUGOS_MOSAICO_SLOT_LEFT_H2  = 0,
    FLUGOS_MOSAICO_SLOT_RIGHT_H1 = 1
} flugos_mosaico_slot_t;

typedef struct {
    flugos_mosaico_slot_t slot;
    uint8_t               eeprom_i2c_addr;
    uint8_t               addr_sel_gpio;
    uint8_t               addr_sel_level;
    uint8_t               ldr_adc_gpio;
    uint8_t               pir_gpio;
    uint8_t               ir_tx_gpio;
    uint8_t               ws2812_gpio;
    uint8_t               key_left_gpio;
    uint8_t               key_right_gpio;
} flugos_mosaico_pins_t;

typedef struct {
    uint16_t flux_ema_q15;
    uint16_t quiet_thresh_q15;
    uint16_t wake_thresh_q15;
    uint16_t hold_ticks_required;
    uint16_t quiet_ticks_accum;
    bool     in_ultradreamstate; /* false = Yamada (Waking), true = Tayama (UltraDreamState) */
} flugos_quiescence_gate_t;

typedef struct {
    uint8_t g;
    uint8_t r;
    uint8_t b;
} flugos_ws2812_grb_t;

/**
 * Returns the slot-specific 2x10P GPIO mapping for either Left Slot (H2, 0x50)
 * or 180-degree rotated Right Slot (H1, 0x51) when EEPROM reports board_id == 0x16.
 */
bool flugos_mosaico_probe_slot(
    flugos_mosaico_slot_t slot,
    uint8_t eeprom_board_id,
    flugos_mosaico_pins_t *out_pins
);

/**
 * Initializes the Hysteresis-Guarded Entropy's Edge Quiescence Gate (\Gamma(t)).
 * Requires `quiet_thresh_q15 < wake_thresh_q15` and `hold_ticks_required >= 1`.
 */
void flugos_quiescence_gate_init(
    flugos_quiescence_gate_t *gate,
    uint16_t quiet_thresh_q15,
    uint16_t wake_thresh_q15,
    uint16_t hold_ticks_required
);

/**
 * Evaluates one tick of the Quiescence Gate from the ESP-Mosaico Interaction Module
 * sensors (GL5506 ambient light 0..1000 permille, AS312 PIR presence, dual touch/keys,
 * and I2S audio RMS energy 0..32767). Returns true when \Gamma(t) == 1 (UltraDreamState).
 */
bool flugos_quiescence_gate_step(
    flugos_quiescence_gate_t *gate,
    uint16_t ldr_permille,
    bool pir_motion,
    bool key_left_pressed,
    bool key_right_pressed,
    uint16_t audio_rms_q15
);

/**
 * Maps 6 balanced-ternary trits `trits[0..5]` in `{-1, 0, +1}` onto the 6 onboard
 * WS2812 RGB LEDs (4 top status LEDs + 2 key backlight LEDs) in 24-bit GRB order.
 */
void flugos_mosaico_encode_ws2812_trits(
    const int8_t trits[FLUGOS_MOSAICO_WS2812_COUNT],
    flugos_ws2812_grb_t out_leds[FLUGOS_MOSAICO_WS2812_COUNT]
);

/**
 * Encodes a 16-bit address and 8-bit command into a standard 32-bit NEC infrared
 * frame (with bitwise inverse verification bytes) for the AO3400A IR driver.
 */
uint32_t flugos_mosaico_encode_nec_ir(uint8_t addr, uint8_t cmd);

#ifdef __cplusplus
}
#endif

#endif /* FLUGOS_MOSAICO_H */
