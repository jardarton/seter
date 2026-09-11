import pathlib
import socket
import sys

address, port, marker = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3])
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
    listener.bind((address, port))
    payload, peer = listener.recvfrom(65535)
marker.write_bytes(payload + b"\n" + repr(peer).encode())
