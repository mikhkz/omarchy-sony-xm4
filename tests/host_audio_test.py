import importlib.machinery
import importlib.util
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("host_audio", str(ROOT / "host-audio"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
HOST_AUDIO = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(HOST_AUDIO)


class HostAudioTest(unittest.TestCase):
    def test_object_for_prefers_bluez_address_property(self):
        rows = [{"name": "anything", "properties": {
            "api.bluez5.address": "aa:bb:cc:dd:ee:ff"}}]
        self.assertEqual(HOST_AUDIO.object_for("AA:BB:CC:DD:EE:FF", rows), "anything")

    def test_object_for_accepts_pipewire_address_in_name(self):
        rows = [{"name": "bluez_output.AA_BB_CC_DD_EE_FF.1", "properties": {}}]
        self.assertEqual(
            HOST_AUDIO.object_for("AA:BB:CC:DD:EE:FF", rows),
            "bluez_output.AA_BB_CC_DD_EE_FF.1")

    @mock.patch.object(HOST_AUDIO, "objects")
    @mock.patch.object(HOST_AUDIO, "save_state")
    @mock.patch.object(HOST_AUDIO, "run")
    def test_release_disables_only_matching_card(self, run, save_state, objects):
        objects.side_effect = [
            [{"name": "xm4-card", "active_profile": "a2dp-sink",
              "properties": {"api.bluez5.address": "AA:BB:CC:DD:EE:FF"}}],
            [{"name": "xm4-sink", "index": 7,
              "properties": {"api.bluez5.address": "AA:BB:CC:DD:EE:FF"}}],
            [{"index": 11, "sink": 7}, {"index": 12, "sink": 9}],
        ]
        self.assertEqual(
            HOST_AUDIO.change("release", "AA:BB:CC:DD:EE:FF")["target"], "other")
        run.assert_called_once_with(
            ["pactl", "set-card-profile", "xm4-card", "off"])
        save_state.assert_called_once_with(
            "AA:BB:CC:DD:EE:FF", {"profile": "a2dp-sink", "inputs": [11]})

    @mock.patch.object(HOST_AUDIO, "objects")
    @mock.patch.object(HOST_AUDIO, "clear_state")
    @mock.patch.object(HOST_AUDIO, "load_state")
    @mock.patch.object(HOST_AUDIO, "run_optional")
    @mock.patch.object(HOST_AUDIO, "run")
    def test_claim_enables_a2dp_and_selects_matching_sink(
            self, run, run_optional, load_state, clear_state, objects):
        load_state.return_value = {"profile": "a2dp-sink-sbc_xq", "inputs": [11]}
        objects.side_effect = [
            [{"name": "xm4-card", "properties": {
                "api.bluez5.address": "AA:BB:CC:DD:EE:FF"}}],
            [{"name": "xm4-sink", "properties": {
                "api.bluez5.address": "AA:BB:CC:DD:EE:FF"}}],
        ]
        self.assertEqual(
            HOST_AUDIO.change("claim", "AA:BB:CC:DD:EE:FF")["target"], "computer")
        self.assertEqual(run.call_args_list, [
            mock.call(["pactl", "set-card-profile", "xm4-card", "a2dp-sink-sbc_xq"]),
            mock.call(["pactl", "set-default-sink", "xm4-sink"]),
        ])
        run_optional.assert_called_once_with(
            ["pactl", "move-sink-input", "11", "xm4-sink"])
        clear_state.assert_called_once_with("AA:BB:CC:DD:EE:FF")

    @mock.patch.object(HOST_AUDIO.time, "sleep")
    @mock.patch.object(HOST_AUDIO, "objects")
    @mock.patch.object(HOST_AUDIO, "run_optional")
    @mock.patch.object(HOST_AUDIO, "load_state", return_value={})
    def test_claim_reopens_a2dp_when_wireplumber_removed_card(
            self, load_state, run_optional, objects, sleep):
        objects.side_effect = [
            [],  # initial card lookup
            [{"name": "xm4-card", "properties": {
                "api.bluez5.address": "AA:BB:CC:DD:EE:FF"}}],
            [{"name": "xm4-sink", "properties": {
                "api.bluez5.address": "AA:BB:CC:DD:EE:FF"}}],
        ]
        with mock.patch.object(HOST_AUDIO, "run") as run, \
                mock.patch.object(HOST_AUDIO, "clear_state"):
            result = HOST_AUDIO.change("claim", "AA:BB:CC:DD:EE:FF")
        self.assertEqual(result["target"], "computer")
        run_optional.assert_called_once_with([
            "bluetoothctl", "connect", "AA:BB:CC:DD:EE:FF", HOST_AUDIO.A2DP_UUID])

    def test_rejects_untrusted_address(self):
        with self.assertRaises(ValueError):
            HOST_AUDIO.change("claim", "$(touch /tmp/nope)")

    @mock.patch.object(HOST_AUDIO, "objects")
    def test_status_reports_other_while_released(self, objects):
        objects.side_effect = [[], []]
        self.assertEqual(
            HOST_AUDIO.change("status", "AA:BB:CC:DD:EE:FF")["target"], "other")


if __name__ == "__main__":
    unittest.main()
