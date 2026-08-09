#!/usr/bin/env python3
"""Deterministic HTTP/1.1 keep-alive payload source for DLSPEED."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class DLSpeedHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    payload_count = 512 * 1024
    write_chunk = 16 * 1024

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/test.bin":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(self.payload_count))
        self.send_header("Content-Encoding", "identity")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        block = bytes(range(256)) * (self.write_chunk // 256)
        left = self.payload_count
        while left:
            piece = block[: min(left, len(block))]
            self.wfile.write(piece)
            left -= len(piece)
        self.wfile.flush()
        self.close_connection = False

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.client_address[0]} - {fmt % args}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--count", type=int, default=512 * 1024)
    parser.add_argument("--chunk", type=int, default=16 * 1024)
    args = parser.parse_args()
    if args.count <= 0:
        parser.error("--count must be positive")
    if args.chunk <= 0 or args.chunk % 256:
        parser.error("--chunk must be a positive multiple of 256")
    return args


def main() -> None:
    args = parse_args()
    DLSpeedHandler.payload_count = args.count
    DLSpeedHandler.write_chunk = args.chunk
    server = ThreadingHTTPServer((args.bind, args.port), DLSpeedHandler)
    host, port = server.server_address[:2]
    print(f"DLSPEED source: http://{host}:{port}/test.bin ({args.count} bytes)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
