#!/usr/bin/env python3
import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True)
parser.add_argument("--host", required=True)
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--max-tokens")
parser.add_argument("--advertise-model")
parser.add_argument("--advertise-ambient-cache-model")
parser.add_argument("--record-cache-root")
args = parser.parse_args()

model = str(Path(args.model).resolve())
cache_root = os.environ.get("HF_HOME", "")
if args.record_cache_root:
    Path(args.record_cache_root).write_text(cache_root, encoding="utf-8")

ambient_marker = Path(cache_root) / "poisoned-model-id" if cache_root else None
ambient_model = None
if args.advertise_ambient_cache_model and ambient_marker and ambient_marker.is_file():
    ambient_model = ambient_marker.read_text(encoding="utf-8").strip()

advertised_models = [args.advertise_model] if args.advertise_model else [model]
if ambient_model:
    advertised_models.insert(0, ambient_model)
behavior_path = Path(model) / "behavior.txt"
behavior = behavior_path.read_text(encoding="utf-8").strip()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_values):
        return

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/models":
            self._json(
                200,
                {
                    "object": "list",
                    "data": [{"id": advertised_model, "object": "model"} for advertised_model in advertised_models],
                },
            )
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        if length:
            self.rfile.read(length)

        if self.path == "/v1/chat/completions":
            content = f"[[ ## answer ## ]]\n{behavior}\n\n[[ ## completed ## ]]"
            self._json(
                200,
                {
                    "id": "fake-mlx-response",
                    "object": "chat.completion",
                    "created": 0,
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": content},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                },
            )
        else:
            self._json(404, {"error": "not found"})


ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
