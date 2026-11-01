/* ============================================================================
 * FlugOS Common Mesh, Codec & Trilingual Telemetry Layer: common/flugos_mesh.h
 * ============================================================================
 * Ontological Boundary Contract (8B-META-WP-v0.0):
 *   * Column A (Mechanical Substrate): Deterministic connectionless ESP-NOW
 *     frame transport (<= 250 bytes/packet), CRC16-CCITT integrity check,
 *     4:1 IMA-ADPCM audio codec (320 samples <-> 80 bytes @ 16kHz),
 *     zero-copy FreeRTOS StreamBuffer ring-buffer bridge, 44-byte RIFF WAV
 *     SD-card corpus harvester, and Trilingual (EN/JA/HU) formant synthesis.
 *   * Column B (Architect's Heuristic): Co-Dreaming Under One Roof & 3-Node
 *     Sensory-Cognitive-Motor Partition (EAR -> BRAIN -> MOUTH) with Galaxy/BLU
 *     mobile hotspot & aurora-cluster.8b.is edge-training uplink.
 * ============================================================================ */

#ifndef FLUGOS_MESH_H
#define FLUGOS_MESH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Node Roles in the 3-Node ESP32-S3 Offline Voice Cluster */
#define FLUGOS_NODE_ROLE_EAR    1U  /* Node 1: INMP441 I2S + VAD + WakeNet9 + ADPCM TX */
#define FLUGOS_NODE_ROLE_BRAIN  2U  /* Node 2: Octal PSRAM + MultiNet7/STT + SD Corpus */
#define FLUGOS_NODE_ROLE_MOUTH  3U  /* Node 3: Trilingual Formant/ESP-TTS + MAX98357A  */

#ifndef FLUGOS_NODE_ROLE
#ifdef CONFIG_FLUGOS_NODE_ROLE
#define FLUGOS_NODE_ROLE CONFIG_FLUGOS_NODE_ROLE
#else
#define FLUGOS_NODE_ROLE FLUGOS_NODE_ROLE_EAR
#endif
#endif

/* Audio & Codec Constants */
#define FLUGOS_SAMPLE_RATE_HZ         16000U
#define FLUGOS_FRAME_SAMPLES          320U    /* 20 ms frame @ 16 kHz mono (640 bytes raw PCM) */
#define FLUGOS_ADPCM_BYTES_PER_FRAME  160U    /* 320 samples * 4 bits = 160 bytes (4:1 from 640B) */
#define FLUGOS_ESPNOW_MAX_PAYLOAD     250U    /* Hard ESP-NOW v1 frame ceiling */
#define FLUGOS_MAGIC_U16              0x4C46U /* Little-endian "FL" */
#define FLUGOS_PROTOCOL_VERSION       1U

/* Network Uplink Targets (Galaxy / BLU Phone Mobile Hotspot + 8b.is DNS) */
#define FLUGOS_MOBILE_HOTSPOT_SSID    "Galaxy_FlugOS_Net"
#define FLUGOS_MOBILE_HOTSPOT_PASS    "aurora_quantum_2026"
#define FLUGOS_DNS_TRAINING_ENDPOINT  "http://aurora-cluster.8b.is/api/v1/ingest"
#define FLUGOS_LOCAL_GALAXY_NODE_URL  "http://192.168.43.1:8080/ingest"
#define FLUGOS_LOCAL_BLU_NODE_URL     "http://192.168.43.102:8080/ingest"

/* Packet Types */
typedef enum {
    FLUGOS_PKT_AUDIO_ADPCM    = 0x01,
    FLUGOS_PKT_UTTERANCE_END  = 0x02,
    FLUGOS_PKT_TEXT_INTENT    = 0x03,
    FLUGOS_PKT_HEARTBEAT_SEAL = 0x04,
    FLUGOS_PKT_ENV_TELEM      = 0x05  /* Ambient noise floor, ZCR, spectral centroid */
} flugos_pkt_type_t;

