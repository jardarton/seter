import socket
import struct
import sys

import dns.edns
import dns.flags
import dns.message
import dns.name
import dns.opcode
import dns.query
import dns.rcode
import dns.rdataclass
import dns.rdatatype
import dns.rrset

server = sys.argv[1]

def udp(query):
    return dns.query.udp(query, server, timeout=2)

def assert_refused(query):
    response = udp(query)
    assert response.rcode() == dns.rcode.REFUSED, response

def udp_unchecked(wire):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        sock.sendto(wire, (server, 53))
        response, _ = sock.recvfrom(4096)
    return dns.message.from_wire(response)

mixed_case = dns.message.make_query("AlLoWeD.ExAmPlE.", "A")
response = udp(mixed_case)
assert response.rcode() == dns.rcode.NOERROR
assert [item.address for rrset in response.answer for item in rrset if item.rdtype == dns.rdatatype.A] == ["11.0.0.2"]
assert response.question[0].name.to_text() == "AlLoWeD.ExAmPlE."

tcp_response = dns.query.tcp(mixed_case, server, timeout=2)
assert tcp_response.rcode() == dns.rcode.NOERROR

aaaa = udp(dns.message.make_query("allowed.example.", "AAAA"))
assert aaaa.rcode() == dns.rcode.NOERROR
assert not aaaa.answer

assert_refused(dns.message.make_query("child.allowed.example.", "A"))
assert_refused(dns.message.make_query("allowed.example.", "TXT"))
assert_refused(
    dns.message.make_query(
        "allowed.example.", "A", rdclass=dns.rdataclass.CH
    )
)

multiple = dns.message.Message()
multiple.flags |= dns.flags.RD
multiple.question.append(
    dns.rrset.RRset(
        dns.name.from_text("allowed.example."),
        dns.rdataclass.IN,
        dns.rdatatype.A,
    )
)
multiple.question.append(
    dns.rrset.RRset(
        dns.name.from_text("denied.example."),
        dns.rdataclass.IN,
        dns.rdatatype.A,
    )
)
assert_refused(multiple)

additional = dns.message.make_query("allowed.example.", "A")
additional.additional.append(
    dns.rrset.from_text(
        "covert.example.", 60, "IN", "TXT", '"must-not-be-forwarded"'
    )
)
assert_refused(additional)

# EDNS is accepted for client compatibility, but the frontend rebuilds
# the upstream request and emits a plain response with no reflected
# option or client-controlled payload.
edns = dns.message.make_query(
    "allowed.example.",
    "A",
    use_edns=0,
    payload=4096,
    options=[dns.edns.GenericOption(65001, b"must-not-be-forwarded")],
)
edns_response = udp(edns)
assert edns_response.rcode() == dns.rcode.NOERROR
assert edns_response.edns < 0

update = dns.message.make_query("allowed.example.", "A")
update.set_opcode(dns.opcode.UPDATE)
assert udp_unchecked(update.to_wire()).rcode() in (
    dns.rcode.FORMERR,
    dns.rcode.REFUSED,
)

response_packet = dns.message.make_query("allowed.example.", "A")
response_packet.flags |= dns.flags.QR
assert udp_unchecked(response_packet.to_wire()).rcode() == dns.rcode.REFUSED

# A parseable header claiming one question but omitting it receives
# FORMERR and cannot reach the backend.
malformed = struct.pack("!HHHHHH", 0x5151, dns.flags.RD, 1, 0, 0, 0)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(2)
    sock.sendto(malformed, (server, 53))
    wire, _ = sock.recvfrom(512)
malformed_response = dns.message.from_wire(wire)
assert malformed_response.id == 0x5151
assert malformed_response.rcode() == dns.rcode.FORMERR
