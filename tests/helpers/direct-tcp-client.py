import pathlib
import socket
import time

ready = pathlib.Path("/tmp/seter-direct-client-ready")
send = pathlib.Path("/tmp/seter-direct-client-send")
blocked = pathlib.Path("/tmp/seter-direct-client-blocked")
allowed = pathlib.Path("/tmp/seter-direct-client-allowed")

with socket.create_connection(("11.0.0.2", 2222), timeout=5) as connection:
    ready.touch()
    for _ in range(200):
        if send.exists():
            break
        time.sleep(0.05)
    else:
        raise SystemExit("timed out waiting for the revocation test")

    connection.settimeout(2)
    try:
        connection.sendall(b"after revocation\n")
        response = connection.recv(1024)
        if response:
            allowed.write_bytes(response)
        else:
            blocked.touch()
    except (OSError, TimeoutError):
        blocked.touch()
