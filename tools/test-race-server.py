#!/usr/bin/env python3
"""Regression test for dual-server recovery after a missing data channel."""

import socket
import sys
import threading
import time

sys.dont_write_bytecode = True

from race_server import serve_dual


def find_port_pair():
    for _ in range(100):
        first = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        first.bind(("127.0.0.1", 0))
        port = first.getsockname()[1]
        if port >= 65535:
            first.close()
            continue
        second = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            second.bind(("127.0.0.1", port + 1))
        except OSError:
            first.close()
            second.close()
            continue
        first.close()
        second.close()
        return port
    raise RuntimeError("could not reserve consecutive test ports")


def connect_retry(port, timeout=2.0):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=1.0)
        except ConnectionRefusedError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)


def recv_all(sock):
    chunks = []
    while True:
        block = sock.recv(4096)
        if not block:
            return b"".join(chunks)
        chunks.append(block)


def main():
    port = find_port_pair()
    count = 1024
    server = threading.Thread(
        target=serve_dual,
        args=("127.0.0.1", port, 32, 4000, count, 0.2),
        daemon=True,
    )
    server.start()

    # Reproduce the real failure: control connects, data never does, and the
    # client process leaves the control socket around until the server timeout.
    stale = connect_retry(port)
    stale.settimeout(2.0)
    if stale.recv(1) != b"":
        raise AssertionError("stale control was not closed")
    stale.close()

    # The next run must form a fresh pair rather than donate its data channel
    # to the stale control socket.
    ctrl = connect_retry(port)
    data = connect_retry(port + 1)
    ctrl.settimeout(2.0)
    data.settimeout(2.0)
    ctrl.sendall(b"UNETTEST DUAL CONTROL\r\n")

    payload = recv_all(data)
    expected = bytes(i & 0xFF for i in range(count))
    if payload != expected:
        raise AssertionError(f"bad data stream: got {len(payload)} bytes")
    reply = ctrl.recv(128)
    if reply != b"CONTROL REPLY DURING TRANSFER\r\n":
        raise AssertionError(f"bad control reply: {reply!r}")

    ctrl.close()
    data.close()
    print("race_server dual stale-pair recovery: OK")


if __name__ == "__main__":
    main()
