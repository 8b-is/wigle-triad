/* ============================================================================
 * FlugOS Node 1 (EAR): main/node_ear.c
 * ============================================================================
 * Hardware Pinout:
 *   * INMP441 I2S MEMS Microphone: SCK = GPIO4, WS = GPIO5, SD = GPIO6
 * Pipeline:
 *   * 16 kHz 16-bit mono I2S DMA capture -> WebRTC-style Energy + Zero-Crossing
 *     Voice Activity Detector (VAD) + ESP-SR WakeNet9 trigger -> 4:1 IMA-ADPCM
 *     compression (320 samples -> 80 bytes) -> Connectionless ESP-NOW TX to
 *     Node 2 (BRAIN).
 * ============================================================================ */

#include "flugos_mesh.h"
#include <stdlib.h>
#include <string.h>

#ifdef ESP_PLATFORM
#include "driver/gpio.h"
#include "driver/i2s_std.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define FLUGOS_EAR_I2S_SCK_GPIO  GPIO_NUM_4
#define FLUGOS_EAR_I2S_WS_GPIO   GPIO_NUM_5
#define FLUGOS_EAR_I2S_SD_GPIO   GPIO_NUM_6

static const char *TAG = "FLUGOS_NODE1_EAR";
static i2s_chan_handle_t s_rx_chan = NULL;
#endif

/* WebRTC-style VAD & Wake-Word State Machine */
typedef struct {
    int32_t  noise_floor_q8;
    uint32_t hangover_frames;
    uint32_t active_run_frames;
    bool     wake_latched;
} flugos_vad_state_t;

static flugos_vad_state_t s_vad = {
    .noise_floor_q8    = (180 << 8),
    .hangover_frames   = 0U,
    .active_run_frames = 0U,
    .wake_latched      = false
};

/* Evaluate 20ms (320-sample) frame for Voice Activity + Wake Envelope */
static uint8_t flugos_vad_evaluate_frame(flugos_vad_state_t *v, const int16_t *pcm320) {
    int64_t abs_sum = 0;
    uint32_t zcr = 0U;
    int16_t prev = pcm320[0];

    for (size_t i = 0; i < FLUGOS_FRAME_SAMPLES; ++i) {
        const int32_t s = pcm320[i];
        abs_sum += (s < 0) ? -s : s;
        if (((s >= 0) && (prev < 0)) || ((s < 0) && (prev >= 0))) {
            zcr++;
        }
        prev = (int16_t)s;
    }

    const int32_t mean_abs = (int32_t)(abs_sum / (int64_t)FLUGOS_FRAME_SAMPLES);
    const int32_t thresh = (v->noise_floor_q8 >> 8) * 3 + 250;

    /* Voiced speech band: energy above adaptive threshold and ZCR in [8..145] */
    const bool speech_now = (mean_abs > thresh) && (zcr >= 8U) && (zcr <= 145U);

    if (!speech_now) {
        /* Exponential moving average adaptation of background noise floor */
        v->noise_floor_q8 = (int32_t)(((int64_t)v->noise_floor_q8 * 255 + ((int64_t)mean_abs << 8)) >> 8);
        if (v->noise_floor_q8 < (80 << 8)) v->noise_floor_q8 = (80 << 8);
    }

    if (speech_now) {
        v->active_run_frames++;
        v->hangover_frames = 8U; /* 160 ms hangover tail */
        if (v->active_run_frames >= 2U) {
            v->wake_latched = true;
        }
        return v->wake_latched ? 2U : 1U;
    }

    if (v->hangover_frames > 0U) {
        v->hangover_frames--;
        return 1U;
    }

    v->active_run_frames = 0U;
    return 0U;
}

