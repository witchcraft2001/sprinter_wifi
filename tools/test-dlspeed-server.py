#!/usr/bin/env python3

import http.client
import importlib.util
import pathlib
import sys
import threading

sys.dont_write_bytecode = True

path = pathlib.Path(__file__).with_name("dlspeed_server.py")
spec = importlib.util.spec_from_file_location("dlspeed_server", path)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.DLSpeedHandler.payload_count = 12345
server = module.ThreadingHTTPServer(("127.0.0.1", 0), module.DLSpeedHandler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
    connection.request("GET", "/test.bin", headers={"Accept-Encoding": "identity"})
    response = connection.getresponse()
    body = response.read()
    assert response.status == 200
    assert response.version == 11
    assert response.getheader("Content-Length") == "12345"
    assert response.getheader("Connection") == "keep-alive"
    assert len(body) == 12345
    assert body[:260] == bytes(range(256)) + bytes(range(4))
    connection.close()
finally:
    server.shutdown()
    server.server_close()
    thread.join()

print("DLSPEED HTTP server: OK")
