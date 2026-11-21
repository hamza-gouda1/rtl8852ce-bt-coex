# SPDX-License-Identifier: GPL-2.0-only
"""Unit tests for scripts/hci-acl-capture.py (stdlib unittest, no hardware).

The monitor-channel record layout follows net/bluetooth/hci_sock.c
(HCI_MON_ACL_TX_PKT = 7, header {opcode, index, len} as little-endian u16).
"""

import importlib.util
import pathlib
import struct
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "hci-acl-capture.py"
spec = importlib.util.spec_from_file_location("hci_acl_capture", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def _acl_data(handle, dlen):
    """HCI ACL header: 12-bit handle, flags in bits 12-15 (0x2 = PB start)."""
    return struct.pack("<HH", (handle & 0x0FFF) | (0x2 << 12), dlen)


def acl_tx_record(index, handle, dlen, opcode=7):
    return struct.pack("<HHH", opcode, index, len(_acl_data(handle, dlen))) + _acl_data(handle, dlen)


def acl_rx_record(index, handle, dlen):
    return struct.pack("<HHH", 8, index, len(_acl_data(handle, dlen))) + _acl_data(handle, dlen)


class ParseRecord(unittest.TestCase):
    def test_acl_tx_parsed_mainline_opcode(self):
        self.assertEqual(mod.parse_record(acl_tx_record(0, 5, 625, opcode=7), 0), (5, 625))

    def test_acl_tx_parsed_liquorix_opcode(self):
        # 7.0.13-liquorix emits the pre-3.5 numbering: ACL TX = 4 (verified
        # 2026-11-21 with scripts/hci-monitor-probe.py: 198 records/5 s).
        self.assertEqual(mod.parse_record(acl_tx_record(0, 5, 657, opcode=4), 0), (5, 657))

    def test_oversized_frame_rejected(self):
        self.assertIsNone(mod.parse_record(acl_tx_record(0, 5, 2000, opcode=4), 0))

    def test_rx_opcode_ignored(self):
        self.assertIsNone(mod.parse_record(acl_rx_record(0, 5, 625), 0))

    def test_sco_and_index_opcodes_ignored(self):
        for op in (5, 9, 10, 2, 3):
            self.assertIsNone(mod.parse_record(acl_tx_record(0, 5, 100, opcode=op), 0))

    def test_other_index_ignored(self):
        self.assertIsNone(mod.parse_record(acl_tx_record(1, 5, 625), 0))

    def test_truncated_records(self):
        self.assertIsNone(mod.parse_record(b"\x07\x00\x00\x00", 0))
        self.assertIsNone(mod.parse_record(b"", 0))

    def test_flags_do_not_leak_into_handle(self):
        rec = acl_tx_record(0, 5, 677)
        self.assertEqual(mod.parse_record(rec, 0)[0], 5)


class OutfilePath(unittest.TestCase):
    def test_relative_paths_pass(self):
        self.assertEqual(mod.resolve_outfile("a/b.txt"), "a/b.txt")
        self.assertEqual(mod.resolve_outfile("./a/../b.txt"), "b.txt")

    def test_escapes_and_absolute_rejected(self):
        with self.assertRaises(ValueError):
            mod.resolve_outfile("../esc.txt")
        with self.assertRaises(ValueError):
            mod.resolve_outfile("/etc/passwd")


if __name__ == "__main__":
    unittest.main()
