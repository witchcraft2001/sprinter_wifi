#!/usr/bin/env python3
"""Race server for RACETEST.EXE - provokes the SEND-during-race defer path.

It streams a single, continuous, incrementing byte sequence (0,1,2,...,255,0,...)
to the connected client as fast as the link accepts it. Because the stream never
pauses, whenever the Sprinter client is mid-CIPSEND (between the '>' prompt and
"SEND OK") peer bytes are queued in the ESP - exactly the window the UNETESP
receive-defer buffer must capture. RACETEST checks that the bytes it receives
form an unbroken increasing sequence; if the defer path dropped or reordered a
byte, continuity breaks and the test fails.

The byte VALUE is a global counter mod 256, independent of chunk/packet
boundaries, so the client only has to verify each byte == previous+1 (mod 256).

TCP (default) gives a reliable ordered stream, so any gap the client sees is a
real defer bug (or a flagged overflow). UDP flood mode is provided too, but the
network itself may drop/reorder datagrams, so it is a stress mode, not a strict
continuity oracle.

Examples:
    ./race_server.py                       # TCP, 0.0.0.0:9099, full speed
    ./race_server.py --port 9099 --rate 20000   # ~20 KB/s paced
    ./race_server.py --udp --port 9100     # UDP flood (client must send first)
    ./race_server.py --dual --port 9099    # two channels for UNETTEST -2
                                           # (control 9099, data 9100)
"""

import argparse
import socket
import sys
import time


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def make_chunk(counter, size):
    """Return `size` bytes continuing the global counter, and the new counter."""
    b = bytes((counter + i) & 0xFF for i in range(size))
    return b, (counter + size) & 0xFF


def serve_tcp(host, port, chunk, rate):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    log(f"TCP race server on {host}:{port} (chunk={chunk}, "
        f"rate={'full' if not rate else str(rate) + ' B/s'}) - waiting...")

    while True:
        conn, addr = srv.accept()
        log(f"client connected: {addr[0]}:{addr[1]} - streaming")
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        counter = 0
        sent = 0
        t0 = time.time()
        try:
            while True:
                data, counter = make_chunk(counter, chunk)
                conn.sendall(data)
                sent += len(data)
                # Drain and discard anything the client sends; we ignore it, but
                # not reading would eventually stall its SENDs behind a full
                # kernel buffer.
                _drain(conn)
                if rate:
                    _pace(sent, t0, rate)
        except (ConnectionResetError, BrokenPipeError, OSError) as e:
            log(f"client gone ({e.__class__.__name__}); streamed {sent} bytes")
        finally:
            conn.close()


def _drain(conn):
    conn.setblocking(False)
    try:
        while True:
            if not conn.recv(4096):
                break
    except (BlockingIOError, InterruptedError):
        pass
    except OSError:
        pass
    finally:
        conn.setblocking(True)


def _pace(sent, t0, rate):
    target = t0 + sent / rate
    now = time.time()
    if target > now:
        time.sleep(target - now)


def serve_udp(host, port, chunk, rate):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    log(f"UDP race server on {host}:{port} - waiting for the client's first "
        f"datagram to learn its address...")
    srv.settimeout(None)
    _, peer = srv.recvfrom(2048)
    log(f"client is {peer[0]}:{peer[1]} - flooding datagrams")

    counter = 0
    sent = 0
    t0 = time.time()
    # Keep draining any further client packets without blocking the flood.
    srv.settimeout(0)
    try:
        while True:
            data, counter = make_chunk(counter, chunk)
            try:
                srv.sendto(data, peer)
                sent += len(data)
            except BlockingIOError:
                pass
            try:
                srv.recvfrom(2048)
            except (BlockingIOError, InterruptedError, OSError):
                pass
            if rate:
                _pace(sent, t0, rate)
    except KeyboardInterrupt:
        log(f"stopped; sent {sent} bytes")


