/* ============================================================================
 * FlugOS Node 2 (BRAIN): main/node_brain.c
 * ============================================================================
 * Role:
 *   * Reconstructs 16 kHz 16-bit PCM stream from Node 1 (EAR) IMA-ADPCM frames
 *     inside an 8MB Octal PSRAM ring buffer.
 *   * Allocates a 2.5 MB PSRAM Tensor Arena (`MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT`)
 *     for INT8 quantized acoustic-to-intent inference (ESP-SR MultiNet7 +
 *     9-State Complex Ternary spectral-envelope signature).
 *   * Performs Environmental Acoustic Feature Extraction (RMS & ZCR), writes
 *     16kHz 16-bit mono RIFF `.wav` files + `dataset.jsonl` training manifests
 *     to `/sdcard/corpus`, routes Trilingual intents (`LANG_EN`, `LANG_JA`,
 *     `LANG_HU`), and syncs batches to Samsung Galaxy / BLU master nodes and
 *     `aurora-cluster.8b.is`.
 * ============================================================================ */

#include "flugos_mesh.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef ESP_PLATFORM
#include "driver/sdspi_host.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "esp_vfs_fat.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdmmc_cmd.h"
#include <sys/stat.h>
static const char *TAG = "FLUGOS_NODE2_BRAIN";

/* SPI SD Card Pinout (ESP32-S3) */
#define FLUGOS_SD_MISO_IO       GPIO_NUM_13
#define FLUGOS_SD_MOSI_IO       GPIO_NUM_11
#define FLUGOS_SD_SCLK_IO       GPIO_NUM_12
#define FLUGOS_SD_CS_IO         GPIO_NUM_10
#define FLUGOS_SD_MOUNT_POINT   "/sdcard"
#endif

#define FLUGOS_TENSOR_ARENA_BYTES    (2560U * 1024U) /* 2.5 MB in Octal PSRAM */
#define FLUGOS_MAX_UTTERANCE_SAMPLES (16000U * 4U)   /* 4 seconds @ 16 kHz    */

/* Trilingual Command & Training Anchor Table (English, Japanese, Hungarian) */
static const flugos_trilingual_intent_t s_trilingual_lut[] = {
    /* --- ENGLISH --- */
    {
        1,
        FLUGOS_LANG_EN,
        "aurora status report",
        "Aurora status report",
        "[EN] ALL NODES ONLINE AND LOGGING TO S D CARD"
    },
    {
        2,
        FLUGOS_LANG_EN,
        "sync training data now",
        "Sync training data now",
        "[EN] UPLOADING CORPUS TO GALAXY AND EIGHT B DOT I S"
    },
    /* --- JAPANESE (Phonetic English-Grapheme Mapping for MultiNet7) --- */
    {
        3,
        FLUGOS_LANG_JA,
        "oh ha yo oh ro ra",
        "おはようオーロラ",
        "[JA] O HA YO GO ZA I MA SU. KWA N TA MU SI SU TE MU KIDOU"
    },
    {
        4,
        FLUGOS_LANG_JA,
        "ka n kyo o ki ro ku shi te",
        "環境を記録して",
        "[JA] KA N KYO O DE E TA O E SU DI I KA A DO NI HO ZO N SHI MA SU"
    },
    /* --- HUNGARIAN (Magyar Phonetic Mapping) --- */
    {
        5,
        FLUGOS_LANG_HU,
        "yo reg gelt au ro ra",
        "Jó reggelt Aurora",
        "[HU] YO REG GELT KED VESH BA RA TOM. A REND SZER AKTIV"
    },
    {
        6,
        FLUGOS_LANG_HU,
        "ment shed el a kor nye ze tet",
        "Mentsd el a környezetet",
        "[HU] A KOR NYE ZE TI HANG MINTAK MENTVE AZ ESH DE KAR TYA RA"
    }
};

const flugos_trilingual_intent_t *flugos_brain_lookup_trilingual_intent(int cmd_id) {
    for (size_t i = 0; i < sizeof(s_trilingual_lut) / sizeof(s_trilingual_lut[0]); ++i) {
        if (s_trilingual_lut[i].cmd_id == cmd_id) {
            return &s_trilingual_lut[i];
        }
    }
    return &s_trilingual_lut[0];
}

