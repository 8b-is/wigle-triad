/* ============================================================================
 * FlugOS Node 3 (MOUTH): main/node_mouth.c
 * ============================================================================
 * Hardware Pinout:
 *   * MAX98357A I2S Class-D Amplifier: BCLK = GPIO15, LRC = GPIO16, DIN = GPIO17
 * Pipeline:
 *   * Receives compact `flugos_text_pkt_t` from Node 2 (BRAIN) over ESP-NOW.
 *   * Executes the Trilingual (EN / JA / HU) 3-Formant Vocal-Tract Synthesizer
 *     (Rosenberg glottal pulse + 3 cascaded second-order digital biquad
 *     resonators for F1, F2, F3 + LFSR fricative noise generator) with Japanese
 *     mora-timed vowels (あ/い/う/え/お) and Hungarian vowel harmony / sibilants.
 *   * Streams synthesized 16-bit PCM directly out via I2S DMA (`i2s_channel_write`).
 * ============================================================================ */

#include "flugos_mesh.h"
#include <ctype.h>
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifdef ESP_PLATFORM
#include "driver/gpio.h"
#include "driver/i2s_std.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define FLUGOS_MOUTH_I2S_BCLK_GPIO GPIO_NUM_15
#define FLUGOS_MOUTH_I2S_LRC_GPIO  GPIO_NUM_16
#define FLUGOS_MOUTH_I2S_DIN_GPIO  GPIO_NUM_17

static const char *TAG = "FLUGOS_NODE3_MOUTH";
static i2s_chan_handle_t s_tx_chan = NULL;
#endif

typedef struct {
    char  ch;
    float f1, f2, f3;   /* Formant center frequencies (Hz) */
    float bw1, bw2;     /* Formant bandwidths (Hz) */
    float voiced_gain;  /* Glottal pitch excitation */
    float noise_gain;   /* Consonant aspiration / fricative noise */
    int   dur_ms;       /* Mora / phoneme duration (ms) */
} flugos_char_formant_t;

/* Trilingual Formant Table (English / Japanese Moraic / Hungarian Magyar) */
static const flugos_char_formant_t s_trilingual_formant_lut[] = {
    /* Japanese & Hungarian Pure Vowels (F1, F2, F3 Hz) */
    {'A', 750.0f, 1180.0f, 2550.0f,  80.0f, 100.0f, 1.0f, 0.01f, 25}, /* JA 'あ' / HU 'á' */
    {'E', 500.0f, 1900.0f, 2500.0f,  75.0f,  95.0f, 1.0f, 0.01f, 25}, /* JA 'え' / HU 'e/é' */
    {'I', 280.0f, 2250.0f, 2950.0f,  65.0f,  85.0f, 1.0f, 0.01f, 25}, /* JA 'い' / HU 'i/í' */
    {'O', 480.0f,  880.0f, 2450.0f,  75.0f,  95.0f, 1.0f, 0.01f, 25}, /* JA 'お' / HU 'o/ó' */
    {'U', 320.0f, 1100.0f, 2300.0f,  70.0f,  90.0f, 1.0f, 0.01f, 25}, /* JA 'う' / HU 'u/ü' */
    /* Consonants & Sibilants across EN / JA / HU */
    {'K', 320.0f, 1350.0f, 2400.0f, 180.0f, 240.0f, 0.1f, 0.55f, 15}, /* JA か行 / HU 'k' */
    {'S', 420.0f, 1850.0f, 3500.0f, 200.0f, 300.0f, 0.0f, 0.70f, 18}, /* JA さ行 / HU 'sz' */
    {'T', 350.0f, 1750.0f, 2700.0f, 180.0f, 250.0f, 0.1f, 0.50f, 15}, /* JA た行 / HU 't' */
    {'N', 270.0f, 1480.0f, 2500.0f,  65.0f, 110.0f, 0.8f, 0.01f, 20}, /* JA な行・ん / HU 'n/ny' */
    {'H', 520.0f, 1550.0f, 2500.0f, 140.0f, 190.0f, 0.1f, 0.45f, 15}, /* JA は行 / HU 'h' */
    {'M', 260.0f,  980.0f, 2200.0f,  65.0f, 110.0f, 0.8f, 0.01f, 20}, /* JA ま行 / HU 'm' */
    {'Y', 290.0f, 2150.0f, 2900.0f,  70.0f,  90.0f, 0.9f, 0.02f, 18}, /* JA や行 / HU 'j/gy' */
    {'R', 420.0f, 1400.0f, 1750.0f,  80.0f, 100.0f, 0.8f, 0.03f, 16}, /* JA ら行 / HU trilled 'r' */
    {'W', 340.0f,  850.0f, 2250.0f,  75.0f,  95.0f, 0.9f, 0.02f, 18}, /* JA わ行 */
    {'G', 310.0f, 1450.0f, 2450.0f, 120.0f, 180.0f, 0.6f, 0.25f, 15}, /* JA が行 / HU 'g' */
    {'Z', 380.0f, 1750.0f, 3300.0f, 160.0f, 240.0f, 0.5f, 0.50f, 18}, /* JA ざ行 / HU 'z/zs' */
    {'D', 330.0f, 1650.0f, 2600.0f, 120.0f, 180.0f, 0.6f, 0.25f, 15}, /* JA だ行 / HU 'd' */
    {'B', 300.0f, 1050.0f, 2250.0f, 110.0f, 160.0f, 0.7f, 0.20f, 15}, /* JA ば行 / HU 'b' */
    {'V', 320.0f, 1250.0f, 2350.0f, 120.0f, 170.0f, 0.6f, 0.35f, 16}, /* HU 'v' / EN 'v' */
    {'L', 380.0f, 1150.0f, 2600.0f,  80.0f, 100.0f, 0.8f, 0.03f, 18}, /* EN/HU 'l' */
    {' ', 500.0f, 1500.0f, 2500.0f, 100.0f, 120.0f, 0.0f, 0.00f, 15},
};

