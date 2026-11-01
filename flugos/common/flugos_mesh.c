/* ============================================================================
 * FlugOS Common Mesh & Codec Layer: common/flugos_mesh.c
 * ============================================================================
 * Implements:
 *   1. CRC16-CCITT (polynomial 0x1021, init 0xFFFF) packet sealing & checking.
 *   2. Exact 4:1 IMA-ADPCM encoder & decoder (320 int16 samples <-> 80 bytes).
 *   3. Connectionless ESP-NOW transport bridged via FreeRTOS StreamBufferHandle_t
 *      (with deterministic in-memory ring-buffer fallback for host testing).
 * ============================================================================ */

#include "flugos_mesh.h"
#include <string.h>

#ifdef ESP_PLATFORM
#include "freertos/FreeRTOS.h"
#include "freertos/stream_buffer.h"
#include "freertos/task.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
static const char *TAG = "FLUGOS_MESH";
static StreamBufferHandle_t s_rx_stream_buf = NULL;
static const uint8_t s_broadcast_mac[ESP_NOW_ETH_ALEN] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
#endif

static flugos_ringbuf_t s_host_ring;
static uint8_t s_self_role = FLUGOS_NODE_ROLE;

/* IMA-ADPCM Index Adjustment Table (16 entries) */
static const int8_t k_ima_index_table[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

/* IMA-ADPCM Quantizer Step Size Table (89 entries) */
static const int16_t k_ima_step_table[89] = {
        7,     8,     9,    10,    11,    12,    13,    14,    16,    17,
       19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
       50,    55,    60,    66,    73,    80,    88,    97,   107,   118,
      130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
      337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
      876,   963,  1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
     2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
     5894,  6484,  7132,  7845,  8630,  9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

uint16_t flugos_crc16_ccitt(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFFU;
    for (size_t i = 0; i < len; ++i) {
        crc ^= (uint16_t)((uint16_t)data[i] << 8);
        for (int b = 0; b < 8; ++b) {
            if (crc & 0x8000U) {
                crc = (uint16_t)((crc << 1) ^ 0x1021U);
            } else {
                crc = (uint16_t)(crc << 1);
            }
        }
    }
    return crc;
}

void flugos_pkt_seal(void *pkt_buf, size_t total_len) {
    if (!pkt_buf || total_len < sizeof(flugos_pkt_header_t)) {
        return;
    }
    flugos_pkt_header_t *hdr = (flugos_pkt_header_t *)pkt_buf;
    hdr->magic = FLUGOS_MAGIC_U16;
    hdr->version = FLUGOS_PROTOCOL_VERSION;
    hdr->payload_len = (uint16_t)(total_len - sizeof(flugos_pkt_header_t));
    hdr->crc16 = 0U;
    hdr->crc16 = flugos_crc16_ccitt((const uint8_t *)pkt_buf, total_len);
}

bool flugos_pkt_verify(const void *pkt_buf, size_t total_len) {
    if (!pkt_buf || total_len < sizeof(flugos_pkt_header_t) || total_len > FLUGOS_ESPNOW_MAX_PAYLOAD) {
        return false;
    }
    flugos_pkt_header_t hdr_copy;
    memcpy(&hdr_copy, pkt_buf, sizeof(flugos_pkt_header_t));
    if (hdr_copy.magic != FLUGOS_MAGIC_U16 || hdr_copy.version != FLUGOS_PROTOCOL_VERSION) {
        return false;
    }
    if ((size_t)hdr_copy.payload_len + sizeof(flugos_pkt_header_t) != total_len) {
        return false;
    }
    uint8_t scratch[FLUGOS_ESPNOW_MAX_PAYLOAD];
    memcpy(scratch, pkt_buf, total_len);
    ((flugos_pkt_header_t *)scratch)->crc16 = 0U;
    const uint16_t calc_crc = flugos_crc16_ccitt(scratch, total_len);
    return (calc_crc == hdr_copy.crc16);
}

void flugos_adpcm_init(flugos_adpcm_state_t *state) {
    if (!state) return;
    state->predictor = 0;
    state->step_index = 0;
}

static inline uint8_t flugos_adpcm_encode_sample(flugos_adpcm_state_t *state, int16_t sample) {
    int32_t step = k_ima_step_table[state->step_index];
    int32_t diff = (int32_t)sample - state->predictor;
    uint8_t nibble = 0U;

    if (diff < 0) {
        nibble = 8U;
        diff = -diff;
    }
    int32_t vpdiff = step >> 3;
    if (diff >= step) {
        nibble |= 4U;
        diff -= step;
        vpdiff += step;
    }
    step >>= 1;
    if (diff >= step) {
        nibble |= 2U;
        diff -= step;
        vpdiff += step;
    }
    step >>= 1;
    if (diff >= step) {
        nibble |= 1U;
        vpdiff += step;
    }

    if (nibble & 8U) {
        state->predictor -= vpdiff;
    } else {
        state->predictor += vpdiff;
    }
    if (state->predictor > 32767) state->predictor = 32767;
    if (state->predictor < -32768) state->predictor = -32768;

    state->step_index += k_ima_index_table[nibble & 0x0FU];
    if (state->step_index < 0) state->step_index = 0;
    if (state->step_index > 88) state->step_index = 88;

    return (uint8_t)(nibble & 0x0FU);
}

static inline int16_t flugos_adpcm_decode_nibble(flugos_adpcm_state_t *state, uint8_t nibble) {
    int32_t step = k_ima_step_table[state->step_index];
    int32_t vpdiff = step >> 3;

    if (nibble & 4U) vpdiff += step;
    if (nibble & 2U) vpdiff += (step >> 1);
    if (nibble & 1U) vpdiff += (step >> 2);

    if (nibble & 8U) {
        state->predictor -= vpdiff;
    } else {
        state->predictor += vpdiff;
    }
    if (state->predictor > 32767) state->predictor = 32767;
    if (state->predictor < -32768) state->predictor = -32768;

    state->step_index += k_ima_index_table[nibble & 0x0FU];
    if (state->step_index < 0) state->step_index = 0;
    if (state->step_index > 88) state->step_index = 88;

    return (int16_t)state->predictor;
}

void flugos_adpcm_encode_block(
    flugos_adpcm_state_t *state,
    const int16_t *pcm_in,
    size_t num_samples,
    uint8_t *adpcm_out
) {
    const size_t pairs = num_samples >> 1;
    for (size_t i = 0; i < pairs; ++i) {
        const uint8_t lo = flugos_adpcm_encode_sample(state, pcm_in[2 * i]);
        const uint8_t hi = flugos_adpcm_encode_sample(state, pcm_in[2 * i + 1]);
        adpcm_out[i] = (uint8_t)(lo | (uint8_t)(hi << 4));
    }
}

void flugos_adpcm_decode_block(
    flugos_adpcm_state_t *state,
    const uint8_t *adpcm_in,
    size_t num_bytes,
    int16_t *pcm_out
) {
    for (size_t i = 0; i < num_bytes; ++i) {
        const uint8_t byte = adpcm_in[i];
        pcm_out[2 * i]     = flugos_adpcm_decode_nibble(state, (uint8_t)(byte & 0x0FU));
        pcm_out[2 * i + 1] = flugos_adpcm_decode_nibble(state, (uint8_t)((byte >> 4) & 0x0FU));
    }
}

/* Ring buffer helper for length-prefixed frames */
static bool ringbuf_push_frame(flugos_ringbuf_t *rb, const uint8_t *data, uint16_t len) {
    const uint32_t needed = (uint32_t)len + 2U;
    if (needed > FLUGOS_RINGBUF_CAPACITY - rb->count) {
        rb->dropped_packets++;
        return false;
    }
    const uint8_t len_le[2] = {(uint8_t)(len & 0xFFU), (uint8_t)((len >> 8) & 0xFFU)};
    for (uint32_t i = 0; i < 2U; ++i) {
        rb->buf[rb->head] = len_le[i];
        rb->head = (rb->head + 1U) % FLUGOS_RINGBUF_CAPACITY;
    }
    for (uint32_t i = 0; i < len; ++i) {
        rb->buf[rb->head] = data[i];
        rb->head = (rb->head + 1U) % FLUGOS_RINGBUF_CAPACITY;
    }
    rb->count += needed;
    return true;
}

static size_t ringbuf_pop_frame(flugos_ringbuf_t *rb, uint8_t *out, size_t max_len) {
    if (rb->count < 2U) {
        return 0U;
    }
    uint8_t len_le[2];
    for (uint32_t i = 0; i < 2U; ++i) {
        len_le[i] = rb->buf[rb->tail];
        rb->tail = (rb->tail + 1U) % FLUGOS_RINGBUF_CAPACITY;
    }
    rb->count -= 2U;
    const uint16_t frame_len = (uint16_t)((uint16_t)len_le[0] | ((uint16_t)len_le[1] << 8));
    if (frame_len > rb->count || frame_len > max_len) {
        rb->head = 0U;
        rb->tail = 0U;
        rb->count = 0U;
        return 0U;
    }
    for (uint16_t i = 0; i < frame_len; ++i) {
        out[i] = rb->buf[rb->tail];
        rb->tail = (rb->tail + 1U) % FLUGOS_RINGBUF_CAPACITY;
    }
    rb->count -= frame_len;
    return frame_len;
}

#ifdef ESP_PLATFORM
static void flugos_espnow_recv_cb(
    const esp_now_recv_info_t *recv_info,
    const uint8_t *data,
    int data_len
) {
    (void)recv_info;
    if (!data || data_len <= 0 || data_len > (int)FLUGOS_ESPNOW_MAX_PAYLOAD) {
        return;
    }
    if (!flugos_pkt_verify(data, (size_t)data_len)) {
        return;
    }
    const flugos_pkt_header_t *hdr = (const flugos_pkt_header_t *)data;
    if (hdr->dst_role != s_self_role && hdr->dst_role != 0xFFU) {
        return;
    }
    if (s_rx_stream_buf != NULL) {
        uint8_t framed[FLUGOS_ESPNOW_MAX_PAYLOAD + 2U];
        const uint16_t ulen = (uint16_t)data_len;
        framed[0] = (uint8_t)(ulen & 0xFFU);
        framed[1] = (uint8_t)((ulen >> 8) & 0xFFU);
        memcpy(&framed[2], data, (size_t)data_len);
        BaseType_t higher_woken = pdFALSE;
        xStreamBufferSendFromISR(s_rx_stream_buf, framed, (size_t)data_len + 2U, &higher_woken);
        if (higher_woken == pdTRUE) {
            portYIELD_FROM_ISR();
        }
    }
}

static void flugos_espnow_send_cb(const uint8_t *mac_addr, esp_now_send_status_t status) {
    (void)mac_addr;
    (void)status;
}
#endif

int flugos_mesh_init(uint8_t self_role, uint8_t wifi_channel, bool enable_lr) {
    s_self_role = self_role;
    memset(&s_host_ring, 0, sizeof(s_host_ring));

#ifdef ESP_PLATFORM
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    s_rx_stream_buf = xStreamBufferCreate(FLUGOS_RINGBUF_CAPACITY, 1);
    if (s_rx_stream_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate FreeRTOS StreamBuffer");
        return -1;
    }

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_channel(wifi_channel, WIFI_SECOND_CHAN_NONE));

    if (enable_lr) {
        ESP_ERROR_CHECK(esp_wifi_set_protocol(
            WIFI_IF_STA,
            WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N | WIFI_PROTOCOL_LR
        ));
    }

    ESP_ERROR_CHECK(esp_now_init());
    ESP_ERROR_CHECK(esp_now_register_recv_cb(flugos_espnow_recv_cb));
    ESP_ERROR_CHECK(esp_now_register_send_cb(flugos_espnow_send_cb));

    esp_now_peer_info_t peer;
    memset(&peer, 0, sizeof(peer));
    memcpy(peer.peer_addr, s_broadcast_mac, ESP_NOW_ETH_ALEN);
    peer.channel = wifi_channel;
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false;
    ESP_ERROR_CHECK(esp_now_add_peer(&peer));

    ESP_LOGI(TAG, "FlugOS ESP-NOW Mesh online (role=%u, channel=%u, LR=%d)",
             (unsigned)self_role, (unsigned)wifi_channel, (int)enable_lr);
#else
    (void)wifi_channel;
    (void)enable_lr;
#endif
    return 0;
}

int flugos_mesh_send_frame(const void *frame, size_t len) {
    if (!frame || len < sizeof(flugos_pkt_header_t) || len > FLUGOS_ESPNOW_MAX_PAYLOAD) {
        return -1;
    }
    uint8_t local_buf[FLUGOS_ESPNOW_MAX_PAYLOAD];
    memcpy(local_buf, frame, len);
    flugos_pkt_seal(local_buf, len);

#ifdef ESP_PLATFORM
    esp_err_t err = esp_now_send(s_broadcast_mac, local_buf, len);
    return (err == ESP_OK) ? 0 : -1;
#else
    return ringbuf_push_frame(&s_host_ring, local_buf, (uint16_t)len) ? 0 : -1;
#endif
}

size_t flugos_mesh_recv_frame(void *frame_out, size_t max_len, uint32_t timeout_ms) {
    if (!frame_out || max_len < sizeof(flugos_pkt_header_t)) {
        return 0U;
    }
#ifdef ESP_PLATFORM
    if (s_rx_stream_buf == NULL) {
        return 0U;
    }
    uint8_t len_le[2] = {0, 0};
    size_t got = xStreamBufferReceive(
        s_rx_stream_buf,
        len_le,
        2U,
        pdMS_TO_TICKS(timeout_ms)
    );
    if (got != 2U) {
        return 0U;
    }
    const uint16_t frame_len = (uint16_t)((uint16_t)len_le[0] | ((uint16_t)len_le[1] << 8));
    if (frame_len > max_len || frame_len > FLUGOS_ESPNOW_MAX_PAYLOAD) {
        xStreamBufferReset(s_rx_stream_buf);
        return 0U;
    }
    size_t body_got = xStreamBufferReceive(
        s_rx_stream_buf,
        frame_out,
        frame_len,
        pdMS_TO_TICKS(timeout_ms)
    );
    if (body_got != frame_len || !flugos_pkt_verify(frame_out, frame_len)) {
        return 0U;
    }
    return frame_len;
#else
    (void)timeout_ms;
    const size_t n = ringbuf_pop_frame(&s_host_ring, (uint8_t *)frame_out, max_len);
    if (n == 0U || !flugos_pkt_verify(frame_out, n)) {
        return 0U;
    }
    return n;
#endif
}

uint32_t flugos_mesh_get_rx_Avail(void) {
#ifdef ESP_PLATFORM
    if (s_rx_stream_buf == NULL) {
        return 0U;
    }
    return (uint32_t)xStreamBufferBytesAvailable(s_rx_stream_buf);
#else
    return s_host_ring.count;
#endif
}
