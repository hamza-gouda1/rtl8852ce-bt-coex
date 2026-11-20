# SPDX-License-Identifier: GPL-2.0-only
"""Unit tests for scripts/hci-cmd.py (stdlib unittest, no hardware needed).

The raw packets below were recorded from the reference laptop's controller.
Run: python3 -m unittest discover -s tests -p 'test_*.py'
"""

import importlib.util
import pathlib
import struct
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "hci-cmd.py"
spec = importlib.util.spec_from_file_location("hci_cmd", SCRIPT)
hci_cmd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hci_cmd)

OP_READ_LOCAL_VERSION = (0x04 << 10) | 0x0001
OP_READ_AFH_MAP = (0x05 << 10) | 0x0006
OP_SET_AFH = (0x03 << 10) | 0x003F

# Recorded: Read Local Version Information -> Command Complete
PKT_VERSION = bytes.fromhex("040E0C02011000 0C0D040C5D002572".replace(" ", ""))
# Recorded: Read AFH Channel Map, handle 4 -> Command Complete
PKT_AFH = bytes.fromhex("040E1102061400040001000000F8FFFFFFFFFF7F")


class ParseEvent(unittest.TestCase):
    def test_command_complete_recorded(self):
        status, params = hci_cmd.parse_event(PKT_VERSION, OP_READ_LOCAL_VERSION)
        self.assertEqual(status, 0)
        self.assertEqual(params.hex(), "0c0d040c5d002572")

    def test_read_afh_map_layout(self):
        status, params = hci_cmd.parse_event(PKT_AFH, OP_READ_AFH_MAP)
        self.assertEqual(status, 0)
        handle = params[0] | (params[1] << 8)
        self.assertEqual(handle, 4)
        self.assertEqual(params[2], 1)          # AFH_Mode
        self.assertEqual(len(params[3:]), 10)   # AFH_Channel_Map

    def test_other_opcode_is_ignored(self):
        self.assertIsNone(hci_cmd.parse_event(PKT_VERSION, OP_SET_AFH))

    def test_command_complete_rejected(self):
        pkt = bytes([0x04, 0x0E, 0x04, 0x01, 0x3F, 0x0C, 0x12])
        self.assertEqual(hci_cmd.parse_event(pkt, OP_SET_AFH), (0x12, b""))

    def test_command_status_rejected(self):
        pkt = bytes([0x04, 0x0F, 0x04, 0x0C, 0x01, 0x3F, 0x0C])
        self.assertEqual(hci_cmd.parse_event(pkt, OP_SET_AFH), (0x0C, b""))

    def test_command_status_pending_is_not_a_verdict(self):
        pkt = bytes([0x04, 0x0F, 0x04, 0x00, 0x01, 0x3F, 0x0C])
        self.assertIsNone(hci_cmd.parse_event(pkt, OP_SET_AFH))

    def test_non_event_and_truncated(self):
        self.assertIsNone(hci_cmd.parse_event(b"\x02\x04\x20", OP_SET_AFH))
        self.assertIsNone(hci_cmd.parse_event(b"\x04\x0E", OP_SET_AFH))


class KernelLayouts(unittest.TestCase):
    def test_filter_is_sizeof_hci_ufilter(self):
        self.assertEqual(len(hci_cmd.CMD_EVENT_FILTER), 16)
        type_mask, ev0, ev1, opcode = struct.unpack("<IIIH2x", hci_cmd.CMD_EVENT_FILTER)
        self.assertEqual(type_mask, 1 << 4)
        self.assertTrue(ev0 & (1 << 0x0E) and ev0 & (1 << 0x0F))

    def test_conn_list_ioctl(self):
        self.assertEqual(hci_cmd.HCIGETCONNLIST, (2 << 30) | (4 << 16) | (ord("H") << 8) | 212)
        self.assertEqual(hci_cmd.HCI_CONN_INFO_SIZE, 16)


if __name__ == "__main__":
    unittest.main()
