/* ============================================================================
 * FlugOS — ESP-Mosaico Multi-Function Interaction Module (Board ID 0x16) Driver
 * ============================================================================ */

#include "flugos_mosaico.h"

bool flugos_mosaico_probe_slot(
    flugos_mosaico_slot_t slot,
    uint8_t eeprom_board_id,
    flugos_mosaico_pins_t *out_pins
) {
    if (out_pins == NULL || eeprom_board_id != FLUGOS_MOSAICO_BOARD_ID_INTERACTION) {
        return false;
    }
    if (slot == FLUGOS_MOSAICO_SLOT_LEFT_H2) {
        out_pins->slot            = FLUGOS_MOSAICO_SLOT_LEFT_H2;
        out_pins->eeprom_i2c_addr = FLUGOS_MOSAICO_EEPROM_ADDR_LEFT_H2; /* 0x50 */
        out_pins->addr_sel_gpio   = 14U;
        out_pins->addr_sel_level  = 0U;
        out_pins->ldr_adc_gpio    = 53U; /* GL5506 LDR */
        out_pins->pir_gpio        = 4U;  /* AS312 PIR */
        out_pins->ir_tx_gpio      = 48U; /* AO3400A IR LED */
        out_pins->ws2812_gpio     = 15U; /* 6x WS2812 RGB */
        out_pins->key_left_gpio   = 13U; /* Touch_L / Key_L */
        out_pins->key_right_gpio  = 12U; /* Touch_R / Key_R */
        return true;
    }
    if (slot == FLUGOS_MOSAICO_SLOT_RIGHT_H1) {
        out_pins->slot            = FLUGOS_MOSAICO_SLOT_RIGHT_H1;
        out_pins->eeprom_i2c_addr = FLUGOS_MOSAICO_EEPROM_ADDR_RIGHT_H1; /* 0x51 */
        out_pins->addr_sel_gpio   = 39U;
        out_pins->addr_sel_level  = 1U;
        out_pins->ldr_adc_gpio    = 46U; /* GL5506 LDR (rotated 180 deg) */
        out_pins->pir_gpio        = 5U;  /* AS312 PIR */
        out_pins->ir_tx_gpio      = 47U; /* AO3400A IR LED */
        out_pins->ws2812_gpio     = 38U; /* 6x WS2812 RGB */
        out_pins->key_left_gpio   = 11U; /* Touch_L / Key_L */
        out_pins->key_right_gpio  = 10U; /* Touch_R / Key_R */
        return true;
    }
    return false;
}

void flugos_quiescence_gate_init(
    flugos_quiescence_gate_t *gate,
    uint16_t quiet_thresh_q15,
    uint16_t wake_thresh_q15,
    uint16_t hold_ticks_required
) {
    if (gate == NULL) {
        return;
    }
    gate->flux_ema_q15        = wake_thresh_q15;
    gate->quiet_thresh_q15    = quiet_thresh_q15;
    gate->wake_thresh_q15     = (wake_thresh_q15 > quiet_thresh_q15)
                                    ? wake_thresh_q15
                                    : (uint16_t)(quiet_thresh_q15 + 1024U);
    gate->hold_ticks_required = (hold_ticks_required > 0U) ? hold_ticks_required : 1U;
    gate->quiet_ticks_accum   = 0U;
    gate->in_ultradreamstate  = false;
}

bool flugos_quiescence_gate_step(
    flugos_quiescence_gate_t *gate,
    uint16_t ldr_permille,
    bool pir_motion,
    bool key_left_pressed,
    bool key_right_pressed,
    uint16_t audio_rms_q15
) {
    if (gate == NULL) {
        return false;
    }
    uint32_t clamped_ldr = (ldr_permille > 1000U) ? 1000U : (uint32_t)ldr_permille;
    uint32_t light_q15   = (clamped_ldr * 32767U) / 1000U;
    uint32_t motion_q15  = (pir_motion || key_left_pressed || key_right_pressed) ? 32767U : 0U;

    /* Weighted external input flux: 50% audio + 25% motion/touch + 25% ambient light */
    uint32_t inst_flux = ((uint32_t)audio_rms_q15 * 2U + motion_q15 + light_q15) >> 2;
    if (inst_flux > 32767U) {
        inst_flux = 32767U;
    }

    /* Exponential moving average: E(t) = (3 * E(t-1) + inst_flux) / 4 */
    uint32_t next_ema = (((uint32_t)gate->flux_ema_q15 * 3U) + inst_flux) >> 2;
    gate->flux_ema_q15 = (uint16_t)next_ema;

    if (!gate->in_ultradreamstate) {
        if (gate->flux_ema_q15 < gate->quiet_thresh_q15) {
            if (gate->quiet_ticks_accum < 0xFFFFU) {
                gate->quiet_ticks_accum++;
            }
            if (gate->quiet_ticks_accum >= gate->hold_ticks_required) {
                gate->in_ultradreamstate = true;
            }
        } else {
            gate->quiet_ticks_accum = 0U;
        }
    } else {
        if (gate->flux_ema_q15 > gate->wake_thresh_q15 || pir_motion || key_left_pressed || key_right_pressed) {
            gate->in_ultradreamstate = false;
            gate->quiet_ticks_accum  = 0U;
        }
    }
    return gate->in_ultradreamstate;
}

void flugos_mosaico_encode_ws2812_trits(
    const int8_t trits[FLUGOS_MOSAICO_WS2812_COUNT],
    flugos_ws2812_grb_t out_leds[FLUGOS_MOSAICO_WS2812_COUNT]
) {
    for (size_t i = 0; i < FLUGOS_MOSAICO_WS2812_COUNT; ++i) {
        if (trits[i] > 0) {
            /* +1: Coherent Cyan-Mint (#00F5D4) */
            out_leds[i].g = 0xF5U;
            out_leds[i].r = 0x00U;
            out_leds[i].b = 0xD4U;
        } else if (trits[i] < 0) {
            /* -1: Phase-Conjugate Magenta (#FF2A85) */
            out_leds[i].g = 0x2AU;
            out_leds[i].r = 0xFFU;
            out_leds[i].b = 0x85U;
        } else {
            /*  0: Quiescent Deep Indigo (#121824) */
            out_leds[i].g = 0x18U;
            out_leds[i].r = 0x12U;
            out_leds[i].b = 0x24U;
        }
    }
}

uint32_t flugos_mosaico_encode_nec_ir(uint8_t addr, uint8_t cmd) {
    uint8_t n_addr = (uint8_t)(~addr);
    uint8_t n_cmd  = (uint8_t)(~cmd);
    return ((uint32_t)addr) |
           ((uint32_t)n_addr << 8) |
           ((uint32_t)cmd << 16) |
           ((uint32_t)n_cmd << 24);
}