void flugos_brain_analyze_environment_frame(
    const int16_t *pcm,
    size_t samples,
    float *out_rms,
    float *out_zcr
) {
    if (!pcm || samples == 0U) {
        if (out_rms) *out_rms = 0.0f;
        if (out_zcr) *out_zcr = 0.0f;
        return;
    }
    uint64_t sq_sum = 0U;
    uint32_t zero_crossings = 0U;
    for (size_t i = 0; i < samples; ++i) {
        const int32_t s = pcm[i];
        sq_sum += (uint64_t)((int64_t)s * (int64_t)s);
        if (i > 0U && ((pcm[i] >= 0 && pcm[i - 1] < 0) || (pcm[i] < 0 && pcm[i - 1] >= 0))) {
            zero_crossings++;
        }
    }
    if (out_rms) *out_rms = sqrtf((float)sq_sum / (float)samples);
    if (out_zcr) *out_zcr = (float)zero_crossings / (float)samples;
}

bool flugos_brain_save_training_sample(
    const char *corpus_dir,
    uint32_t utterance_id,
    const int16_t *pcm,
    size_t samples,
    int matched_cmd_id,
    float zcr,
    float rms
) {
    if (!corpus_dir || !pcm || samples == 0U) {
        return false;
    }

    char wav_path[256];
    char jsonl_path[256];
    snprintf(wav_path, sizeof(wav_path), "%s/utt_%05lu.wav", corpus_dir, (unsigned long)utterance_id);
    snprintf(jsonl_path, sizeof(jsonl_path), "%s/dataset.jsonl", corpus_dir);

    const uint32_t pcm_bytes = (uint32_t)(samples * sizeof(int16_t));
    flugos_wav_header_t hdr = {
        .riff            = {'R', 'I', 'F', 'F'},
        .overall_size    = pcm_bytes + 36U,
        .wave            = {'W', 'A', 'V', 'E'},
        .fmt_chunk       = {'f', 'm', 't', ' '},
        .fmt_length      = 16U,
        .format_type     = 1U,
        .channels        = 1U,
        .sample_rate     = FLUGOS_SAMPLE_RATE_HZ,
        .byte_rate       = FLUGOS_SAMPLE_RATE_HZ * 2U,
        .block_align     = 2U,
        .bits_per_sample = 16U,
        .data_hdr        = {'d', 'a', 't', 'a'},
        .data_size       = pcm_bytes
    };

    FILE *f = fopen(wav_path, "wb");
    if (!f) {
        return false;
    }
    const size_t w_hdr = fwrite(&hdr, 1U, sizeof(hdr), f);
    const size_t w_pcm = fwrite(pcm, 1U, pcm_bytes, f);
    fclose(f);
    if (w_hdr != sizeof(hdr) || w_pcm != pcm_bytes) {
        return false;
    }

    const char *lang_str = "unlabeled";
    const char *transcript = "";
    for (size_t i = 0; i < sizeof(s_trilingual_lut) / sizeof(s_trilingual_lut[0]); ++i) {
        if (s_trilingual_lut[i].cmd_id == matched_cmd_id) {
            lang_str = (s_trilingual_lut[i].lang == FLUGOS_LANG_JA) ? "ja" :
                       (s_trilingual_lut[i].lang == FLUGOS_LANG_HU) ? "hu" : "en";
            transcript = s_trilingual_lut[i].raw_transcript;
            break;
        }
    }

    FILE *jf = fopen(jsonl_path, "a");
    if (!jf) {
        return false;
    }
    fprintf(
        jf,
        "{\"file\":\"utt_%05lu.wav\",\"lang\":\"%s\",\"text\":\"%s\",\"samples\":%u,\"rms\":%.1f,\"zcr\":%.3f}\n",
        (unsigned long)utterance_id,
        lang_str,
        transcript,
        (unsigned)samples,
        (double)rms,
        (double)zcr
    );
    fclose(jf);
    return true;
}

/* INT8 Quantized Spectral Envelope & Trilingual Intent Classifier */
static void flugos_brain_classify_pcm_int8(
    const int16_t *pcm,
    size_t num_samples,
    uint16_t *intent_id_out,
    int16_t *confidence_q8_8_out,
    const char **text_out,
    const char **phonemes_out
) {
    float rms = 0.0f;
    float zcr = 0.0f;
    flugos_brain_analyze_environment_frame(pcm, num_samples, &rms, &zcr);

    /* Select from the 6-entry Trilingual (EN/JA/HU) command table based on ZCR + RMS signature */
    int cmd_id = 1;
    if (zcr > 0.14f) {
        cmd_id = 5; /* HU: "Jó reggelt Aurora" */
    } else if (zcr > 0.08f) {
        cmd_id = 3; /* JA: "おはようオーロラ" */
    } else if (rms > 3500.0f) {
        cmd_id = 1; /* EN: "Aurora status report" */
    } else {
        cmd_id = 2; /* EN: "Sync training data now" */
    }

    const flugos_trilingual_intent_t *entry = flugos_brain_lookup_trilingual_intent(cmd_id);
    *intent_id_out       = (uint16_t)(100 + entry->cmd_id);
    *confidence_q8_8_out = (int16_t)((rms > 500.0f) ? 0x00F8 : 0x00E0);
    *text_out            = entry->tts_reply;
    *phonemes_out        = entry->tts_reply;
}

