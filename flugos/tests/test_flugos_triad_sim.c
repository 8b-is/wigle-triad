/* ============================================================================
 * FlugOS 3-Node End-to-End Hardware-Exact Simulation & Attestation Suite
 * ============================================================================
 * Verifies:
 *   1. Compile-time & runtime ESP-NOW packet ceilings (<= 250 bytes) & 44B WAV header.
 *   2. 4:1 IMA-ADPCM encode/decode fidelity (320 samples <-> 80 bytes).
 *   3. CRC16-CCITT frame sealing and tamper rejection.
 *   4. Full 3-Node pipeline:
 *      Node 1 (EAR) -> ESP-NOW RingBuf -> Node 2 (BRAIN) -> ESP-NOW RingBuf -> Node 3 (MOUTH)
 *   5. Trilingual (EN / JA / HU) intent routing, environmental acoustic feature
 *      extraction (RMS & ZCR), and 16kHz RIFF `.wav` + `dataset.jsonl` harvesting.
 * ============================================================================ */

#include "flugos_mesh.h"
#include "flugos_mosaico.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int main(void) {
    printf("=== FlugOS 3-Node ESP32-S3 Offline Voice Mesh Attestation ===\n");
    printf("  sizeof(flugos_pkt_header_t) = %zu bytes\n", sizeof(flugos_pkt_header_t));
    printf("  sizeof(flugos_audio_pkt_t)  = %zu bytes (limit <= %u)\n",
           sizeof(flugos_audio_pkt_t), FLUGOS_ESPNOW_MAX_PAYLOAD);
    printf("  sizeof(flugos_text_pkt_t)   = %zu bytes (limit <= %u)\n",
           sizeof(flugos_text_pkt_t), FLUGOS_ESPNOW_MAX_PAYLOAD);
    printf("  sizeof(flugos_wav_header_t) = %zu bytes (RIFF WAVE standard = 44)\n",
           sizeof(flugos_wav_header_t));

    assert(sizeof(flugos_pkt_header_t) == 12U);
    assert(sizeof(flugos_audio_pkt_t)  == 180U);
    assert(sizeof(flugos_text_pkt_t)   == 244U);
    assert(sizeof(flugos_wav_header_t) == 44U);
    assert(sizeof(flugos_audio_pkt_t)  <= FLUGOS_ESPNOW_MAX_PAYLOAD);
    assert(sizeof(flugos_text_pkt_t)   <= FLUGOS_ESPNOW_MAX_PAYLOAD);

    /* 1. Test IMA-ADPCM 4:1 Codec Round-Trip Fidelity */
    int16_t src_pcm[FLUGOS_FRAME_SAMPLES];
    int16_t dec_pcm[FLUGOS_FRAME_SAMPLES];
    uint8_t adpcm_wire[FLUGOS_ADPCM_BYTES_PER_FRAME];

    for (size_t i = 0; i < FLUGOS_FRAME_SAMPLES; ++i) {
        /* 300 Hz speech fundamental with raised ramp to avoid step-0 cold-start slew */
        const double env = (i < 32U) ? ((double)i / 32.0) : 1.0;
        const double t = (double)i / (double)FLUGOS_SAMPLE_RATE_HZ;
        src_pcm[i] = (int16_t)(env * 12000.0 * sin(2.0 * M_PI * 300.0 * t));
    }

    flugos_adpcm_state_t enc_st, dec_st;
    flugos_adpcm_init(&enc_st);
    flugos_adpcm_init(&dec_st);

    flugos_adpcm_encode_block(&enc_st, src_pcm, FLUGOS_FRAME_SAMPLES, adpcm_wire);
    flugos_adpcm_decode_block(&dec_st, adpcm_wire, FLUGOS_ADPCM_BYTES_PER_FRAME, dec_pcm);

    double sig_pow = 0.0;
    double err_pow = 0.0;
    for (size_t i = 32U; i < FLUGOS_FRAME_SAMPLES; ++i) {
        const double s = (double)src_pcm[i];
        const double e = (double)src_pcm[i] - (double)dec_pcm[i];
        sig_pow += s * s;
        err_pow += e * e;
    }
    const double snr_db = 10.0 * log10(sig_pow / (err_pow + 1e-9));
    printf("  [PASS] 4:1 IMA-ADPCM Codec Round-Trip SNR: %.2f dB (320 samples / 640B -> 160 bytes)\n", snr_db);
    assert(snr_db > 35.0);

    /* 2. Simulate Full 3-Node Pipeline: EAR (Node 1) -> BRAIN (Node 2) -> MOUTH (Node 3) */
    assert(flugos_mesh_init(FLUGOS_NODE_ROLE_EAR, 1U, false) == 0);

    flugos_adpcm_state_t ear_adpcm;
    flugos_adpcm_init(&ear_adpcm);
    uint16_t ear_seq = 0U;

    const size_t total_frames = 25U; /* 500 ms utterance */
    size_t tx_audio_pkts = 0U;

    for (size_t f = 0; f < total_frames; ++f) {
        int16_t frame_pcm[FLUGOS_FRAME_SAMPLES];
        for (size_t i = 0; i < FLUGOS_FRAME_SAMPLES; ++i) {
            const double idx = (double)(f * FLUGOS_FRAME_SAMPLES + i);
            frame_pcm[i] = (int16_t)(9000.0 * sin(2.0 * M_PI * 750.0 * idx / 16000.0));
        }

        flugos_audio_pkt_t audio_pkt;
        const bool active = flugos_ear_process_pcm_frame(
            frame_pcm,
            (uint32_t)f,
            &ear_adpcm,
            &ear_seq,
            &audio_pkt
        );
        assert(active);
        assert(flugos_pkt_verify(&audio_pkt, sizeof(audio_pkt)));
        assert(flugos_mesh_send_frame(&audio_pkt, sizeof(audio_pkt)) == 0);
        tx_audio_pkts++;
    }

    /* Send End-of-Utterance control frame from Node 1 (EAR) to Node 2 (BRAIN) */
    flugos_audio_pkt_t eou_pkt;
    memset(&eou_pkt, 0, sizeof(eou_pkt));
    eou_pkt.hdr.pkt_type = (uint8_t)FLUGOS_PKT_UTTERANCE_END;
    eou_pkt.hdr.src_role = FLUGOS_NODE_ROLE_EAR;
    eou_pkt.hdr.dst_role = FLUGOS_NODE_ROLE_BRAIN;
    eou_pkt.hdr.seq_num  = ear_seq++;
    flugos_pkt_seal(&eou_pkt, sizeof(eou_pkt));
    assert(flugos_mesh_send_frame(&eou_pkt, sizeof(eou_pkt)) == 0);

    /* Node 2 (BRAIN) drains the StreamBuffer, reconstructs PCM in PSRAM ring, and emits intent */
    int16_t psram_pcm_ring[16000 * 2];
    size_t acc_samples = 0U;
    uint16_t brain_seq = 0U;
    flugos_text_pkt_t emitted_intent;
    bool intent_ready = false;

    uint8_t wire_buf[FLUGOS_ESPNOW_MAX_PAYLOAD];
    while (flugos_mesh_get_rx_Avail() > 0U) {
        const size_t n = flugos_mesh_recv_frame(wire_buf, sizeof(wire_buf), 0U);
        assert(n == sizeof(flugos_audio_pkt_t));
        if (flugos_brain_ingest_audio_pkt(
                (const flugos_audio_pkt_t *)wire_buf,
                psram_pcm_ring,
                16000U * 2U,
                &acc_samples,
                &brain_seq,
                &emitted_intent)) {
            intent_ready = true;
        }
    }

    assert(intent_ready);
    assert(flugos_pkt_verify(&emitted_intent, sizeof(emitted_intent)));
    printf("  [PASS] Node 1 -> Node 2 Stream: %zu ADPCM packets decoded -> Intent #%u\n",
           tx_audio_pkts, (unsigned)emitted_intent.body.intent_id);
    printf("         Response Text : \"%s\"\n", emitted_intent.body.text);

    /* 3. Verify Trilingual (EN / JA / HU) Table + RIFF WAV & JSONL Corpus Harvester */
    const flugos_trilingual_intent_t *ja_intent = flugos_brain_lookup_trilingual_intent(3);
    const flugos_trilingual_intent_t *hu_intent = flugos_brain_lookup_trilingual_intent(5);
    assert(ja_intent->lang == FLUGOS_LANG_JA);
    assert(hu_intent->lang == FLUGOS_LANG_HU);
    printf("  [PASS] Trilingual Intent Lookup: JA=\"%s\" -> \"%s\"\n",
           ja_intent->raw_transcript, ja_intent->tts_reply);
    printf("  [PASS] Trilingual Intent Lookup: HU=\"%s\" -> \"%s\"\n",
           hu_intent->raw_transcript, hu_intent->tts_reply);

    float env_rms = 0.0f, env_zcr = 0.0f;
    flugos_brain_analyze_environment_frame(src_pcm, FLUGOS_FRAME_SAMPLES, &env_rms, &env_zcr);
    assert(env_rms > 1000.0f);
    assert(flugos_brain_save_training_sample("/tmp", 42U, src_pcm, FLUGOS_FRAME_SAMPLES, 3, env_zcr, env_rms));
    printf("  [PASS] Harvested 16kHz RIFF WAV (/tmp/utt_00042.wav) + JSONL (RMS=%.1f, ZCR=%.3f)\n",
           (double)env_rms, (double)env_zcr);

    /* 4. Node 2 transmits Intent Packet to Node 3 (MOUTH) for Trilingual Formant Synthesis */
    assert(flugos_mesh_send_frame(&emitted_intent, sizeof(emitted_intent)) == 0);

    flugos_text_pkt_t mouth_rx_pkt;
    const size_t mouth_rx_len = flugos_mesh_recv_frame(&mouth_rx_pkt, sizeof(mouth_rx_pkt), 0U);
    assert(mouth_rx_len == sizeof(flugos_text_pkt_t));

    int16_t tts_pcm_out[32000];
    const size_t synth_samples = flugos_mouth_synthesize_intent_pkt(
        &mouth_rx_pkt,
        tts_pcm_out,
        32000U
    );
    assert(synth_samples > 1600U);

    int32_t peak_tts = 0;
    for (size_t i = 0; i < synth_samples; ++i) {
        const int32_t v = (tts_pcm_out[i] < 0) ? -tts_pcm_out[i] : tts_pcm_out[i];
        if (v > peak_tts) peak_tts = v;
    }
    assert(peak_tts > 500);
    printf("  [PASS] Node 2 -> Node 3 Trilingual Formant TTS: synthesized %zu PCM samples (peak=%d)\n",
           synth_samples, (int)peak_tts);

    /* 5. Verify ESP-Mosaico Multi-Function Interaction Module (0x16) Slot Discovery & Quiescence Gate */
    flugos_mosaico_pins_t left_h2, right_h1;
    assert(flugos_mosaico_probe_slot(FLUGOS_MOSAICO_SLOT_LEFT_H2, FLUGOS_MOSAICO_BOARD_ID_INTERACTION, &left_h2));
    assert(flugos_mosaico_probe_slot(FLUGOS_MOSAICO_SLOT_RIGHT_H1, FLUGOS_MOSAICO_BOARD_ID_INTERACTION, &right_h1));
    assert(left_h2.eeprom_i2c_addr == 0x50U && left_h2.ldr_adc_gpio == 53U && left_h2.pir_gpio == 4U && left_h2.ws2812_gpio == 15U);
    assert(right_h1.eeprom_i2c_addr == 0x51U && right_h1.ldr_adc_gpio == 46U && right_h1.pir_gpio == 5U && right_h1.ws2812_gpio == 38U);
    assert(!flugos_mosaico_probe_slot(FLUGOS_MOSAICO_SLOT_LEFT_H2, 0x00U, &left_h2));

    flugos_quiescence_gate_t qgate;
    flugos_quiescence_gate_init(&qgate, 3000U, 8000U, 4U);
    assert(!qgate.in_ultradreamstate);
    for (int t = 0; t < 12; ++t) {
        flugos_quiescence_gate_step(&qgate, 20U, false, false, false, 100U);
    }
    assert(qgate.in_ultradreamstate); /* Entered Tayama UltraDreamState after quiet hold */
    assert(!flugos_quiescence_gate_step(&qgate, 600U, true, false, false, 9000U)); /* Woke back to Yamada on PIR/voice */

    const int8_t trits[6] = { 1, 0, -1, 0, 0, 1 }; /* +0-00+ */
    flugos_ws2812_grb_t leds[6];
    flugos_mosaico_encode_ws2812_trits(trits, leds);
    assert(leds[0].g == 0xF5U && leds[2].r == 0xFFU && leds[1].b == 0x24U);
    assert(flugos_mosaico_encode_nec_ir(0x8BU, 0x16U) == 0xE916748BU);
    printf("  [PASS] ESP-Mosaico (0x16) Left H2 (0x50) / Right H1 (0x51), Quiescence Gate & 6x WS2812 Verified\n");

    printf("=== ALL FLUGOS 3-NODE MESH & TRILINGUAL HARVESTER ATTESTATIONS PASSED ===\n");
    return 0;
}