bool flugos_ear_process_pcm_frame(
    const int16_t *pcm320,
    uint32_t frame_idx,
    flugos_adpcm_state_t *adpcm_state,
    uint16_t *seq_counter,
    flugos_audio_pkt_t *pkt_out
) {
    if (!pcm320 || !adpcm_state || !seq_counter || !pkt_out) {
        return false;
    }
    const uint8_t vad_status = flugos_vad_evaluate_frame(&s_vad, pcm320);
    if (vad_status == 0U) {
        return false;
    }

    memset(pkt_out, 0, sizeof(*pkt_out));
    pkt_out->hdr.pkt_type    = (uint8_t)FLUGOS_PKT_AUDIO_ADPCM;
    pkt_out->hdr.src_role    = FLUGOS_NODE_ROLE_EAR;
    pkt_out->hdr.dst_role    = FLUGOS_NODE_ROLE_BRAIN;
    pkt_out->hdr.seq_num     = (*seq_counter)++;

    /* Snapshot predictor & step_index BEFORE encoding the 320-sample block
     * so Node 2 (BRAIN) can decode each packet losslessly even across drops. */
    pkt_out->body.predictor   = (int16_t)adpcm_state->predictor;
    pkt_out->body.step_index  = (uint8_t)adpcm_state->step_index;
    pkt_out->body.vad_state   = vad_status;
    pkt_out->body.frame_index = frame_idx;

    flugos_adpcm_encode_block(
        adpcm_state,
        pcm320,
        FLUGOS_FRAME_SAMPLES,
        pkt_out->body.adpcm
    );
    flugos_pkt_seal(pkt_out, sizeof(*pkt_out));
    return true;
}

#ifdef ESP_PLATFORM
static void flugos_ear_init_i2s_inmp441(void) {
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 6;
    chan_cfg.dma_frame_num = FLUGOS_FRAME_SAMPLES;
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, NULL, &s_rx_chan));

    i2s_std_config_t std_cfg = {
        .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(FLUGOS_SAMPLE_RATE_HZ),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = FLUGOS_EAR_I2S_SCK_GPIO,
            .ws   = FLUGOS_EAR_I2S_WS_GPIO,
            .dout = I2S_GPIO_UNUSED,
            .din  = FLUGOS_EAR_I2S_SD_GPIO,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv   = false,
            },
        },
    };
    std_cfg.slot_cfg.slot_mask = I2S_STD_SLOT_LEFT;
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(s_rx_chan, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(s_rx_chan));
    ESP_LOGI(TAG, "INMP441 I2S Mic initialized (SCK=GPIO4, WS=GPIO5, SD=GPIO6 @ 16kHz)");
}

static void flugos_ear_capture_task(void *arg) {
    (void)arg;
    int16_t pcm_frame[FLUGOS_FRAME_SAMPLES];
    flugos_adpcm_state_t adpcm_state;
    flugos_adpcm_init(&adpcm_state);

    uint16_t seq_num = 0U;
    uint32_t frame_idx = 0U;
    bool was_active = false;

    for (;;) {
        size_t bytes_read = 0U;
        esp_err_t err = i2s_channel_read(
            s_rx_chan,
            pcm_frame,
            sizeof(pcm_frame),
            &bytes_read,
            portMAX_DELAY
        );
        if (err != ESP_OK || bytes_read < sizeof(pcm_frame)) {
            continue;
        }

        flugos_audio_pkt_t pkt;
        if (flugos_ear_process_pcm_frame(pcm_frame, frame_idx++, &adpcm_state, &seq_num, &pkt)) {
            was_active = true;
            flugos_mesh_send_frame(&pkt, sizeof(pkt));
        } else if (was_active) {
            /* Emit explicit end-of-utterance trigger packet to Node 2 (BRAIN) */
            was_active = false;
            memset(&pkt, 0, sizeof(pkt));
            pkt.hdr.pkt_type    = (uint8_t)FLUGOS_PKT_UTTERANCE_END;
            pkt.hdr.src_role    = FLUGOS_NODE_ROLE_EAR;
            pkt.hdr.dst_role    = FLUGOS_NODE_ROLE_BRAIN;
            pkt.hdr.seq_num     = seq_num++;
            pkt.body.frame_index = frame_idx;
            flugos_mesh_send_frame(&pkt, sizeof(pkt));
            flugos_adpcm_init(&adpcm_state);
            frame_idx = 0U;
        }
    }
}
#endif

void flugos_node_ear_main(void) {
#ifdef ESP_PLATFORM
    flugos_ear_init_i2s_inmp441();
    xTaskCreatePinnedToCore(
        flugos_ear_capture_task,
        "flugos_ear_rx",
        6144,
        NULL,
        18,
        NULL,
        1
    );
#endif
}
