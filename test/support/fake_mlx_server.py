#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True)
parser.add_argument("--host", required=True)
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--max-tokens")
parser.add_argument("--advertise-model")
args = parser.parse_args()

model = str(Path(args.model).resolve())
advertised_model = args.advertise_model or model
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
            self._json(200, {"object": "list", "data": [{"id": advertised_model, "object": "model"}]})
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