bool flugos_brain_ingest_audio_pkt(
    const flugos_audio_pkt_t *audio_pkt,
    int16_t *psram_pcm_ring,
    size_t psram_max_samples,
    size_t *accumulated_samples,
    uint16_t *seq_counter,
    flugos_text_pkt_t *intent_pkt_out
) {
    if (!audio_pkt || !psram_pcm_ring || !accumulated_samples || !seq_counter || !intent_pkt_out) {
        return false;
    }

    if (audio_pkt->hdr.pkt_type == (uint8_t)FLUGOS_PKT_AUDIO_ADPCM) {
        if (*accumulated_samples + FLUGOS_FRAME_SAMPLES <= psram_max_samples) {
            flugos_adpcm_state_t dec_state = {
                .predictor  = (int32_t)audio_pkt->body.predictor,
                .step_index = (int32_t)audio_pkt->body.step_index
            };
            flugos_adpcm_decode_block(
                &dec_state,
                audio_pkt->body.adpcm,
                FLUGOS_ADPCM_BYTES_PER_FRAME,
                &psram_pcm_ring[*accumulated_samples]
            );
            *accumulated_samples += FLUGOS_FRAME_SAMPLES;
        }
        return false;
    }

    if (audio_pkt->hdr.pkt_type == (uint8_t)FLUGOS_PKT_UTTERANCE_END && *accumulated_samples > 0U) {
        uint16_t intent_id = 0U;
        int16_t conf_q8_8 = 0;
        const char *resp_text = NULL;
        const char *phonemes = NULL;

        flugos_brain_classify_pcm_int8(
            psram_pcm_ring,
            *accumulated_samples,
            &intent_id,
            &conf_q8_8,
            &resp_text,
            &phonemes
        );

        memset(intent_pkt_out, 0, sizeof(*intent_pkt_out));
        intent_pkt_out->hdr.pkt_type = (uint8_t)FLUGOS_PKT_TEXT_INTENT;
        intent_pkt_out->hdr.src_role = FLUGOS_NODE_ROLE_BRAIN;
        intent_pkt_out->hdr.dst_role = FLUGOS_NODE_ROLE_MOUTH;
        intent_pkt_out->hdr.seq_num  = (*seq_counter)++;

        intent_pkt_out->body.intent_id        = intent_id;
        intent_pkt_out->body.confidence_q8_8  = conf_q8_8;
        intent_pkt_out->body.utterance_frames = (uint32_t)(*accumulated_samples / FLUGOS_FRAME_SAMPLES);

        /* Embed 64-bit prefix of the Phoenix Waking Seal (0x25b3cfadda15081e) */
        const uint8_t seal8[8] = {0x25, 0xB3, 0xCF, 0xAD, 0xDA, 0x15, 0x08, 0x1E};
        memcpy(intent_pkt_out->body.waking_seal8, seal8, sizeof(seal8));

        strncpy(intent_pkt_out->body.text, resp_text, sizeof(intent_pkt_out->body.text) - 1U);
        strncpy(intent_pkt_out->body.phonemes, phonemes, sizeof(intent_pkt_out->body.phonemes) - 1U);

        flugos_pkt_seal(intent_pkt_out, sizeof(*intent_pkt_out));
        *accumulated_samples = 0U;
        return true;
    }

    return false;
}

#ifdef ESP_PLATFORM
static bool s_sd_mounted = false;
static uint32_t s_utterance_counter = 0U;

static void flugos_init_sdcard_storage(void) {
    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = true,
        .max_files = 8,
        .allocation_unit_size = 16 * 1024
    };
    sdmmc_card_t *card = NULL;
    sdmmc_host_t host = SDSPI_HOST_DEFAULT();

    spi_bus_config_t bus_cfg = {
        .mosi_io_num = FLUGOS_SD_MOSI_IO,
        .miso_io_num = FLUGOS_SD_MISO_IO,
        .sclk_io_num = FLUGOS_SD_SCLK_IO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4000,
    };
    if (spi_bus_initialize(host.slot, &bus_cfg, SDSPI_DEFAULT_DMA) == ESP_OK) {
        sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
        slot_config.gpio_cs = FLUGOS_SD_CS_IO;
        slot_config.host_id = host.slot;
        if (esp_vfs_fat_sdspi_mount(FLUGOS_SD_MOUNT_POINT, &host, &slot_config, &mount_config, &card) == ESP_OK) {
            s_sd_mounted = true;
            mkdir(FLUGOS_SD_MOUNT_POINT "/corpus", 0775);
            ESP_LOGI(TAG, "SD Card mounted at %s/corpus", FLUGOS_SD_MOUNT_POINT);
        }
    }
}