typedef struct {
    float a1, a2, b0;
    float y1, y2;
} flugos_biquad_resonator_t;

static void flugos_resonator_set(flugos_biquad_resonator_t *r, float freq, float bw) {
    const float r_pole = expf(-(float)M_PI * bw / (float)FLUGOS_SAMPLE_RATE_HZ);
    r->a2 = -(r_pole * r_pole);
    r->a1 = 2.0f * r_pole * cosf(2.0f * (float)M_PI * freq / (float)FLUGOS_SAMPLE_RATE_HZ);
    r->b0 = 1.0f - r->a1 - r->a2;
}

static inline float flugos_resonator_step(flugos_biquad_resonator_t *r, float x) {
    const float y = r->b0 * x + r->a1 * r->y1 + r->a2 * r->y2;
    r->y2 = r->y1;
    r->y1 = y;
    return y;
}

static const flugos_char_formant_t *flugos_lookup_formant(char c) {
    const char up = (char)toupper((unsigned char)c);
    for (size_t i = 0; i < sizeof(s_trilingual_formant_lut) / sizeof(s_trilingual_formant_lut[0]); ++i) {
        if (s_trilingual_formant_lut[i].ch == up) {
            return &s_trilingual_formant_lut[i];
        }
    }
    return &s_trilingual_formant_lut[11]; /* Voiced glide fallback */
}

