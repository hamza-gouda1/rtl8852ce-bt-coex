#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""hci-acl-capture.py — record outgoing ACL traffic timestamps without btmon.

btmon aborts (glibc fortify: "buffer overflow detected") while decoding the
RTL8852CE's A2DP media stream on this system (bluez 5.72), which truncated
the 10-minute capture to ~104 s (frame #5328). This recorder reads the
kernel's monitor channel directly - the same source btmon uses - but only
timestamps ACL TX records and writes plain text, so there is no frame
decoder in the path to abort.

Output format:
    # hci-acl-tx v1
    <seconds-since-start> <handle> <dlen>
    ...

Usage:
    sudo python3 scripts/hci-acl-capture.py <seconds> [outfile] [--hci hci0]

outfile is created inside the current working directory or a subdirectory of
it (relative paths only, no '..' escapes, no symlink targets).

Root is required for the monitor channel (btmon needs it for the same
reason). Only one monitor reader may run at a time (no btmon in parallel).
Ctrl-C stops early and still leaves a complete file.
"""

import argparse
import ctypes
import os
import socket
import struct
import sys
import time

HCI_MON_ACL_TX_PKT = 7   # net/bluetooth/hci_sock.c: HCI_MON_ACL_TX_PKT
HCI_CHANNEL_MONITOR = 1
HCI_DEV_NONE = 0xFFFF    # btmon binds the monitor channel here: global, all controllers
AF_BLUETOOTH_LINUX = 31  # socket.AF_BLUETOOTH on Linux


def parse_record(pkt, dev_id):
    """One monitor-channel message -> (handle, dlen) for ACL TX, else None.

    Monitor message: [opcode u16 LE][index u16 LE][len u16 LE][data ...];
    ACL data records carry the full HCI ACL packet: [handle+flags u16 LE][dlen u16 LE].
    """
    if len(pkt) < 10:
        return None
    opcode, index, mlen = struct.unpack_from("<HHH", pkt, 0)
    if opcode != HCI_MON_ACL_TX_PKT or index != dev_id or mlen < 4:
        return None
    data = pkt[6:6 + mlen]
    handle = data[0] | ((data[1] & 0x0F) << 8)
    dlen = data[2] | (data[3] << 8)
    return handle, dlen


def resolve_outfile(path):
    """Only relative paths inside the current directory or below are allowed."""
    if os.path.isabs(path):
        raise ValueError(f"outfile must be a relative path (created under the current directory): {path}")
    norm = os.path.normpath(path)
    if norm == ".." or norm.startswith(".." + os.sep):
        raise ValueError(f"outfile must not escape the current directory: {path}")
    return norm


def open_capture_file(path):
    """Create the capture file for writing.

    O_NOFOLLOW refuses an existing symlink at the path; combined with the
    relative-only path rule in resolve_outfile, the capture always lands
    inside the invoking directory tree.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    return os.open(path, flags, 0o644)


def open_monitor():
    """Bind the global monitor channel (HCI_DEV_NONE, like btmon does).

    A per-device monitor bind is rejected with EBUSY; the global channel
    carries every controller's records, and parse_record() filters by the
    index field. CPython's BTPROTO_HCI bind only sets hci_dev (channel stays
    0 = raw), so the bind is issued through libc with a fully packed
    sockaddr_hci.
    """
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    sockaddr = struct.pack("HHH", AF_BLUETOOTH_LINUX, HCI_DEV_NONE, HCI_CHANNEL_MONITOR)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.bind(s.fileno(), sockaddr, len(sockaddr)) != 0:
        err = ctypes.get_errno()
        s.close()
        raise OSError(err, os.strerror(err))
    s.settimeout(1.0)
    return s


def main():
    ap = argparse.ArgumentParser(description="Record ACL TX timestamps from the kernel monitor channel (no btmon decoder).")
    ap.add_argument("seconds", type=float, help="capture duration in seconds")
    ap.add_argument("outfile", nargs="?", default="acl-tx-capture.txt")
    ap.add_argument("--hci", default="hci0", help="controller name (default hci0)")
    args = ap.parse_args()

    try:
        outfile = resolve_outfile(args.outfile)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if not args.hci.startswith("hci") or not args.hci[3:].isdigit():
        print(f"error: invalid HCI device name {args.hci!r} (expected hci<N>)", file=sys.stderr)
        return 2
    dev_id = int(args.hci[3:])

    try:
        sock = open_monitor()
    except OSError as exc:
        print(f"error: cannot open the monitor channel: {exc}", file=sys.stderr)
        print("       (root required; the channel binds globally via HCI_DEV_NONE, like btmon)", file=sys.stderr)
        return 1

    n = 0
    t0 = time.monotonic()
    end = t0 + args.seconds
    fd = open_capture_file(outfile)
    os.write(fd, b"# hci-acl-tx v1\n")
    print(f"[*] recording ACL TX for {args.seconds:.0f} s on {args.hci} -> {outfile}")
    try:
        while True:
            remain = end - time.monotonic()
            if remain <= 0:
                break
            sock.settimeout(min(1.0, remain))
            try:
                pkt = sock.recv(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            rec = parse_record(pkt, dev_id)
            if rec is None:
                continue
            handle, dlen = rec
            os.write(fd, f"{time.monotonic() - t0:.6f} {handle} {dlen}\n".encode())
            n += 1
    finally:
        sock.close()
        os.close(fd)
    print(f"[*] done: {n} ACL TX packets -> {outfile}")
    print(f"[*] analyze: bash scripts/analyze-stalls.sh {outfile}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
