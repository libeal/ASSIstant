#!/usr/bin/env python3
"""SNMP v1/v2c/v3 client using only the Python standard library.

Supports GET / GETNEXT / GETBULK / WALK, multiple OIDs, and named-OID aliases.
SNMPv3 supports noAuthNoPriv and authNoPriv (HMAC-MD5/HMAC-SHA per RFC 3414).
authPriv (encryption) is intentionally NOT supported: the stdlib ships no DES/AES
cipher, so privacy cannot be implemented without a third-party dependency.
"""
import hashlib
import hmac
import os
import socket
import time


class SnmpError(Exception):
    def __init__(self, status, message, **extra):
        super().__init__(message)
        self.status = status
        self.message = message
        self.extra = extra


NAMED_OIDS = {
    "sysDescr": ".1.3.6.1.2.1.1.1.0",
    "sysObjectID": ".1.3.6.1.2.1.1.2.0",
    "sysUpTime": ".1.3.6.1.2.1.1.3.0",
    "sysContact": ".1.3.6.1.2.1.1.4.0",
    "sysName": ".1.3.6.1.2.1.1.5.0",
    "sysLocation": ".1.3.6.1.2.1.1.6.0",
    "sysServices": ".1.3.6.1.2.1.1.7.0",
    "ifNumber": ".1.3.6.1.2.1.2.1.0",
    "system": ".1.3.6.1.2.1.1",
    "interfaces": ".1.3.6.1.2.1.2",
    "ifTable": ".1.3.6.1.2.1.2.2",
    "ifDescr": ".1.3.6.1.2.1.2.2.1.2",
    "ifOperStatus": ".1.3.6.1.2.1.2.2.1.8",
}

VERSION_CODE = {"1": 0, "v1": 0, "2c": 1, "v2c": 1, "2": 1, "3": 3, "v3": 3}
ERROR_STATUS = {
    0: "noError", 1: "tooBig", 2: "noSuchName", 3: "badValue", 4: "readOnly",
    5: "genErr", 6: "noAccess", 7: "wrongType", 16: "authorizationError",
}

GET, GETNEXT, GETBULK, RESPONSE, REPORT = 0xA0, 0xA1, 0xA5, 0xA2, 0xA8


# --------------------------------------------------------------------------- #
# BER encoding
# --------------------------------------------------------------------------- #
def enc_len(length):
    if length < 0x80:
        return bytes([length])
    raw = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(raw)]) + raw


def tlv(tag, value):
    return bytes([tag]) + enc_len(len(value)) + value


def enc_int(value):
    raw = int(value).to_bytes(4, "big", signed=True).lstrip(b"\x00") or b"\x00"
    if raw[0] & 0x80:
        raw = b"\x00" + raw
    return tlv(0x02, raw)


