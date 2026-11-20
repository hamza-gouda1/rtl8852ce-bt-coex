#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""hci-cmd.py — verified HCI command sender for bt-afh-guard.

`hcitool cmd` exits 0 even when the controller rejects the command; the real
decision arrives in the Command Complete event's status byte. This helper sends
one raw HCI command on an AF_BLUETOOTH/BTPROTO_HCI socket, waits (bounded) for
the Command Complete / Command Status event for that exact opcode, and makes
the controller's verdict its exit code, so callers can trust success.

stdout:
    status 0xNN            (the verified status byte; always printed when the
                            controller answered)
    <return parameters as space-separated 0xNN hex tokens>
stderr: diagnostics
exit:   the HCI status byte (0 = accepted, 1..255 rejected), or 255 when the
        command could not be transported at all (no controller, down, timeout).

stdlib only; no bluez python bindings. Requires root for raw HCI access.

Examples:
    hci-cmd.py 0x03 0x003F 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0x7F
    hci-cmd.py --hci hci0 0x05 0x0006 0x04 0x00     # Read AFH Channel Map, handle 4
    hci-cmd.py --list-conns                          # enumerate ACL connections
"""

import argparse
import fcntl
import socket
import struct
import sys
import time

HCI_COMMAND_PKT = 0x01
HCI_EVENT_PKT = 0x04
EVT_CMD_COMPLETE = 0x0E
EVT_CMD_STATUS = 0x0F

# A raw HCI socket delivers nothing until a filter is installed (the kernel
# starts every socket with an all-zero type mask). struct hci_ufilter is
# { __u32 type_mask; __u32 event_mask[2]; __u16 opcode; } and sizeof() is 16
# because of tail padding; a 14-byte option is rejected with EINVAL.
SOL_HCI = getattr(socket, "SOL_HCI", 0)
HCI_FILTER = getattr(socket, "HCI_FILTER", 2)
CMD_EVENT_FILTER = struct.pack(
    "<IIIH2x", 1 << HCI_EVENT_PKT, (1 << EVT_CMD_COMPLETE) | (1 << EVT_CMD_STATUS), 0, 0)

# include/net/bluetooth/hci_sock.h:
# struct hci_conn_list_req { __u16 dev_id; __u16 conn_num;
#                            struct hci_conn_info conn_info[]; }
# struct hci_conn_info { __u16 handle; bdaddr_t bdaddr; __u8 type; __u8 out;
#                        __u16 state; __u32 link_mode; }       # 16 bytes
HCIGETCONNLIST = 0x800448D4  # _IOR('H', 212, int)
HCI_CONN_INFO_FMT = "<H6sBBHI"
HCI_CONN_INFO_SIZE = struct.calcsize(HCI_CONN_INFO_FMT)
ACL_LINK = 1

HCI_STATUS_NAMES = {
    0x01: "Unknown Command",
    0x02: "Unknown Connection Identifier",
    0x03: "Hardware Failure",
    0x04: "Page Timeout",
    0x07: "Memory Capacity Exceeded",
    0x08: "Connection Timeout",
    0x0C: "Command Disallowed",
    0x0D: "Connection Rejected: Limited Resources",
    0x0E: "Connection Rejected: Security",
    0x11: "Unsupported Feature Or Parameter Value",
    0x12: "Invalid HCI Command Parameters",
    0x13: "Remote User Terminated Connection",
}


def parse_dev(name):
    """hci0 -> 0; anything else is rejected (the kernel names devices hci<N>)."""
    if not name.startswith("hci") or not name[3:].isdigit():
        raise ValueError(f"invalid HCI device name {name!r} (expected hci<N>)")
    return int(name[3:])


def send_command(sock, opcode, params):
    sock.send(bytes([HCI_COMMAND_PKT]) + struct.pack("<H", opcode) + bytes([len(params)]) + bytes(params))


def parse_event(pkt, opcode):
    """Classify one raw HCI packet against `opcode`.

    Returns (status, params) for a verdict, or None when the packet is not a
    verdict for this opcode. Layouts (Core Spec Vol 4 Part E §7.7.14/15):
      Command Complete: 04 0E plen | ncmd | opcode lo hi | status | params...
      Command Status:   04 0F plen | status | ncmd | opcode lo hi
    A Command Status with status 0 means "pending" and is not a verdict.
    """
    if len(pkt) < 3 or pkt[0] != HCI_EVENT_PKT:
        return None
    evt, plen = pkt[1], pkt[2]
    body = pkt[3:3 + plen]
    if evt == EVT_CMD_COMPLETE and len(body) >= 4:
        if body[1] | (body[2] << 8) == opcode:
            return body[3], bytes(body[4:])
    elif evt == EVT_CMD_STATUS and len(body) >= 4:
        if body[2] | (body[3] << 8) == opcode and body[0] != 0:
            return body[0], b""
    return None


def wait_complete(sock, opcode, deadline):
    """Read events until the verdict for `opcode`; returns (status, params) or (None, None)."""
    while True:
        remain = deadline - time.monotonic()
        if remain <= 0:
            return None, None
        sock.settimeout(remain)
        try:
            pkt = sock.recv(260)
        except OSError:   # includes socket.timeout
            return None, None
        verdict = parse_event(pkt, opcode)
        if verdict is not None:
            return verdict


def do_command(dev_id, ogf, ocf, params, timeout):
    opcode = (ogf << 10) | ocf
    try:
        sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
        sock.bind((dev_id,))
        sock.setsockopt(SOL_HCI, HCI_FILTER, CMD_EVENT_FILTER)
    except OSError as exc:
        print(f"error: cannot open raw HCI socket on hci{dev_id}: {exc}", file=sys.stderr)
        return 255
    try:
        send_command(sock, opcode, params)
        status, ret = wait_complete(sock, opcode, time.monotonic() + timeout)
    except OSError as exc:
        print(f"error: transport: {exc}", file=sys.stderr)
        return 255
    finally:
        sock.close()
    if status is None:
        print("error: no Command Complete received (controller down, busy, or timeout)",
              file=sys.stderr)
        return 255
    print(f"status 0x{status:02X}")
    if ret:
        print(" ".join(f"0x{b:02X}" for b in ret))
    if status != 0:
        name = HCI_STATUS_NAMES.get(status, "vendor-specific / reserved status")
        print(f"HCI command rejected: status 0x{status:02X} ({name})", file=sys.stderr)
        return status
    return 0


def list_conns(dev_id):
    """Enumerate ACL connections via the HCIGETCONNLIST ioctl (read-only)."""
    try:
        sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    except OSError as exc:
        print(f"error: cannot open raw HCI socket: {exc}", file=sys.stderr)
        return 255
    max_conns = 32
    buf = struct.pack("<HH", dev_id, max_conns) + b"\x00" * (HCI_CONN_INFO_SIZE * max_conns)
    try:
        res = fcntl.ioctl(sock.fileno(), HCIGETCONNLIST, buf)
    except OSError as exc:
        print(f"error: HCIGETCONNLIST on hci{dev_id}: {exc}", file=sys.stderr)
        return 255
    finally:
        sock.close()
    n = min(struct.unpack_from("<H", res, 2)[0], max_conns)
    for i in range(n):
        handle, bdaddr, ctype, _out, state, _lm = struct.unpack_from(
            HCI_CONN_INFO_FMT, res, 4 + i * HCI_CONN_INFO_SIZE)
        addr = ":".join(f"{b:02X}" for b in reversed(bdaddr))
        print(f"handle {handle} addr {addr} type {ctype} state {state}")
    if n == 0:
        print("no connections", file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Verified HCI command sender: exit code = the controller's Command Complete status byte.")
    ap.add_argument("--hci", default="hci0", help="controller name (default hci0)")
    ap.add_argument("--timeout", type=float, default=2.0, help="seconds to wait for Command Complete (default 2)")
    ap.add_argument("--list-conns", action="store_true", help="enumerate ACL connections and exit")
    ap.add_argument("ogf", nargs="?", help="command group field, e.g. 0x03")
    ap.add_argument("ocf", nargs="?", help="command opcode field, e.g. 0x003F")
    ap.add_argument("params", nargs="*", help="command parameters as 0xNN hex bytes")
    args = ap.parse_args()

    try:
        dev_id = parse_dev(args.hci)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.list_conns:
        return list_conns(dev_id)
    if args.ogf is None or args.ocf is None:
        ap.error("need OGF and OCF (e.g. hci-cmd.py 0x03 0x003F) or --list-conns")

    try:
        ogf = int(args.ogf, 0)
        ocf = int(args.ocf, 0)
        params = [int(p, 0) for p in args.params]
    except ValueError as exc:
        print(f"error: bad hex argument: {exc}", file=sys.stderr)
        return 2
    if not 0 <= ogf <= 0x3F:
        print(f"error: OGF 0x{ogf:X} out of range (0x00-0x3F)", file=sys.stderr)
        return 2
    if not 0 <= ocf <= 0x03FF:
        print(f"error: OCF 0x{ocf:X} out of range (0x0000-0x03FF)", file=sys.stderr)
        return 2
    for p in params:
        if not 0 <= p <= 255:
            print(f"error: parameter 0x{p:X} out of range (0x00-0xFF)", file=sys.stderr)
            return 2

    return do_command(dev_id, ogf, ocf, params, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
