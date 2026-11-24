"""Minimal stdio LSP server for Eglot tests: delays `initialize', answers requests with null."""
import json
import sys
import time

delay = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
stdin, stdout = sys.stdin.buffer, sys.stdout.buffer


def read():
    length = None
    while True:
        line = stdin.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, _, value = line.decode().partition(":")
        if name.lower() == "content-length":
            length = int(value)
    return json.loads(stdin.read(length))


def send(message):
    body = json.dumps(message).encode()
    stdout.write(b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
    stdout.flush()


while (message := read()) is not None:
    method = message.get("method")
    if method == "exit":
        break
    if "id" not in message or method is None:
        continue
    if method == "initialize":
        time.sleep(delay)
        send({"jsonrpc": "2.0", "id": message["id"],
              "result": {"capabilities": {"hoverProvider": True}, "serverInfo": {"name": "fixture"}}})
    else:
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