def enc_octets(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return tlv(0x04, data)


def enc_null():
    return tlv(0x05, b"")


def resolve_oid(oid):
    """Map a named alias to a numeric OID, otherwise validate the dotted form."""
    text = str(oid or "").strip()
    if text in NAMED_OIDS:
        return NAMED_OIDS[text]
    if not text:
        raise SnmpError("invalid_oid", "oid is required")
    return text


def oid_to_tuple(oid):
    return tuple(int(part) for part in str(oid).strip(".").split(".") if part != "")


def enc_oid(oid):
    parts = oid_to_tuple(oid)
    if len(parts) < 2 or parts[0] > 2 or parts[1] > 39:
        raise SnmpError("invalid_oid", f"oid must be a numeric dotted OID: {oid}")
    encoded = bytes([parts[0] * 40 + parts[1]])
    for part in parts[2:]:
        if part < 0:
            raise SnmpError("invalid_oid", "oid arcs must be non-negative")
        stack = [part & 0x7F]
        part >>= 7
        while part:
            stack.append(0x80 | (part & 0x7F))
            part >>= 7
        encoded += bytes(reversed(stack))
    return tlv(0x06, encoded)


# --------------------------------------------------------------------------- #
# BER decoding
# --------------------------------------------------------------------------- #
def read_len(data, offset):
    if offset < 0 or offset >= len(data):
        raise SnmpError("invalid_response", "SNMP length is missing")
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    if count == 0 or offset + count > len(data):
        raise SnmpError("invalid_response", "SNMP length is truncated")
    return int.from_bytes(data[offset:offset + count], "big"), offset + count


def read_tlv(data, offset):
    if offset < 0 or offset >= len(data):
        raise SnmpError("invalid_response", "SNMP TLV is missing")
    tag = data[offset]
    length, value_offset = read_len(data, offset + 1)
    end = value_offset + length
    if end > len(data):
        raise SnmpError("invalid_response", "SNMP TLV is truncated")
    return tag, data[value_offset:end], end


def read_tlv_info(data, offset):
    if offset < 0 or offset >= len(data):
        raise SnmpError("invalid_response", "SNMP TLV is missing")
    tag = data[offset]
    length, value_offset = read_len(data, offset + 1)
    end = value_offset + length
    if end > len(data):
        raise SnmpError("invalid_response", "SNMP TLV is truncated")
    return tag, data[value_offset:end], value_offset, end


def dec_oid(raw):
    if not raw:
        return ""
    parts = [raw[0] // 40, raw[0] % 40]
    value = 0
    for byte in raw[1:]:
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            parts.append(value)
            value = 0
    return "." + ".".join(str(part) for part in parts)


def dec_int(raw):
    return int.from_bytes(raw, "big", signed=bool(raw and raw[0] & 0x80))


def decode_value(tag, raw):
    if tag == 0x02:
        return {"type": "integer", "value": dec_int(raw)}
    if tag == 0x04:
        return {"type": "octet_string", "value": raw.decode("utf-8", errors="replace")}
    if tag == 0x05:
        return {"type": "null", "value": None}
    if tag == 0x06:
        return {"type": "oid", "value": dec_oid(raw)}
    if tag == 0x40 and len(raw) == 4:
        return {"type": "ip_address", "value": ".".join(str(part) for part in raw)}
    if tag == 0x43:
        return {"type": "timeticks", "value": int.from_bytes(raw, "big")}
    if tag in {0x41, 0x42, 0x46}:
        return {"type": {0x41: "counter32", 0x42: "gauge32", 0x46: "counter64"}[tag], "value": int.from_bytes(raw, "big")}
    if tag in {0x80, 0x81, 0x82}:
        return {"type": {0x80: "no_such_object", 0x81: "no_such_instance", 0x82: "end_of_mib_view"}[tag], "value": None}
    return {"type": f"tag_{hex(tag)}", "hex": raw.hex()}


def parse_varbinds(varbinds_raw):
    results = []
    offset = 0
    while offset < len(varbinds_raw):
        _, vb, offset = read_tlv(varbinds_raw, offset)
        vb_offset = 0
        _, oid_raw, vb_offset = read_tlv(vb, vb_offset)
        value_tag, value_raw, _ = read_tlv(vb, vb_offset)
        results.append({"oid": dec_oid(oid_raw), "value": decode_value(value_tag, value_raw)})
    return results


# --------------------------------------------------------------------------- #
# PDU / message assembly
# --------------------------------------------------------------------------- #
def build_varbinds(oids):
    return b"".join(tlv(0x30, enc_oid(oid) + enc_null()) for oid in oids)


def build_pdu(pdu_type, request_id, oids, non_repeaters=0, max_repetitions=0):
    if pdu_type == GETBULK:
        head = enc_int(request_id) + enc_int(non_repeaters) + enc_int(max_repetitions)
    else:
        head = enc_int(request_id) + enc_int(0) + enc_int(0)
    return tlv(pdu_type, head + tlv(0x30, build_varbinds(oids)))


def build_message_v12(version_code, community, pdu):
    return tlv(0x30, enc_int(version_code) + enc_octets(community) + pdu)


def transaction(host, port, family, packet, timeout):
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        started = time.monotonic()
        destination = (host, port, 0, 0) if family == socket.AF_INET6 else (host, port)
        sock.sendto(packet, destination)
        data, address = sock.recvfrom(65535)
    return data, address, round((time.monotonic() - started) * 1000, 2)


def validate_oid_limit(oids, max_oids):
    if max_oids < 1:
        raise SnmpError("invalid_limit", "max_oids must be at least 1")
    if len(oids) > max_oids:
        raise SnmpError("too_many_oids", f"at most {max_oids} OIDs are allowed", oid_count=len(oids))


def parse_message_v12(data):
    _, top, _ = read_tlv(data, 0)
    offset = 0
    _, version_raw, offset = read_tlv(top, offset)
    _, _community_raw, offset = read_tlv(top, offset)
    pdu_tag, pdu, _ = read_tlv(top, offset)
    pdu_offset = 0
    _, request_id_raw, pdu_offset = read_tlv(pdu, pdu_offset)
    _, error_status_raw, pdu_offset = read_tlv(pdu, pdu_offset)
    _, error_index_raw, pdu_offset = read_tlv(pdu, pdu_offset)
    _, varbinds_raw, _ = read_tlv(pdu, pdu_offset)
    error_status = dec_int(error_status_raw)
    return {
        "version": dec_int(version_raw) + 1,
        "pdu_tag": hex(pdu_tag),
        "request_id": dec_int(request_id_raw),
        "error_status": error_status,
        "error_text": ERROR_STATUS.get(error_status, str(error_status)),
        "error_index": dec_int(error_index_raw),
        "varbinds": parse_varbinds(varbinds_raw),
    }


# --------------------------------------------------------------------------- #
# SNMPv3 (USM, noAuthNoPriv / authNoPriv)
# --------------------------------------------------------------------------- #
def password_to_key(password, engine_id, hash_name):
    digest = hashlib.new(hash_name)
    pw = password.encode("utf-8")
    megabyte = 1048576
    reps, tail = divmod(megabyte, len(pw))
    digest.update(pw * reps + pw[:tail])
    ku = digest.digest()
    localized = hashlib.new(hash_name)
    localized.update(ku + engine_id + ku)
    return localized.digest()


def build_v3_message(msg_id, engine_id, boots, etime, user, auth_key, hash_name, scoped_pdu, want_auth):
    flags = 0x04 | (0x01 if want_auth else 0x00)  # reportable (+auth)
    header = tlv(0x30, enc_int(msg_id) + enc_int(65507) + enc_octets(bytes([flags])) + enc_int(3))
    auth_placeholder = b"\x00" * 12 if want_auth else b""
    sec_params = tlv(
        0x30,
        enc_octets(engine_id) + enc_int(boots) + enc_int(etime)
        + enc_octets(user) + enc_octets(auth_placeholder) + enc_octets(b""),
    )
    message = tlv(0x30, enc_int(3) + header + enc_octets(sec_params) + scoped_pdu)
    if not want_auth:
        return message
    marker = b"\x04\x0c" + auth_placeholder
    sp_index = message.find(sec_params)
    rel = sec_params.find(marker)
    auth_offset = sp_index + rel + 2
    digest = hmac.new(auth_key, message, hash_name).digest()[:12]
    return message[:auth_offset] + digest + message[auth_offset + 12:]


def build_scoped_pdu(context_engine_id, pdu):
    return tlv(0x30, enc_octets(context_engine_id) + enc_octets(b"") + pdu)


def parse_v3_security(data):
    _, top, top_value_offset, _ = read_tlv_info(data, 0)
    offset = 0
    _, _version, _, offset = read_tlv_info(top, offset)          # msgVersion
    _, _header, _, offset = read_tlv_info(top, offset)           # msgGlobalData
    sec_tag, sec_octets, sec_value_offset, offset = read_tlv_info(top, offset)  # msgSecurityParameters
    if sec_tag != 0x04:
        raise SnmpError("invalid_response", "SNMPv3 security parameters are not an OCTET STRING")
    data_tag, scoped, _, _ = read_tlv_info(top, offset)           # msgData
    if data_tag != 0x30:
        raise SnmpError("unsupported", "encrypted SNMPv3 scoped PDU is not supported (authPriv)")
    sp_offset = 0
    seq_tag, sp_seq, seq_value_offset, _ = read_tlv_info(sec_octets, sp_offset)
    if seq_tag != 0x30:
        raise SnmpError("invalid_response", "SNMPv3 security parameters are not a sequence")
    inner = 0
    fields = []
    auth_offset = None
    while inner < len(sp_seq):
        tag, raw, value_offset, inner = read_tlv_info(sp_seq, inner)
        fields.append((tag, raw))
        if len(fields) == 5:
            auth_offset = top_value_offset + sec_value_offset + seq_value_offset + value_offset
    if len(fields) < 6:
        raise SnmpError("invalid_response", "SNMPv3 security parameters are incomplete")
    return {
        "engine_id": fields[0][1],
        "boots": dec_int(fields[1][1]),
        "time": dec_int(fields[2][1]),
        "user": fields[3][1].decode("utf-8", errors="replace"),
        "auth_params": fields[4][1],
        "auth_offset": auth_offset,
        "scoped": scoped,
    }


def verify_v3_auth(data, security, auth_key, hash_name):
    if not auth_key:
        return
    auth_params = security.get("auth_params") or b""
    auth_offset = security.get("auth_offset")
    if len(auth_params) != 12 or auth_offset is None:
        raise SnmpError("auth_failed", "SNMPv3 response does not contain valid authentication parameters")
    if auth_offset + len(auth_params) > len(data):
        raise SnmpError("auth_failed", "SNMPv3 response authentication offset is invalid")
    unsigned = bytearray(data)
    unsigned[auth_offset:auth_offset + len(auth_params)] = b"\x00" * len(auth_params)
    expected = hmac.new(auth_key, bytes(unsigned), hash_name).digest()[:12]
    if not hmac.compare_digest(expected, auth_params):
        raise SnmpError("auth_failed", "SNMPv3 response authentication failed")


def parse_v3_varbinds(scoped):
    offset = 0
    _, _context_engine, offset = read_tlv(scoped, offset)
    _, _context_name, offset = read_tlv(scoped, offset)
    pdu_tag, pdu, _ = read_tlv(scoped, offset)
    pdu_offset = 0
    _, request_id_raw, pdu_offset = read_tlv(pdu, pdu_offset)
    _, error_status_raw, pdu_offset = read_tlv(pdu, pdu_offset)
    _, _error_index_raw, pdu_offset = read_tlv(pdu, pdu_offset)
    _, varbinds_raw, _ = read_tlv(pdu, pdu_offset)
    return pdu_tag, dec_int(request_id_raw), dec_int(error_status_raw), parse_varbinds(varbinds_raw)


def v3_discover(host, port, family, timeout):
    msg_id = int.from_bytes(os.urandom(3), "big")
    pdu = build_pdu(GET, msg_id, [])
    scoped = build_scoped_pdu(b"", pdu)
    packet = build_v3_message(msg_id, b"", 0, 0, "", b"", "md5", scoped, want_auth=False)
    data, _address, _latency = transaction(host, port, family, packet, timeout)
    security = parse_v3_security(data)
    return security["engine_id"], security["boots"], security["time"]


def snmp_v3_request(host, port, family, oids, action, timeout, v3, non_repeaters, max_repetitions):
    hash_name = {"md5": "md5", "sha": "sha1", "sha1": "sha1"}.get(str(v3.get("auth_protocol") or "sha").lower())
    if hash_name is None:
        raise SnmpError("invalid_auth", "auth_protocol must be md5 or sha")
    user = str(v3.get("user") or "")
    if not user:
        raise SnmpError("missing_user", "snmp v3 requires a user")
    password = str(v3.get("auth_password") or "")
    want_auth = bool(password)
    engine_id, boots, etime = v3_discover(host, port, family, timeout)
    auth_key = password_to_key(password, engine_id, hash_name) if want_auth else b""
    pdu_type = {"get": GET, "getnext": GETNEXT, "bulk": GETBULK}.get(action, GET)
    msg_id = int.from_bytes(os.urandom(3), "big")
    pdu = build_pdu(pdu_type, msg_id, oids, non_repeaters, max_repetitions)
    scoped = build_scoped_pdu(engine_id, pdu)
    packet = build_v3_message(msg_id, engine_id, boots, etime, user, auth_key, hash_name, scoped, want_auth)
    data, address, latency = transaction(host, port, family, packet, timeout)
    security = parse_v3_security(data)
    if security["engine_id"] != engine_id:
        raise SnmpError("auth_failed", "SNMPv3 response engine ID does not match the discovered engine")
    if security["user"] != user:
        raise SnmpError("auth_failed", "SNMPv3 response user does not match the request")
    verify_v3_auth(data, security, auth_key, hash_name)
    _pdu_tag, request_id, error_status, varbinds = parse_v3_varbinds(security["scoped"])
    if request_id != msg_id:
        raise SnmpError("invalid_response", "SNMPv3 response request ID does not match the request")
    return {
        "version": 3,
        "security_level": "authNoPriv" if want_auth else "noAuthNoPriv",
        "engine_id": engine_id.hex(),
        "engine_boots": boots,
        "error_status": error_status,
        "error_text": ERROR_STATUS.get(error_status, str(error_status)),
        "varbinds": varbinds,
    }, address, latency


# --------------------------------------------------------------------------- #
# High-level operations
# --------------------------------------------------------------------------- #
def snmp_walk(host, port, family, version_code, community, base_oid, timeout, max_oids, v3=None):
    base = oid_to_tuple(base_oid)
    current = base_oid
    collected = []
    seen = set()
    latency = None
    address = None
    while len(collected) < max_oids:
        if version_code == 3:
            parsed, address, latency = snmp_v3_request(host, port, family, [current], "getnext", timeout, v3, 0, 0)
            varbinds = parsed["varbinds"]
        else:
            request_id = int.from_bytes(os.urandom(3), "big")
            pdu = build_pdu(GETNEXT, request_id, [current])
            packet = build_message_v12(version_code, community, pdu)
            data, address, latency = transaction(host, port, family, packet, timeout)
            parsed = parse_message_v12(data)
            if parsed["request_id"] != request_id:
                raise SnmpError("invalid_response", "SNMP response request ID does not match the request")
            varbinds = parsed["varbinds"]
        if not varbinds:
            break
        entry = varbinds[0]
        oid = entry["oid"]
        value_type = entry["value"].get("type")
        if value_type in {"end_of_mib_view", "no_such_object", "no_such_instance"}:
            break
        oid_tuple = oid_to_tuple(oid)
        if oid_tuple[:len(base)] != base or oid in seen:
            break
        seen.add(oid)
        collected.append(entry)
        current = oid
    return collected, address, latency


def snmp_execute(params):
    host = params["host"]
    port = params["port"]
    family = params["family"]
    version = str(params.get("version") or "2c").lower()
    if version not in VERSION_CODE:
        raise SnmpError("invalid_version", "version must be 1, 2c, or 3")
    version_code = VERSION_CODE[version]
    community = str(params.get("community") or "public")
    action = str(params.get("action") or "get").lower()
    if action not in {"get", "getnext", "walk", "bulk"}:
        raise SnmpError("invalid_action", "action must be get, getnext, walk, or bulk")
    if action == "bulk" and version_code == 0:
        raise SnmpError("unsupported", "getbulk requires SNMP v2c or v3")
    timeout = params["timeout"]
    oids = [resolve_oid(item) for item in params["oids"]]
    if not oids:
        raise SnmpError("invalid_oid", "at least one oid is required")
    try:
        max_oids = int(params.get("max_oids", 64))
    except (TypeError, ValueError):
        raise SnmpError("invalid_limit", "max_oids must be an integer")
    validate_oid_limit(oids, max_oids)

    if action == "walk":
        collected, address, latency = snmp_walk(host, port, family, version_code, community, oids[0], timeout, max_oids, params.get("v3"))
        return {"version": version, "action": "walk", "base_oid": oids[0], "count": len(collected), "varbinds": collected}, address, latency

    if version_code == 3:
        parsed, address, latency = snmp_v3_request(
            host, port, family, oids, action, timeout, params.get("v3") or {},
            params.get("non_repeaters", 0), params.get("max_repetitions", 10),
        )
        parsed["action"] = action
        return parsed, address, latency

    pdu_type = {"get": GET, "getnext": GETNEXT, "bulk": GETBULK}[action]
    request_id = int.from_bytes(os.urandom(3), "big")
    pdu = build_pdu(pdu_type, request_id, oids, params.get("non_repeaters", 0), params.get("max_repetitions", 10))
    packet = build_message_v12(version_code, community, pdu)
    data, address, latency = transaction(host, port, family, packet, timeout)
    parsed = parse_message_v12(data)
    if parsed["request_id"] != request_id:
        raise SnmpError("invalid_response", "SNMP response request ID does not match the request")
    parsed["action"] = action
    return parsed, address, latency
