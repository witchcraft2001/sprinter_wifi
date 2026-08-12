#!/usr/bin/env python3
"""Deterministic HTTP/1.1 keep-alive payload source for DLSPEED."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class DLSpeedHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    payload_count = 512 * 1024
    write_chunk = 16 * 1024

    def range_start(self) -> int | None:
        value = self.headers.get("Range")
        if value is None:
            return None
        prefix = "bytes="
        if not value.startswith(prefix) or not value.endswith("-"):
            return -1
        start_text = value[len(prefix) : -1]
        if not start_text.isdecimal():
            return -1
        start = int(start_text)
        if start < 0 or start >= self.payload_count:
            return -1
        return start

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/test.bin":
            self.send_error(404)
            return
        start = self.range_start()
        if start == -1:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{self.payload_count}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body_start = 0 if start is None else start
        body_count = self.payload_count - body_start
        self.send_response(200 if start is None else 206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(body_count))
        if start is not None:
            self.send_header(
                "Content-Range",
                f"bytes {body_start}-{self.payload_count - 1}/{self.payload_count}",
            )
        self.send_header("Content-Encoding", "identity")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        # One extra pattern period lets a resumed response begin at any byte
        # offset while retaining the same deterministic 0..255 sequence.
        block = bytes(range(256)) * (self.write_chunk // 256 + 1)
        pattern_offset = body_start & 0xFF
        left = body_count
        sent = 0
        try:
            while left:
                piece_len = min(left, self.write_chunk)
                piece = block[pattern_offset : pattern_offset + piece_len]
                self.wfile.write(piece)
                sent += len(piece)
                left -= len(piece)
            self.wfile.flush()
        except OSError as exc:
            # This line is deliberately emitted by the reproducible benchmark
            # server: it distinguishes an application/server-side truncation
            # from a downstream TCP/ESP/UART stall seen only by DLSPEED.
            self.log_message(
                "send stopped after %d/%d bytes: %s",
                sent,
                body_count,
                exc,
            )
            self.close_connection = True
            return
        self.log_message(
            "sent %d/%d bytes from offset %d; keeping connection open",
            sent,
            body_count,
            body_start,
        )
        self.close_connection = False

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.client_address[0]} - {fmt % args}", flush=True)


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
    print(
        f"DLSPEED source: http://{host}:{port}/test.bin ({args.count} bytes)",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
