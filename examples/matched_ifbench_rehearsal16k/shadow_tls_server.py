#!/usr/bin/env python3
"""Deterministic local TLS/OpenAI surface for credential-free peer shadowing."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import ssl
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


def atomic_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, required=True)
    args = parser.parse_args()

    temporary = tempfile.TemporaryDirectory(prefix="imp-ifbench-shadow-tls-")
    root = Path(temporary.name)
    ca_key = root / "ca-key.pem"
    ca_cert = root / "ca-cert.pem"
    key = root / "server-key.pem"
    request = root / "server.csr"
    cert = root / "server-cert.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(ca_key),
            "-out",
            str(ca_cert),
            "-days",
            "1",
            "-subj",
            "/CN=Imp Shadow CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(key),
            "-out",
            str(request),
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(request),
            "-CA",
            str(ca_cert),
            "-CAkey",
            str(ca_key),
            "-CAcreateserial",
            "-out",
            str(cert),
            "-days",
            "1",
            "-copy_extensions",
            "copy",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    ledger: list[dict[str, Any]] = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            return

        def send_json(self, status: int, value: Any) -> None:
            body = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def record(self, method: str, body: bytes = b"") -> None:
            parsed = json.loads(body) if body else None
            ledger.append(
                {
                    "method": method,
                    "path": self.path,
                    "body_sha256": hashlib.sha256(body).hexdigest(),
                    "model": parsed.get("model") if isinstance(parsed, dict) else None,
                    "authorization_present": "authorization" in {
                        name.lower() for name in self.headers
                    },
                    "tls_version": self.connection.version(),
                }
            )
            atomic_write(args.ledger, {"requests": ledger})

        def do_GET(self) -> None:  # noqa: N802
            self.record("GET")
            if self.path == "/health":
                self.send_json(200, {"status": "ready"})
                return
            if self.path.endswith("/models/openai/gpt-5.4-mini/endpoints"):
                self.send_json(
                    200,
                    {
                        "data": {
                            "endpoints": [
                                {
                                    "provider_name": "OpenAI",
                                    "tag": "openai",
                                    "pricing": {
                                        "prompt": "0.00000075",
                                        "completion": "0.0000045",
                                    },
                                    "supported_parameters": [
                                        "max_tokens",
                                        "seed",
                                        "response_format",
                                    ],
                                }
                            ]
                        }
                    },
                )
                return
            if self.path.endswith("/models/anthropic/claude-sonnet-4.6/endpoints"):
                self.send_json(
                    200,
                    {
                        "data": {
                            "endpoints": [
                                {
                                    "provider_name": "Anthropic",
                                    "tag": "anthropic",
                                    "pricing": {
                                        "prompt": "0.000003",
                                        "completion": "0.000015",
                                    },
                                    "supported_parameters": ["max_tokens", "temperature"],
                                }
                            ]
                        }
                    },
                )
                return
            self.send_json(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("content-length", "0"))
            body = self.rfile.read(length)
            self.record("POST", body)
            request = json.loads(body)
            model = request.get("model", "shadow")
            content = (
                "[[ ## proposed_instruction ## ]]\nshadow optimizer\n\n"
                "[[ ## completed ## ]]"
                if "optimizer" in str(model) or "claude" in str(model)
                else '{"answer":"shadow-task-ok"}'
            )
            self.send_json(
                200,
                {
                    "id": f"shadow-{len(ledger)}",
                    "object": "chat.completion",
                    "created": 1,
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": content},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 8,
                        "completion_tokens": 8,
                        "total_tokens": 16,
                        "cost": 0.0,
                    },
                },
            )

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    port = server.server_address[1]
    atomic_write(
        args.ready,
        {
            "base_url": f"https://127.0.0.1:{port}",
            "ca_cert": str(ca_cert),
            "pid": os.getpid(),
        },
    )

    def stop(_signal: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        atomic_write(args.ledger, {"requests": ledger, "status": "stopped"})
        temporary.cleanup()


if __name__ == "__main__":
    main()