/* Trilingual Language Routing (English, Japanese Moraic Romaji/Kana, Hungarian Magyar) */
typedef enum {
    FLUGOS_LANG_EN = 0, /* English */
    FLUGOS_LANG_JA = 1, /* Japanese (Romaji / Moraic phoneme mapping) */
    FLUGOS_LANG_HU = 2  /* Hungarian (Magyar phonetic mapping) */
} flugos_lang_t;

/* 44-Byte Standard RIFF WAVE Header (16kHz, 16-bit Mono PCM) */
typedef struct __attribute__((packed)) {
    char     riff[4];         /* "RIFF" */
    uint32_t overall_size;    /* file size - 8 */
    char     wave[4];         /* "WAVE" */
    char     fmt_chunk[4];    /* "fmt " */
    uint32_t fmt_length;      /* 16 */
    uint16_t format_type;     /* 1 (PCM) */
    uint16_t channels;        /* 1 */
    uint32_t sample_rate;     /* 16000 */
    uint32_t byte_rate;       /* 32000 */
    uint16_t block_align;     /* 2 */
    uint16_t bits_per_sample; /* 16 */
    char     data_hdr[4];     /* "data" */
    uint32_t data_size;       /* pcm bytes */
} flugos_wav_header_t;

/* Trilingual Command & Training Anchor Entry */
typedef struct {
    int           cmd_id;
    flugos_lang_t lang;
    const char   *phonetic_trigger; /* MultiNet7 phonetic approximation */
    const char   *raw_transcript;   /* Ground-truth UTF-8 for JSONL training */
    const char   *tts_reply;        /* Phonetic string sent to Node 3 (MOUTH) */
} flugos_trilingual_intent_t;

/* 12-Byte Wire Header for All FlugOS ESP-NOW Frames */
typedef struct __attribute__((packed)) {
    uint16_t magic;        /* FLUGOS_MAGIC_U16 (0x4C46) */
    uint8_t  version;      /* FLUGOS_PROTOCOL_VERSION (1) */
    uint8_t  pkt_type;     /* flugos_pkt_type_t */
    uint8_t  src_role;     /* 1=EAR, 2=BRAIN, 3=MOUTH */
    uint8_t  dst_role;     /* 1=EAR, 2=BRAIN, 3=MOUTH, 0xFF=BROADCAST */
    uint16_t seq_num;      /* Monotonic per-link sequence number */
    uint16_t payload_len;  /* Bytes following header */
    uint16_t crc16;        /* CRC16-CCITT over header (with crc16=0) + payload */
} flugos_pkt_header_t;

/* Audio ADPCM Payload (8 + 80 = 88 bytes; total frame = 100 bytes <= 250B) */
typedef struct __attribute__((packed)) {
    int16_t  predictor;    /* Initial IMA-ADPCM predictor for zero-drift recovery */
    uint8_t  step_index;   /* Initial IMA-ADPCM step table index (0..88) */
    uint8_t  vad_state;    /* 1=speech active, 2=wake-word triggered, 0=hangover */
    uint32_t frame_index;  /* 20ms frame counter within current utterance */
    uint8_t  adpcm[FLUGOS_ADPCM_BYTES_PER_FRAME];
} flugos_audio_payload_t;

typedef struct __attribute__((packed)) {
    flugos_pkt_header_t    hdr;
    flugos_audio_payload_t body;
} flugos_audio_pkt_t;

/* Compact Text & Phoneme Intent Payload (232 bytes; total frame = 244B <= 250B) */
typedef struct __attribute__((packed)) {
    uint16_t intent_id;         /* Recognized command/slot ID */
    int16_t  confidence_q8_8;   /* Fixed-point Q8.8 confidence score */
    uint32_t utterance_frames;  /* Number of 20ms audio frames decoded */
    uint8_t  waking_seal8[8];   /* 64-bit prefix of BLAKE3 Phoenix Waking Seal */
    char     text[160];         /* Null-terminated response text for TTS */
    char     phonemes[56];      /* Null-terminated phoneme/prosody code sequence */
} flugos_text_payload_t;

