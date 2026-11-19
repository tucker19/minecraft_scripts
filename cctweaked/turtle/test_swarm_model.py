"""Executable design checks for SWARM_DESIGN.md, not an in-game implementation."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def persist(path, record):
    staged = path.with_suffix(".tmp")
    staged.write_text(json.dumps(record))
    staged.replace(path)


def adjacent(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) == 1


class Coordinator:
    def __init__(self, path, manifest=None):
        self.path = path
        if manifest is not None:
            if path.exists():
                raise ValueError("already initialized")
            occupied = set()
            for home, area in manifest.values():
                reservation = {tuple(p) for p in [home, *area]}
                if occupied & reservation:
                    raise ValueError("overlapping reservation")
                occupied |= reservation
            persist(path, {"manifest": manifest, "grants": {}, "replies": {},
                           "evidence": {}, "next_id": 1})
        self.state = json.loads(path.read_text())

    def request(self, worker, seq, home):
        # Each message is dispatched serially. This fixture has one immutable
        # manifest; the production wire envelope adds quarry and manifest IDs.
        q = json.loads(self.path.read_text())
        last = q["replies"].get(worker)
        if last and seq <= last["seq"]:
            return last["reply"] if seq == last["seq"] and home == last["home"] else None
        grant = q["grants"].get(worker)
        used = {g["area"] for g in q["grants"].values()}
        candidates = sorted(a for a, (h, _) in q["manifest"].items()
                            if h == home and a not in used)
        if grant and q["manifest"][grant["area"]][0] != home:
            return None
        if grant is None and candidates:
            grant = {"id": q["next_id"], "worker": worker, "area": candidates[0]}
            q["next_id"] += 1
            q["grants"][worker] = grant
        reply = {"seq": seq, "grant": grant}
        q["replies"][worker] = {"seq": seq, "home": home, "reply": reply}
        persist(self.path, q)
        self.state = q
        return reply

    def sync(self, worker, grant):
        return self.state["grants"].get(worker) == grant and grant is not None

    def observe(self, worker, grant, seq, observations):
        if not self.sync(worker, grant):
            return False
        area = grant["area"]
        _, cells = self.state["manifest"][area]
        if any(p not in cells or status not in {"clear", "blocked", "unverified"}
               for p, status in observations):
            return False
        history = self.state["evidence"].get(area, [])
        if 0 < seq <= len(history):
            return history[seq - 1] == observations
        if seq != len(history) + 1:
            return False
        self.state["evidence"][area] = [*history, observations]
        persist(self.path, self.state)
        return True

    def plan(self, worker, grant, route, work, fuel, allowance=2, margin=1):
        """Plan route-only transit to an adjacent unfinished cell, then return."""
        if not self.sync(worker, grant):
            return None
        area = grant["area"]
        home, cells = self.state["manifest"][area]
        evidence = {tuple(p): s for batch in self.state["evidence"].get(area, [])
                    for p, s in batch}
        clear = {p for p, s in evidence.items() if s == "clear"}
        if (not route or route[0] != home or work not in cells or work in route
                or evidence.get(tuple(work), "unverified") != "unverified"
                or not adjacent(route[-1], work)
                or any(tuple(p) not in clear for p in route[1:])
                or not all(adjacent(a, b) for a, b in zip(route, route[1:]))
                or fuel < 2 * (len(route) - 1) + allowance + margin):
            return None
        return [("transit", p) for p in route[1:]] + [("work", work)] + [
            ("transit", p) for p in reversed(route)]

    def verified_layer(self, area, y):
        cells = [p for p in self.state["manifest"][area][1] if p[1] == y]
        evidence = {tuple(p): s for batch in self.state["evidence"].get(area, [])
                    for p, s in batch}
        return bool(cells) and all(evidence.get(tuple(p)) == "clear" for p in cells)


class Worker:
    def __init__(self, path, worker_id):
        self.path, self.id = path, worker_id
        self.state = json.loads(path.read_text()) if path.exists() else {}

    def save(self, **fields):
        self.state.update(fields)
        persist(self.path, self.state)

    def accept(self, response):
        if not response or response["seq"] != self.state.get("pending"):
            return False
        grant = response["grant"]
        if not grant or grant["worker"] != self.id:
            return False
        if "grant" in self.state:
            return self.state["grant"] == grant
        self.save(grant=grant, checkpoint={"assignment": grant["id"], "cursor": 0})
        return True

    def resume(self, coordinator):
        grant, checkpoint = self.state.get("grant"), self.state.get("checkpoint")
        return bool(coordinator and grant and checkpoint
                    and checkpoint["assignment"] == grant["id"]
                    and coordinator.sync(self.id, grant))


class SwarmDesignTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.manifest = {str(x): [[x, 3, 0], [[x, y, z] for y in (2, 1) for z in (0, 1)]]
                         for x in range(4)}
        self.ledger = self.root / "ledger.json"
        self.coordinator = Coordinator(self.ledger, self.manifest)

    def request(self, i, seq=1):
        return self.coordinator.request(f"turtle{i}", seq, self.manifest[str(i)][0])

    def test_three_queued_requests_and_late_join(self):
        queue = [2, 0, 1]
        replies = [self.request(i) for i in queue]
        replies.append(self.request(3))
        grants = [r["grant"] for r in replies]
        self.assertEqual(len({g["id"] for g in grants}), 4)
        reservations = [{tuple(p) for p in [home, *cells]} for home, cells in
                        (self.manifest[g["area"]] for g in grants)]
        self.assertEqual(len(set.union(*reservations)), sum(map(len, reservations)))
        self.assertIsNone(self.coordinator.request("late", 1, [0, 3, 0])["grant"])
        self.assertEqual(self.coordinator.state["next_id"], 5)

    def test_restart_after_commit_before_delivery_and_replays(self):
        path = self.root / "worker.json"
        Worker(path, "turtle0").save(pending=1)
        lost = self.request(0)
        self.coordinator = Coordinator(self.ledger)
        w = Worker(path, "turtle0")
        self.assertFalse(w.resume(self.coordinator))
        replay = self.request(0)
        self.assertEqual(replay, lost)
        self.assertTrue(w.accept(replay))
        self.assertTrue(w.resume(self.coordinator))
        self.assertIsNone(self.coordinator.request("turtle0", 1, [1, 3, 0]))
        self.assertEqual(self.request(0, 2)["grant"], lost["grant"])
        self.assertIsNone(self.request(0, 1))
        self.assertEqual(self.coordinator.state["next_id"], 2)

    def test_failed_persistence_cannot_return_a_grant(self):
        with patch(f"{__name__}.persist", side_effect=OSError("injected write failure")):
            with self.assertRaisesRegex(OSError, "write failure"):
                self.request(0)
        self.coordinator = Coordinator(self.ledger)
        self.assertEqual(self.coordinator.state["grants"], {})
        self.assertEqual(self.request(0)["grant"]["id"], 1)

    def test_worker_unloads_and_resumes_without_reinitialization(self):
        path = self.root / "worker.json"
        w = Worker(path, "turtle0")
        w.save(pending=1)
        reply = self.request(0)
        self.assertTrue(w.accept(reply))
        w.save(checkpoint={"assignment": reply["grant"]["id"], "cursor": 7})
        # No worker coroutine or heartbeat survives. Ownership remains.
        self.coordinator = Coordinator(self.ledger)
        self.assertIsNone(self.coordinator.request("other", 1, [0, 3, 0])["grant"])
        w = Worker(path, "turtle0")
        self.assertFalse(w.resume(None))
        self.assertTrue(w.resume(self.coordinator))
        self.assertTrue(w.accept(reply))
        self.assertEqual(w.state["checkpoint"]["cursor"], 7)
        self.assertFalse(w.accept({"seq": 0, "grant": reply["grant"]}))
        w.save(checkpoint={"assignment": 999, "cursor": 7})
        self.assertFalse(w.resume(self.coordinator))

    def test_verified_upper_layer_transit_without_sweep(self):
        c = self.coordinator
        grant = self.request(0)["grant"]
        home, entry, edge, work = [0, 3, 0], [0, 2, 0], [0, 2, 1], [0, 1, 1]
        first = [[entry, "clear"], [edge, "blocked"]]
        self.assertTrue(c.observe("turtle0", grant, 1, first))
        self.assertFalse(c.verified_layer("0", 2))
        self.assertIsNone(c.plan("turtle0", grant, [home, entry, edge], work, 7))
        self.assertTrue(c.observe("turtle0", grant, 1, first))
        second = [[edge, "clear"]]
        self.assertFalse(c.observe("turtle0", grant, 3, second))
        self.assertTrue(c.observe("turtle0", grant, 2, second))
        c = Coordinator(self.ledger)
        self.assertTrue(c.verified_layer("0", 2))
        self.assertFalse(c.verified_layer("0", 1))
        self.assertIsNone(c.plan("turtle0", grant, [home, edge], work, 99))
        self.assertIsNone(c.plan("turtle0", grant, [home, entry, edge], work, 6))
        self.assertEqual(c.plan("turtle0", grant, [home, entry, edge], work, 7),
                         [("transit", entry), ("transit", edge), ("work", work),
                          ("transit", edge), ("transit", entry), ("transit", home)])
        self.assertTrue(c.observe("turtle0", grant, 3, [[entry, "blocked"]]))
        self.assertFalse(c.verified_layer("0", 2))
        self.assertIsNone(c.plan("turtle0", grant, [home, entry, edge], work, 7))

    def test_overlapping_manifest_and_missing_ledger_fail_closed(self):
        self.manifest["1"][0] = self.manifest["0"][1][0]
        empty_path = self.root / "other.json"
        with self.assertRaisesRegex(ValueError, "overlapping"):
            Coordinator(empty_path, self.manifest)
        with self.assertRaises(FileNotFoundError):
            Coordinator(empty_path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