size_t flugos_mouth_synthesize_intent_pkt(
    const flugos_text_pkt_t *intent_pkt,
    int16_t *pcm_out_buf,
    size_t max_pcm_samples
) {
    if (!intent_pkt || !pcm_out_buf || max_pcm_samples < FLUGOS_FRAME_SAMPLES) {
        return 0U;
    }

    const char *src = (intent_pkt->body.text[0] != '\0')
        ? intent_pkt->body.text
        : intent_pkt->body.phonemes;
    if (src[0] == '\0') {
        return 0U;
    }

    flugos_biquad_resonator_t res1 = {0}, res2 = {0}, res3 = {0};
    size_t written = 0U;
    float phase = 0.0f;
    uint32_t lfsr = 0xACE1U;

    for (size_t idx = 0; src[idx] != '\0'; ++idx) {
        const flugos_char_formant_t *fm = flugos_lookup_formant(src[idx]);
        flugos_resonator_set(&res1, fm->f1, fm->bw1);
        flugos_resonator_set(&res2, fm->f2, fm->bw2);
        flugos_resonator_set(&res3, fm->f3, 150.0f);

        const size_t total_samples = (size_t)((fm->dur_ms * (int)FLUGOS_SAMPLE_RATE_HZ) / 1000);
        if (written + total_samples > max_pcm_samples) {
            break;
        }

        const float f0 = 115.0f + (float)((idx % 5U) * 4U);
        for (size_t s = 0; s < total_samples; ++s) {
            phase += f0 / (float)FLUGOS_SAMPLE_RATE_HZ;
            if (phase >= 1.0f) phase -= 1.0f;

            const float glottal = (phase < 0.7f) ? sinf(phase * (float)M_PI / 0.7f) : -0.3f;
            lfsr = (lfsr >> 1U) ^ (uint32_t)(-(int32_t)(lfsr & 1U) & 0xB400);
            const float noise = ((float)(int16_t)lfsr / 32768.0f);

            const float exc = (glottal * fm->voiced_gain) + (noise * fm->noise_gain);
            const float out = flugos_resonator_step(&res1, exc) +
                              0.6f * flugos_resonator_step(&res2, exc) +
                              0.25f * flugos_resonator_step(&res3, exc);

            int32_t sample = (int32_t)(out * 5500.0f);
            if (sample > 32767)  sample = 32767;
            if (sample < -32768) sample = -32768;
            pcm_out_buf[written++] = (int16_t)sample;
        }
    }

    return written;
}

#ifdef ESP_PLATFORM
static void flugos_mouth_init_i2s_max98357a(void) {
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 6;
    chan_cfg.dma_frame_num = FLUGOS_FRAME_SAMPLES;
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &s_tx_chan, NULL));

    i2s_std_config_t std_cfg = {
        .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(FLUGOS_SAMPLE_RATE_HZ),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = FLUGOS_MOUTH_I2S_BCLK_GPIO,
            .ws   = FLUGOS_MOUTH_I2S_LRC_GPIO,
            .dout = FLUGOS_MOUTH_I2S_DIN_GPIO,
            .din  = I2S_GPIO_UNUSED,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv   = false,
            },
        },
    };
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(s_tx_chan, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(s_tx_chan));
    ESP_LOGI(TAG, "MAX98357A I2S Class-D DAC initialized (BCLK=GPIO15, LRC=GPIO16, DIN=GPIO17)");
}

static void flugos_mouth_playback_task(void *arg) {
    (void)arg;
    static int16_t s_tts_pcm_buf[32000]; /* 2.0s trilingual formant buffer */
    uint8_t rx_buf[FLUGOS_ESPNOW_MAX_PAYLOAD];

    for (;;) {
        const size_t n = flugos_mesh_recv_frame(rx_buf, sizeof(rx_buf), 100U);
        if (n == sizeof(flugos_text_pkt_t)) {
            const flugos_text_pkt_t *pkt = (const flugos_text_pkt_t *)rx_buf;
            if (pkt->hdr.pkt_type == (uint8_t)FLUGOS_PKT_TEXT_INTENT) {
                const size_t pcm_samples = flugos_mouth_synthesize_intent_pkt(
                    pkt,
                    s_tts_pcm_buf,
                    sizeof(s_tts_pcm_buf) / sizeof(s_tts_pcm_buf[0])
                );
                if (pcm_samples > 0U) {
                    size_t bytes_written = 0U;
                    i2s_channel_write(
                        s_tx_chan,
                        s_tts_pcm_buf,
                        pcm_samples * sizeof(int16_t),
                        &bytes_written,
                        portMAX_DELAY
                    );
                    ESP_LOGI(TAG, "Synthesized & played %u Trilingual PCM samples for intent #%u",
                             (unsigned)pcm_samples, (unsigned)pkt->body.intent_id);
                }
            }
        }
    }
}
#endif

void flugos_node_mouth_main(void) {
#ifdef ESP_PLATFORM
    flugos_mouth_init_i2s_max98357a();
    xTaskCreatePinnedToCore(
        flugos_mouth_playback_task,
        "flugos_mouth_tx",
        6144,
        NULL,
        18,
        NULL,
        1
    );
#endif
}
