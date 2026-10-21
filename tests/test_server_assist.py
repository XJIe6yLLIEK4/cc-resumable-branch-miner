"""Protocol, calibration and chunk ownership tests; no real Minecraft commands."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("assist", Path(__file__).resolve().parents[1] / "server" / "assist.py")
assist = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assist)


class FakeConsole:
    def __init__(self):
        self.actual = {}
        self.calls = []
        self.preexisting = {(8, -12), (11, -12)}
        self.on_observe = None

    def ensure_chunk(self, chunk):
        self.calls.append(("add", chunk))
        return chunk not in self.preexisting

    def remove_chunk(self, chunk):
        self.calls.append(("remove", chunk))

    def observe(self, computer, position):
        self.calls.append(("observe", computer, position))
        if self.on_observe:
            self.on_observe()
        return self.actual.get(position)

    def position(self, computer):
        return next(iter(self.actual))


class TestAssist(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="assist-test-", dir=Path(__file__).parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / "computers" / "1" / ".branchminer"
        self.folder.mkdir(parents=True)
        self.binding = {"job": "1:100", "home": [141, -55, -32], "heading": 0, "seed": [163, -54, -22]}
        self.console = FakeConsole()
        self.agent = assist.Assist({"computer_root": str(self.root / "computers"), "bindings": {"1": self.binding}},
                                  self.console, self.root / "state" / "tickets.json")
        self.chown = patch.object(assist.os, "chown", create=True)
        self.chown.start()
        self.addCleanup(self.chown.stop)

    def prepare(self):
        (self.folder / "server-assist").write_text("1\n")
        hb = "1\t1\t1:100\t12\t-22\t1\t10\t1\twaiting\t1000\n"
        request = "1\t1\t1:100\t12\t1000:12\tturnLeft\t-22\t1\t10\t1\t-22\t1\t10\t0\n"
        (self.folder / "assist.heartbeat").write_text(hb)
        (self.folder / "assist.request").write_text(request)
        self.console.actual[(163, -54, -22)] = (163, -54, -22, 0)
        return hb, request

    def test_all_compass_transforms_round_trip(self):
        for heading in range(4):
            binding = dict(self.binding, heading=heading)
            for h in range(4):
                pose = (-22, 1, 10, h)
                self.assertEqual(assist.relative(binding, assist.world(binding, pose)), pose)
        self.assertEqual(assist.world(self.binding, (-22, 1, 10, 0)), (163, -54, -22, 0))

    def test_console_feedback_starts_after_exact_journal_cursor(self):
        responses = [SimpleNamespace(stdout="old message\n-- cursor: exact-cursor\n"),
                     SimpleNamespace(stdout="[minecraft/MinecraftServer]: new response\n")]
        with patch.object(assist.subprocess, "run", side_effect=responses) as run, \
                patch.object(assist.os, "open", return_value=123), \
                patch.object(assist.os, "O_NONBLOCK", 2048, create=True), \
                patch.object(assist.os, "write"), patch.object(assist.os, "close"), \
                patch.object(assist.time, "sleep"):
            self.assertEqual(assist.Console().query("data get block 0 0 0 On"), ["new response"])
        self.assertIn("--show-cursor", run.call_args_list[0].args[0])
        self.assertIn("--after-cursor", run.call_args_list[1].args[0])
        self.assertIn("exact-cursor", run.call_args_list[1].args[0])

    def test_live_direction_results_have_a_unique_query_token(self):
        line = 'Storage branchminer:assist has the following contents: {token: "unique", south: 0b, east: 1b, north: 0b, west: 0b}'
        console = assist.Console()
        with patch.object(assist.uuid, "uuid4", return_value=SimpleNamespace(hex="unique")), \
                patch.object(console, "query", return_value=[line]) as query:
            self.assertEqual(console.observe(1, (2, 3, 4)), (2, 3, 4, 1))
        self.assertEqual(query.call_args.kwargs["token"], "unique")
        command = query.call_args.args[0]
        self.assertIn('south:0b,east:0b,north:0b,west:0b', command)
        self.assertEqual(command.count("if data block 2 3 4 {ComputerId:1}"), 4)
        self.assertNotIn("setblock", command)
        self.assertNotIn("teleport", command)

    def test_live_completed_turn_reply_is_bound_to_request(self):
        self.prepare()
        self.agent.step()
        response = (self.folder / "assist.response").read_text()
        self.assertEqual(response, "1\t1\t1:100\t12\t1000:12\t-22\t1\t10\t0\n")
        self.assertEqual(self.agent.owned, {(10, -2)})
        self.assertEqual(json.loads(self.agent.state.read_text())["owned"], [[10, -2]])

    def test_stale_sequence_or_running_worker_gets_no_response(self):
        hb, _ = self.prepare()
        for bad in (hb.replace("\t12\t", "\t13\t"), hb.replace("waiting", "running")):
            (self.folder / "assist.heartbeat").write_text(bad)
            self.agent.step()
            self.assertFalse((self.folder / "assist.response").exists())
            self.assertFalse(any(call[0] == "observe" for call in self.console.calls))

    def test_request_replaced_while_querying_gets_no_response(self):
        self.prepare()
        self.console.on_observe = lambda: (self.folder / "assist.request").write_text("replaced")
        self.agent.step()
        self.assertFalse((self.folder / "assist.response").exists())

    def test_unbound_job_cannot_move_chunk_ticket_or_get_reply(self):
        hb, _ = self.prepare()
        (self.folder / "assist.heartbeat").write_text(hb.replace("1:100", "1:200"))
        self.agent.step()
        self.assertEqual(self.console.calls, [])
        self.assertFalse((self.folder / "assist.response").exists())

    def test_new_unmoved_job_gets_its_own_durable_anchor(self):
        self.prepare()
        (self.folder / "assist.heartbeat").write_text("1\t1\t1:200\t2\t0\t0\t0\t0\twaiting\t2000\n")
        (self.folder / "assist.request").write_text("1\t1\t1:200\t2\t2000:2\tanchor\t0\t0\t0\t0\t0\t0\t0\t0\n")
        self.agent.step()
        self.assertEqual(self.agent.bindings["1"]["job"], "1:200")
        self.assertEqual(self.agent.bindings["1"]["home"], [163, -54, -22])
        self.assertEqual(json.loads(self.agent.anchor_state.read_text())["1"], self.agent.bindings["1"])
        self.assertTrue((self.folder / "assist.response").read_text().endswith("\t0\t0\t0\t0\n"))

    def test_ticket_moves_add_before_remove_and_preserves_existing(self):
        self.agent.centers = {"1": (10, -2)}
        self.agent.tickets()
        self.console.calls.clear()
        self.agent.centers = {"1": (8, -12)}
        self.agent.tickets()
        self.assertEqual(self.console.calls, [("add", (8, -12)), ("remove", (10, -2))])
        self.assertFalse(self.agent.owned)
        self.agent.centers = {"1": (9, -1)}
        self.agent.tickets()
        self.assertNotIn(("remove", (8, -12)), self.console.calls)

    def test_restart_retains_owned_ticket_for_later_cleanup(self):
        self.agent.centers = {"1": (10, -2)}
        self.agent.tickets()
        agent = assist.Assist({"computer_root": str(self.root / "computers"), "bindings": {}},
                             self.console, self.agent.state)
        agent.tickets()
        self.assertIn(("remove", (10, -2)), self.console.calls)

    def test_heartbeat_replacement_gap_keeps_last_center_across_helper_restart(self):
        hb, _ = self.prepare()
        (self.folder / "assist.request").unlink()
        (self.folder / "assist.heartbeat").write_text(hb.replace("\t-22\t", "\t-40\t"))
        self.agent.step()
        center = self.agent.centers["1"]
        self.assertNotEqual(center, (10, -2))
        (self.folder / "assist.heartbeat").unlink()
        self.agent.step()
        self.assertEqual(self.agent.centers["1"], center)
        agent = assist.Assist({"computer_root": str(self.root / "computers"), "bindings": {"1": self.binding}},
                             self.console, self.agent.state)
        agent.step()
        self.assertEqual(agent.centers["1"], center)

    def test_invalid_motion_and_protocol_are_rejected(self):
        _, raw = self.prepare()
        for bad in (raw.replace("turnLeft", "dig"), raw.replace("\t10\t0\n", "\t10\t2\n"),
                    raw + "second record\n", raw.replace("\t1:100\t", "\t$(touch /tmp/x)\t")):
            with self.assertRaises(ValueError):
                assist.request(bad)


if __name__ == "__main__":
    unittest.main()