def serve_dual(host, port, chunk, rate, count):
    """Two-channel peer for UNETTEST -2 (see docs/UNETTEST.TXT).

    Control socket on `port`: echoes whatever the client sends, but only after
    the data transfer is well under way, so the reply lands in the middle of the
    data stream - the case a single-channel backend loses.
    Data socket on `port + 1`: streams `count` counter bytes, then closes, which
    is how an FTP server signals end of transfer on the data connection.
    """
    ctrl_srv = _listener(host, port)
    data_srv = _listener(host, port + 1)
    log(f"dual-channel server: control {host}:{port}, data {host}:{port + 1} "
        f"({count} bytes, chunk={chunk}, "
        f"rate={'full' if not rate else str(rate) + ' B/s'}) - waiting...")

    while True:
        ctrl, addr = ctrl_srv.accept()
        ctrl.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        log(f"control connected: {addr[0]}:{addr[1]}")
        data, addr = data_srv.accept()
        data.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        log(f"data connected: {addr[0]}:{addr[1]} - streaming")

        counter = 0
        sent = 0
        pending = b""
        replied = False
        t0 = time.time()
        ctrl.setblocking(False)
        try:
            while sent < count:
                block, counter = make_chunk(counter, min(chunk, count - sent))
                data.sendall(block)
                sent += len(block)
                try:
                    pending += ctrl.recv(4096)
                except (BlockingIOError, InterruptedError):
                    pass
                # Answer once the transfer is properly in flight.
                if pending and not replied and sent >= count // 2:
                    ctrl.sendall(b"CONTROL REPLY DURING TRANSFER\r\n")
                    replied = True
                    log(f"control reply sent after {sent} data bytes")
                if rate:
                    _pace(sent, t0, rate)
            data.close()
            log(f"data closed after {sent} bytes")
            if not replied:
                ctrl.sendall(b"CONTROL REPLY AFTER TRANSFER\r\n")
                log("control reply sent after the transfer")
            # Give the client time to drain and close.
            time.sleep(3)
        except (ConnectionResetError, BrokenPipeError, OSError) as e:
            log(f"client gone ({e.__class__.__name__}); streamed {sent} bytes")
        finally:
            for s in (ctrl, data):
                try:
                    s.close()
                except OSError:
                    pass


def _listener(host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    return srv


def main():
    ap = argparse.ArgumentParser(description="Race server for RACETEST.EXE")
    ap.add_argument("--host", default="0.0.0.0", help="bind address (default 0.0.0.0)")
    ap.add_argument("--port", type=int, default=9099, help="port (default 9099)")
    ap.add_argument("--udp", action="store_true", help="UDP flood mode (default TCP)")
    ap.add_argument("--dual", action="store_true",
                    help="two-channel mode for UNETTEST -2: control on --port, "
                         "data on --port+1. The data socket streams --count "
                         "bytes and closes; the control socket replies in the "
                         "middle of the transfer.")
    ap.add_argument("--count", type=int, default=8192,
                    help="bytes to stream on the data channel in --dual mode "
                         "(default 8192)")
    ap.add_argument("--chunk", type=int, default=None,
                    help="bytes per send (default 128)")
    ap.add_argument("--rate", type=int, default=4000,
                    help="throttle to this many bytes/sec (default 4000). Must "
                         "stay well below the UART line rate so RACETEST can "
                         "out-drain the stream between SENDs; also keeps <2 KB "
                         "per SEND window so the defer buffer never overflows.")
    ap.add_argument("--full", action="store_true",
                    help="stream at full speed (no pacing). Overwhelms the ESP: "
                         "the CIPSEND handshake can stall and the defer buffer "
                         "overflows every send - use only for overflow stress.")
    args = ap.parse_args()

    chunk = args.chunk if args.chunk else 128
    if chunk < 1:
        ap.error("--chunk must be >= 1")
    rate = 0 if args.full else args.rate

    if args.dual and args.udp:
        ap.error("--dual and --udp are mutually exclusive")
    if args.count < 1:
        ap.error("--count must be >= 1")

    try:
        if args.dual:
            serve_dual(args.host, args.port, chunk, rate, args.count)
        elif args.udp:
            serve_udp(args.host, args.port, chunk, rate)
        else:
            serve_tcp(args.host, args.port, chunk, rate)
    except KeyboardInterrupt:
        log("interrupted")


if __name__ == "__main__":
    main()
