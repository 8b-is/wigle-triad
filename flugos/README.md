# FlugOS — 3-Node ESP32-S3 Offline Voice-to-Voice Mesh & Trilingual Edge Harvester (`ESP-IDF v5.3+`)

**FlugOS** is a 100% offline, distributed voice-to-voice cluster and trilingual (`English` / `Japanese` / `Hungarian`) acoustic training harvester engineered for **3x ESP32-S3** microcontrollers (**240MHz Dual-Core Xtensa LX7**, **8MB Octal PSRAM**, **16MB Quad Flash**).

---

## 1. 3-Node Distributed Topology & Hardware Pinout

| Node | Role (`FLUGOS_NODE_ROLE`) | Peripheral & Pinout | Core 0 Task | Core 1 Task |
| :--- | :--- | :--- | :--- | :--- |
| **Node 1** | **`EAR`** (`1`) | **INMP441 I2S Mic** (`SCK=GPIO4`, `WS=GPIO5`, `SD=GPIO6`) | ESP-NOW TX & Wi-Fi Coexistence | 16kHz I2S DMA RX + VAD + WakeNet9 + 4:1 IMA-ADPCM Encoder |
| **Node 2** | **`BRAIN`** (`2`) | **8MB Octal PSRAM** (`80MHz`) + **SPI SD Card** (`MISO=13`, `MOSI=11`, `SCLK=12`, `CS=10`) | ESP-NOW RX/TX + Galaxy/BLU/`8b.is` Sync | PSRAM Ring Buffer + `MultiNet7` / INT8 STT + Trilingual (EN/JA/HU) Intent + RIFF `.wav`/`dataset.jsonl` Harvester |
| **Node 3** | **`MOUTH`** (`3`) | **MAX98357A I2S Amp** (`BCLK=GPIO15`, `LRC=GPIO16`, `DIN=GPIO17`) | ESP-NOW RX Bridge (`StreamBuffer`) | Trilingual 3-Formant Biquad Vocal-Tract / `ESP-TTS` Synthesizer + I2S DMA TX |

---

## 2. Mechanical Substrate & Codec Architecture

1. **ESP-NOW 250-Byte Ceiling & 4:1 IMA-ADPCM (`40.59 dB` Round-Trip SNR)**:
   - Raw 16kHz 16-bit mono PCM is `32,000 bytes/sec` (`640 bytes` per `20ms` frame of `320` samples).
   - [`common/flugos_mesh.c`](common/flugos_mesh.c) compresses each `320`-sample (`640`-byte) frame 4:1 into `160` bytes of 4-bit IMA-ADPCM (`sizeof(flugos_audio_pkt_t) == 180 bytes <= 250 bytes`) with the exact `(predictor, step_index)` snapshot embedded in every frame header for zero-drift packet-loss resilience, sealed with `CRC16-CCITT` (`0x1021`).
2. **Zero-Copy FreeRTOS `StreamBufferHandle_t` Bridge**:
   - The `esp_now_register_recv_cb` callback runs in the high-priority Wi-Fi task context and pushes length-prefixed frames into `xStreamBufferSendFromISR` without blocking or allocating.
3. **8MB Octal PSRAM Tensor Arena + Custom Flash Partitions (`partitions.csv`)**:
   - [`partitions.csv`](partitions.csv) defines `model` (`0x380000` for `ESP-SR MultiNet7` quantized weights), `voice_data` (`0x280000` for `ESP-TTS` memory-mapped voice fonts), and `model_data` (`0x800000` for custom INT8 DS-CNN/CTC weights packed by [`tools/pack_models.py`](tools/pack_models.py)).
4. **Trilingual (EN / JA / HU) Intent Routing, Formant Engine & SD-Card Corpus Harvester**:
   - **Node 2 (`BRAIN`)** extracts ambient RMS and Zero-Crossing Rate (`ZCR`), routes English, Japanese (`おはようオーロラ` / `環境を記録して`), and Hungarian (`Jó reggelt Aurora` / `Mentsd el a környezetet`) commands, saves 44-byte RIFF `.wav` + `dataset.jsonl` manifests to `/sdcard/corpus`, and syncs batches over Wi-Fi STA to Samsung Galaxy (`192.168.43.1:8080`), BLU (`192.168.43.102:8080`), and `http://aurora-cluster.8b.is/api/v1/ingest`.
   - **Node 3 (`MOUTH`)** synthesizes speech via a 3-formant Rosenberg-glottal + cascaded biquad resonator (`F1, F2, F3`) with Japanese mora-timed vowels and Hungarian vowel harmony (`s_trilingual_formant_lut`), or memory-mapped `ESP-TTS`.

---

## 3. Directory Tree

```text
flugos/
├── CMakeLists.txt
├── Makefile
├── partitions.csv
├── sdkconfig.defaults
├── common/
│   ├── flugos_mesh.h
│   └── flugos_mesh.c
├── main/
│   ├── CMakeLists.txt
│   ├── idf_component.yml
│   ├── Kconfig.projbuild
│   ├── main.c
│   ├── node_ear.c
│   ├── node_brain.c
│   └── node_mouth.c
├── tools/
│   ├── pack_models.py
│   └── phone_master_node.py
└── tests/
    └── test_flugos_triad_sim.c
```

---

## 4. Build, Flash & Verification Commands

### Host C11 Hardware-Exact 3-Node Simulation & Model Packer
```bash
make all
```

### Flashing the 3x ESP32-S3 Nodes (`ESP-IDF v5.3+`)
```bash
idf.py set-target esp32s3

# 1. Flash Node 1 (EAR - INMP441 I2S Mic)
idf.py -DFLUGOS_NODE_ROLE=1 -p /dev/ttyACM0 build flash monitor

# 2. Flash Node 2 (BRAIN - Octal PSRAM STT + SD Harvester)
uv run --script tools/pack_models.py --out build/model_data.bin
esptool.py --chip esp32s3 --port /dev/ttyACM1 --baud 921600 write_flash 0x790000 build/model_data.bin
idf.py -DFLUGOS_NODE_ROLE=2 -p /dev/ttyACM1 build flash monitor

# 3. Flash Node 3 (MOUTH - Trilingual Formant / ESP-TTS + MAX98357A)
idf.py -DFLUGOS_NODE_ROLE=3 -p /dev/ttyACM2 build flash monitor
```

### Running the Galaxy / BLU Phone Master Node (`Termux`)
```bash
python3 tools/phone_master_node.py
```