typedef struct __attribute__((packed)) {
    flugos_pkt_header_t   hdr;
    flugos_text_payload_t body;
} flugos_text_pkt_t;

/* Compile-time assertions enforcing the 250-byte ESP-NOW limit & 44B WAV header */
typedef char flugos_assert_audio_pkt_size[(sizeof(flugos_audio_pkt_t) <= FLUGOS_ESPNOW_MAX_PAYLOAD) ? 1 : -1];
typedef char flugos_assert_text_pkt_size[(sizeof(flugos_text_pkt_t) <= FLUGOS_ESPNOW_MAX_PAYLOAD) ? 1 : -1];
typedef char flugos_assert_wav_hdr_size[(sizeof(flugos_wav_header_t) == 44U) ? 1 : -1];

/* IMA-ADPCM Codec State */
typedef struct {
    int32_t predictor;
    int32_t step_index;
} flugos_adpcm_state_t;

/* Byte Ring Buffer (Used inside ISR/Callback -> Task bridge and host simulation) */
#define FLUGOS_RINGBUF_CAPACITY 16384U

typedef struct {
    uint8_t  buf[FLUGOS_RINGBUF_CAPACITY];
    uint32_t head;
    uint32_t tail;
    uint32_t count;
    uint32_t dropped_packets;
} flugos_ringbuf_t;

/* Core API */
uint16_t flugos_crc16_ccitt(const uint8_t *data, size_t len);
void     flugos_pkt_seal(void *pkt_buf, size_t total_len);
bool     flugos_pkt_verify(const void *pkt_buf, size_t total_len);

void     flugos_adpcm_init(flugos_adpcm_state_t *state);
void     flugos_adpcm_encode_block(
    flugos_adpcm_state_t *state,
    const int16_t *pcm_in,
    size_t num_samples,
    uint8_t *adpcm_out
);
void     flugos_adpcm_decode_block(
    flugos_adpcm_state_t *state,
    const uint8_t *adpcm_in,
    size_t num_bytes,
    int16_t *pcm_out
);

/* Transport & StreamBuffer Bridge API */
int      flugos_mesh_init(uint8_t self_role, uint8_t wifi_channel, bool enable_lr);
int      flugos_mesh_send_frame(const void *frame, size_t len);
size_t   flugos_mesh_recv_frame(void *frame_out, size_t max_len, uint32_t timeout_ms);
uint32_t flugos_mesh_get_rx_Avail(void);

/* Node Entrypoints */
void flugos_node_ear_main(void);
void flugos_node_brain_main(void);
void flugos_node_mouth_main(void);

/* Deterministic Single-Frame Processors (Used by both FreeRTOS tasks and CI tests) */
bool flugos_ear_process_pcm_frame(
    const int16_t *pcm320,
    uint32_t frame_idx,
    flugos_adpcm_state_t *adpcm_state,
    uint16_t *seq_counter,
    flugos_audio_pkt_t *pkt_out
);

bool flugos_brain_ingest_audio_pkt(
    const flugos_audio_pkt_t *audio_pkt,
    int16_t *psram_pcm_ring,
    size_t psram_max_samples,
    size_t *accumulated_samples,
    uint16_t *seq_counter,
    flugos_text_pkt_t *intent_pkt_out
);

/* Environmental Feature Extraction & Trilingual SD Corpus Harvester */
void flugos_brain_analyze_environment_frame(
    const int16_t *pcm,
    size_t samples,
    float *out_rms,
    float *out_zcr
);

const flugos_trilingual_intent_t *flugos_brain_lookup_trilingual_intent(int cmd_id);

bool flugos_brain_save_training_sample(
    const char *corpus_dir,
    uint32_t utterance_id,
    const int16_t *pcm,
    size_t samples,
    int matched_cmd_id,
    float zcr,
    float rms
);

size_t flugos_mouth_synthesize_intent_pkt(
    const flugos_text_pkt_t *intent_pkt,
    int16_t *pcm_out_buf,
    size_t max_pcm_samples
);

#ifdef __cplusplus
}
#endif

#endif /* FLUGOS_MESH_H */