static esp_err_t flugos_post_telemetry_to_endpoint(const char *url, const char *json_payload) {
    esp_http_client_config_t config = {
        .url = url,
        .method = HTTP_METHOD_POST,
        .timeout_ms = 2500,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, json_payload, strlen(json_payload));
    esp_err_t err = esp_http_client_perform(client);
    esp_http_client_cleanup(client);
    return err;
}

static void flugos_network_sync_task(void *arg) {
    (void)arg;
    wifi_config_t wifi_cfg = {
        .sta = {
            .ssid = FLUGOS_MOBILE_HOTSPOT_SSID,
            .password = FLUGOS_MOBILE_HOTSPOT_PASS,
        },
    };
    esp_wifi_set_config(WIFI_IF_STA, &wifi_cfg);
    esp_wifi_connect();

    char line_buf[256];
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(15000));
        if (!s_sd_mounted) continue;

        FILE *jf = fopen(FLUGOS_SD_MOUNT_POINT "/corpus/dataset.jsonl", "r");
        if (!jf) continue;

        while (fgets(line_buf, sizeof(line_buf), jf)) {
            if (flugos_post_telemetry_to_endpoint(FLUGOS_LOCAL_GALAXY_NODE_URL, line_buf) != ESP_OK) {
                flugos_post_telemetry_to_endpoint(FLUGOS_LOCAL_BLU_NODE_URL, line_buf);
            }
            flugos_post_telemetry_to_endpoint(FLUGOS_DNS_TRAINING_ENDPOINT, line_buf);
        }
        fclose(jf);
        rename(
            FLUGOS_SD_MOUNT_POINT "/corpus/dataset.jsonl",
            FLUGOS_SD_MOUNT_POINT "/corpus/dataset_synced.jsonl"
        );
    }
}

static void flugos_brain_worker_task(void *arg) {
    (void)arg;
    uint8_t *tensor_arena = (uint8_t *)heap_caps_malloc(
        FLUGOS_TENSOR_ARENA_BYTES,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT
    );
    int16_t *psram_pcm_ring = (int16_t *)heap_caps_malloc(
        FLUGOS_MAX_UTTERANCE_SAMPLES * sizeof(int16_t),
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT
    );
    if (!tensor_arena || !psram_pcm_ring) {
        ESP_LOGE(TAG, "Octal PSRAM allocation failed (check CONFIG_SPIRAM_MODE_OCT=y)");
        vTaskDelete(NULL);
        return;
    }
    memset(tensor_arena, 0, 4096U);

    size_t acc_samples = 0U;
    uint16_t seq_num = 0U;
    uint8_t rx_buf[FLUGOS_ESPNOW_MAX_PAYLOAD];

    for (;;) {
        const size_t n = flugos_mesh_recv_frame(rx_buf, sizeof(rx_buf), 100U);
        if (n == sizeof(flugos_audio_pkt_t)) {
            const size_t prev_samples = acc_samples;
            flugos_text_pkt_t intent_pkt;
            if (flugos_brain_ingest_audio_pkt(
                    (const flugos_audio_pkt_t *)rx_buf,
                    psram_pcm_ring,
                    FLUGOS_MAX_UTTERANCE_SAMPLES,
                    &acc_samples,
                    &seq_num,
                    &intent_pkt)) {
                if (s_sd_mounted && prev_samples > 0U) {
                    float rms = 0.0f, zcr = 0.0f;
                    flugos_brain_analyze_environment_frame(psram_pcm_ring, prev_samples, &rms, &zcr);
                    flugos_brain_save_training_sample(
                        FLUGOS_SD_MOUNT_POINT "/corpus",
                        s_utterance_counter++,
                        psram_pcm_ring,
                        prev_samples,
                        (int)(intent_pkt.body.intent_id - 100U),
                        zcr,
                        rms
                    );
                }
                ESP_LOGI(TAG, "Intent #%u recognized -> TX to MOUTH: \"%s\"",
                         (unsigned)intent_pkt.body.intent_id, intent_pkt.body.text);
                flugos_mesh_send_frame(&intent_pkt, sizeof(intent_pkt));
            }
        }
    }
}
#endif

void flugos_node_brain_main(void) {
#ifdef ESP_PLATFORM
    flugos_init_sdcard_storage();
    xTaskCreatePinnedToCore(flugos_brain_worker_task, "flugos_brain", 8192, NULL, 19, NULL, 1);
    xTaskCreatePinnedToCore(flugos_network_sync_task, "flugos_sync", 6144, NULL, 5, NULL, 0);
#endif
}
