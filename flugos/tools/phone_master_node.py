#!/usr/bin/env python3
"""
FlugOS Master-Node Receiver for Samsung Galaxy & BLU Phones (Termux) and aurora-cluster.8b.is.
Ingests environmental telemetry, trilingual (EN/JA/HU) JSONL training manifests, and 16kHz WAV
recordings harvested by Node 2 (BRAIN), queuing them for Whisper/Moonshine fine-tuning.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import sys
import time

CORPUS_DIR = os.environ.get("FLUGOS_CORPUS_DIR", os.path.expanduser("~/flugos_corpus"))
os.makedirs(CORPUS_DIR, exist_ok=True)


class FlugOSIngestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/status", "/healthz"):
            log_path = os.path.join(CORPUS_DIR, "master_training_log.jsonl")
            count = 0
            if os.path.exists(log_path):
                with open(log_path, "r", encoding="utf-8") as f:
                    count = sum(1 for _ in f)
            payload = json.dumps({
                "service": "FlugOS Trilingual Master Node (EN/JA/HU)",
                "status": "online",
                "corpus_dir": CORPUS_DIR,
                "ingested_samples": count,
                "timestamp": int(time.time()),
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", errors="replace")

        if self.path in ("/ingest", "/api/v1/ingest"):
            log_path = os.path.join(CORPUS_DIR, "master_training_log.jsonl")
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(body.strip() + "\n")
            print(f"[FlugOS Master] Logged EN/JA/HU sample: {body.strip()}", flush=True)
            resp = b'{"status":"synced"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("FLUGOS_PORT", "8080"))
    print(f"FlugOS Galaxy/BLU Master Node listening on 0.0.0.0:{port} (Corpus: {CORPUS_DIR})")
    HTTPServer(("0.0.0.0", port), FlugOSIngestHandler).serve_forever()
