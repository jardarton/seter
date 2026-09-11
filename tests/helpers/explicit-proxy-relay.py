import select
import socket
import threading

def relay(client):
    with client:
        request = b""
        while b"\r\n\r\n" not in request and len(request) < 16384:
            chunk = client.recv(4096)
            if not chunk:
                return
            request += chunk
        if not request.startswith(b"CONNECT proxy-e2e.example:443 HTTP/"):
            client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        with socket.create_connection(("127.0.0.1", 8443)) as upstream:
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            sockets = [client, upstream]
            while True:
                readable, _, _ = select.select(sockets, [], [], 10)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    destination = upstream if source is client else client
                    destination.sendall(data)

with socket.create_server(("0.0.0.0", 18081), reuse_port=True) as listener:
    while True:
        client, _ = listener.accept()
        threading.Thread(target=relay, args=(client,), daemon=True).start()
