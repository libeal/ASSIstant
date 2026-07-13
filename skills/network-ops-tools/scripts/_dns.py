#!/usr/bin/env python3
"""Minimal DNS stub resolver (UDP with TCP fallback) using only the stdlib.

Used as the fallback path for dns-lookup when `dig` is not installed, so that
MX/TXT/NS/SOA/CNAME/SRV/CAA lookups still work without any external tooling.
"""
import os
import socket
import struct


RECORD_TYPES = {
    "A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "PTR": 12, "MX": 15,
    "TXT": 16, "AAAA": 28, "SRV": 33, "CAA": 257, "ANY": 255,
}
TYPE_NAMES = {value: key for key, value in RECORD_TYPES.items()}
RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}


class DnsError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def encode_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        if not label:
            continue
        raw = label.encode("idna") if any(ord(char) > 127 for char in label) else label.encode("ascii", "replace")
        if len(raw) > 63:
            raise DnsError("invalid_name", "label longer than 63 octets")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def build_query(name, qtype):
    ident = int.from_bytes(os.urandom(2), "big")
    header = struct.pack("!HHHHHH", ident, 0x0100, 1, 0, 0, 0)  # RD set
    question = encode_name(name) + struct.pack("!HH", qtype, 1)
    return ident, header + question


def read_name(data, offset):
    labels = []
    jumped = False
    next_offset = offset
    visited = set()
    while True:
        if offset in visited:
            raise DnsError("invalid_response", "DNS name contains a compression pointer loop")
        visited.add(offset)
        if offset < 0 or offset >= len(data):
            raise DnsError("invalid_response", "DNS name points outside the response")
        length = data[offset]
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                raise DnsError("invalid_response", "DNS compression pointer is truncated")
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if pointer >= len(data):
                raise DnsError("invalid_response", "DNS compression pointer is outside the response")
            if not jumped:
                next_offset = offset + 2
            offset = pointer
            jumped = True
            continue
        if length & 0xC0:
            raise DnsError("invalid_response", "DNS name contains an invalid label type")
        offset += 1
        if length == 0:
            break
        if offset + length > len(data):
            raise DnsError("invalid_response", "DNS label is truncated")
        labels.append(data[offset:offset + length].decode("ascii", "replace"))
        offset += length
    return ".".join(labels), (next_offset if jumped else offset)


def parse_rdata(rtype, data, offset, rdlength):
    end = offset + rdlength
    if rtype == 1 and rdlength == 4:
        return socket.inet_ntoa(data[offset:end])
    if rtype == 28 and rdlength == 16:
        return socket.inet_ntop(socket.AF_INET6, data[offset:end])
    if rtype in (2, 5, 12):
        return read_name(data, offset)[0]
    if rtype == 15:
        preference = struct.unpack("!H", data[offset:offset + 2])[0]
        return {"preference": preference, "exchange": read_name(data, offset + 2)[0]}
    if rtype == 16:
        texts, pos = [], offset
        while pos < end:
            length = data[pos]
            pos += 1
            texts.append(data[pos:pos + length].decode("utf-8", "replace"))
            pos += length
        return "".join(texts)
    if rtype == 6:
        mname, pos = read_name(data, offset)
        rname, pos = read_name(data, pos)
        serial, refresh, retry, expire, minimum = struct.unpack("!IIIII", data[pos:pos + 20])
        return {"mname": mname, "rname": rname, "serial": serial, "refresh": refresh, "retry": retry, "expire": expire, "minimum": minimum}
    if rtype == 33:
        priority, weight, port = struct.unpack("!HHH", data[offset:offset + 6])
        return {"priority": priority, "weight": weight, "port": port, "target": read_name(data, offset + 6)[0]}
    if rtype == 257:
        flags = data[offset]
        taglen = data[offset + 1]
        tag = data[offset + 2:offset + 2 + taglen].decode("ascii", "replace")
        return {"flags": flags, "tag": tag, "value": data[offset + 2 + taglen:end].decode("ascii", "replace")}
    return data[offset:end].hex()


def parse_response(data, expected_ident=None):
    if len(data) < 12:
        raise DnsError("invalid_response", "DNS response is shorter than 12 bytes")
    ident, flags, qd, an, _ns, _ar = struct.unpack("!HHHHHH", data[:12])
    if expected_ident is not None and ident != expected_ident:
        raise DnsError("invalid_response", "DNS response ID does not match the request")
    offset = 12
    for _ in range(qd):
        _, offset = read_name(data, offset)
        offset += 4
    answers = []
    for _ in range(an):
        name, offset = read_name(data, offset)
        rtype, _rclass, ttl, rdlength = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        answers.append({"name": name, "type": TYPE_NAMES.get(rtype, str(rtype)), "ttl": ttl, "value": parse_rdata(rtype, data, offset, rdlength)})
        offset += rdlength
    return {"rcode": flags & 0x000F, "truncated": bool(flags & 0x0200), "answers": answers}


def system_resolver():
    try:
        with open("/etc/resolv.conf", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver":
                    return parts[1]
    except OSError:
        pass
    return "127.0.0.1"


def _recv_exact(sock, count):
    buffer = b""
    while len(buffer) < count:
        chunk = sock.recv(count - len(buffer))
        if not chunk:
            break
        buffer += chunk
    return buffer


def _tcp_query(family, sockaddr, packet, timeout, expected_ident):
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(sockaddr)
        sock.sendall(struct.pack("!H", len(packet)) + packet)
        length_data = _recv_exact(sock, 2)
        if len(length_data) != 2:
            raise DnsError("invalid_response", "DNS TCP response length is truncated")
        length = struct.unpack("!H", length_data)[0]
        response = _recv_exact(sock, length)
        if len(response) != length:
            raise DnsError("invalid_response", "DNS TCP response is truncated")
        return parse_response(response, expected_ident)


def query(name, rtype, server=None, port=53, timeout=3.0):
    rtype = rtype.upper()
    if rtype not in RECORD_TYPES:
        raise DnsError("unsupported_record_type", f"unsupported record type: {rtype}")
    server = server or system_resolver()
    infos = socket.getaddrinfo(server, port, socket.AF_UNSPEC, socket.SOCK_DGRAM)
    if not infos:
        raise DnsError("dns_error", f"cannot resolve DNS server {server}")
    family, _type, _proto, _canon, sockaddr = infos[0]
    ident, packet = build_query(name, RECORD_TYPES[rtype])
    try:
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(packet, sockaddr)
            data, _address = sock.recvfrom(4096)
    except socket.timeout:
        raise DnsError("timeout", "no DNS response before timeout")
    result = parse_response(data, ident)
    if result["truncated"]:
        result = _tcp_query(family, sockaddr, packet, timeout, ident)
    result["server"] = server
    result["rcode_text"] = RCODES.get(result["rcode"], str(result["rcode"]))
    return result
