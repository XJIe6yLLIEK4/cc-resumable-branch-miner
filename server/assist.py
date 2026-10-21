#!/usr/bin/env python3
"""Optional dedicated-server adapter. Observe live blocks; never move turtles.

Only explicitly calibrated computer/job pairs are accepted. A worker must be
waiting at an immutable motion journal before an orientation reply is issued.
Chunk tickets follow its heartbeat, with no offline region/NBT reads.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

DIR = ((0, 1), (1, 0), (0, -1), (-1, 0))
NAMES = ("south", "east", "north", "west")
METHODS = {"turnLeft", "turnRight", "forward", "back", "up", "down", "anchor"}


def integer(value, low=-30_000_000, high=30_000_000):
    if not re.fullmatch(r"-?\d+", str(value)):
        raise ValueError("Invalid integer")
    value = int(value)
    if not low <= value <= high:
        raise ValueError("Integer outside permitted range")
    return value


def parse(raw, count):
    fields = raw.rstrip("\n").split("\t")
    if len(fields) != count or fields[0] != "1" or "\n" in raw.rstrip("\n"):
        raise ValueError("Invalid protocol record")
    integer(fields[1], 0, 1_000_000)
    integer(fields[3], 0, 10**12)
    if not re.fullmatch(r"\d+:\d+", fields[2]):
        raise ValueError("Invalid job ID")
    return fields


def heartbeat(raw):
    f = parse(raw, 10)
    position = tuple(integer(v) for v in f[4:7]) + (integer(f[7], 0, 3),)
    if f[8] not in {"running", "waiting", "recovery", "paused", "completed", "cancelled"}:
        raise ValueError("Invalid worker status")
    integer(f[9], 0, 10**16)
    return f, position


def request(raw):
    f = parse(raw, 14)
    if not re.fullmatch(r"\d+:\d+", f[4]) or f[5] not in METHODS:
        raise ValueError("Invalid observation request")
    points = []
    for start in (6, 10):
        points.append(tuple(integer(v) for v in f[start:start + 3]) + (integer(f[start + 3], 0, 3),))
    a, b = points
    expected = list(a)
    if f[5] == "anchor":
        if a != (0, 0, 0, 0):
            raise ValueError("Only a new, unmoved job can create an anchor")
    elif f[5] in ("turnLeft", "turnRight"):
        expected[3] = (a[3] + (1 if f[5] == "turnRight" else -1)) % 4
    elif f[5] in ("up", "down"):
        expected[1] += 1 if f[5] == "up" else -1
    else:
        sign = -1 if f[5] == "back" else 1
        expected[0] += DIR[a[3]][0] * sign
        expected[2] += DIR[a[3]][1] * sign
    if tuple(expected) != b:
        raise ValueError("Request is not one ordinary physical action")
    return f, a, b


def world(binding, pose):
    x, y, z, h = pose
    forward, right = DIR[binding["heading"]], DIR[(binding["heading"] + 3) % 4]
    home = binding["home"]
    return (home[0] + x * right[0] + z * forward[0], home[1] + y,
            home[2] + x * right[1] + z * forward[1], (binding["heading"] - h) % 4)


def relative(binding, pose):
    x, y, z, h = pose
    dx, dz = x - binding["home"][0], z - binding["home"][2]
    forward, right = DIR[binding["heading"]], DIR[(binding["heading"] + 3) % 4]
    return (dx * right[0] + dz * right[1], y - binding["home"][1],
            dx * forward[0] + dz * forward[1], (binding["heading"] - h) % 4)


def atomic(path, raw):
    staged = path.with_name(path.name + ".host-tmp")
    staged.write_text(raw, encoding="ascii")
    if path.exists():
        metadata = path.stat()
    else:
        metadata = path.parent.stat()
    os.chown(staged, metadata.st_uid, metadata.st_gid)
    os.chmod(staged, 0o600)
    os.replace(staged, path)


class Console:
    def __init__(self, unit="minecraft", fifo="/run/minecraft/console"):
        self.unit, self.fifo = unit, fifo

    def query(self, command, token=None):
        tail = subprocess.run(
            ["journalctl", "-u", self.unit, "-n", "1", "--show-cursor", "--no-pager", "-o", "cat"],
            check=True, capture_output=True, text=True, timeout=5).stdout
        cursors = [line.removeprefix("-- cursor: ") for line in tail.splitlines() if line.startswith("-- cursor: ")]
        if not cursors:
            raise RuntimeError("Cannot obtain Minecraft journal cursor")
        cursor = cursors[-1]
        fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, (command + "\n").encode("ascii"))
        finally:
            os.close(fd)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            time.sleep(0.12)
            output = subprocess.run(
                ["journalctl", "-u", self.unit, "--after-cursor", cursor,
                 "--no-pager", "-o", "cat"], check=True, capture_output=True, text=True,
                timeout=5).stdout
            lines = [line.split("[minecraft/MinecraftServer]: ", 1)[1]
                     for line in output.splitlines() if "[minecraft/MinecraftServer]: " in line]
            # dump emits several lines. Do not return a partial instance table.
            if lines and (token is None or any(f'token: "{token}"' in line for line in lines)) \
                    and (not command.startswith("computercraft dump")
                         or any(line.startswith("Family") for line in lines)):
                return lines
        raise RuntimeError("No console feedback")

    def observe(self, computer, position):
        x, y, z = position
        # Failed execute predicates can be silent at the dedicated console.
        # Store their boolean results in our own tiny diagnostic storage and
        # read one nonce-tagged reply. No blocks/entities/inventories change.
        token = uuid.uuid4().hex
        commands = [f'data modify storage branchminer:assist observation set value '
                    f'{{token:"{token}",south:0b,east:0b,north:0b,west:0b}}']
        for name in NAMES:
            commands.append(
                f"execute store success storage branchminer:assist observation.{name} byte 1 "
                f"run execute if block {x} {y} {z} computercraft:turtle_advanced[facing={name}] "
                f"if data block {x} {y} {z} {{ComputerId:{computer}}}")
        commands.append("data get storage branchminer:assist observation")
        lines = self.query("\n".join(commands), token=token)
        replies = [line for line in lines if f'token: "{token}"' in line]
        if len(replies) != 1:
            raise RuntimeError("Missing or duplicate live observation reply")
        values = [re.search(r"\b" + name + r":\s*([01])b\b", replies[0]) for name in NAMES]
        if not all(values):
            raise RuntimeError("Incomplete live observation reply")
        headings = [h for h, value in enumerate(values) if value.group(1) == "1"]
        if len(headings) > 1:
            raise RuntimeError("Conflicting live direction results")
        return (*position, headings[0]) if headings else None

    def position(self, computer):
        lines = self.query(f"computercraft dump #{computer}")
        for line in lines:
            match = re.fullmatch(r"Position\s*\|\s*(-?\d+), (-?\d+), (-?\d+)", line)
            if match:
                return tuple(int(v) for v in match.groups())
        raise RuntimeError(f"Computer {computer}: live instance is not registered")

    def ensure_chunk(self, chunk):
        x, z = chunk[0] * 16, chunk[1] * 16
        messages = self.query(f"forceload query {x} {z}")
        if any("is marked for force loading" in m and "not marked" not in m for m in messages):
            return False
        messages = self.query(f"forceload add {x} {z}")
        if not any("Marked chunk" in m or "Marked chunks" in m for m in messages):
            raise RuntimeError("Could not add chunk ticket: " + str(messages))
        return True

    def remove_chunk(self, chunk):
        self.query(f"forceload remove {chunk[0] * 16} {chunk[1] * 16}")


class Assist:
    def __init__(self, config, console, state):
        self.root = Path(config["computer_root"]).resolve()
        self.bindings, self.console, self.state = config["bindings"], console, Path(state)
        self.state.parent.mkdir(parents=True, exist_ok=True)
        self.anchor_state = self.state.with_name("anchors.json")
        if self.anchor_state.exists():
            for computer, binding in json.loads(self.anchor_state.read_text()).items():
                if computer in self.bindings:
                    self.bindings[computer] = binding
        self.owned = set()
        self.centers = {}
        if self.state.exists():
            saved = json.loads(self.state.read_text())
            self.owned = {tuple(p) for p in saved["owned"]}
            self.centers = {n: tuple(p) for n, p in saved.get("centers", {}).items() if n in self.bindings}
        self.loaded, self.last_error, self.saved_state = set(), None, None
        for computer, binding in self.bindings.items():
            integer(computer, 0, 1_000_000)
            integer(binding["heading"], 0, 3)
            if len(binding["home"]) != 3 or len(binding["seed"]) != 3:
                raise ValueError("Invalid calibrated anchor")
            for value in binding["home"] + binding["seed"]:
                integer(value)
            if not re.fullmatch(re.escape(computer) + r":\d+", binding["job"]):
                raise ValueError("Job is not bound to this computer")

    def folder(self, computer):
        result = (self.root / computer / ".branchminer").resolve()
        if result.parent.parent != self.root:
            raise ValueError("Computer path escapes configured root")
        return result

    def tickets(self):
        desired = set(self.centers.values())
        # A ticket keeps neighboring block-ticking chunks available too. Follow each turtle,
        # rather than keeping its complete mine and surrounding world loaded.
        for chunk in desired:
            if chunk not in self.loaded:
                if self.console.ensure_chunk(chunk):
                    self.owned.add(chunk)
                    self.save_tickets()
                self.loaded.add(chunk)
        for chunk in list(self.owned - desired):
            self.console.remove_chunk(chunk)
            self.owned.remove(chunk)
            self.loaded.discard(chunk)
            self.save_tickets()
        self.save_tickets()

    def save_tickets(self):
        raw = json.dumps({"owned": sorted(self.owned), "centers": self.centers}) + "\n"
        if raw != self.saved_state:
            atomic(self.state, raw)
            self.saved_state = raw

    def calibrate(self, computer, folder, hb):
        path = folder / "assist.request"
        raw = path.read_text(encoding="ascii")
        f, before, _ = request(raw)
        if f[1:4] != hb[1:4] or f[5] != "anchor" or hb[8] != "waiting" or before != (0, 0, 0, 0):
            raise ValueError(f"Computer {computer}: new job needs its own calibrated anchor")
        position = self.console.position(int(computer))
        actual = self.console.observe(int(computer), position)
        if actual is None:
            raise RuntimeError("New job's live computer ID could not be verified")
        if path.read_text(encoding="ascii") != raw:
            raise RuntimeError("New job changed during calibration")
        current, pose = heartbeat((folder / "assist.heartbeat").read_text(encoding="ascii"))
        if current[:9] != hb[:9] or pose != (0, 0, 0, 0):
            raise RuntimeError("New job moved during calibration")
        binding = {"job": f[2], "home": list(actual[:3]), "seed": list(actual[:3]), "heading": actual[3]}
        self.bindings[computer] = binding
        atomic(self.anchor_state, json.dumps(self.bindings) + "\n")
        print(f"Computer {computer}: new job {f[2]} anchored at {actual}", flush=True)
        return binding

    def answer(self, computer, binding, folder, hb):
        path = folder / "assist.request"
        if not path.exists():
            return
        raw = path.read_text(encoding="ascii")
        f, before, after = request(raw)
        if f[1:4] != hb[1:4] or f[2] != binding["job"] or hb[8] != "waiting":
            return
        response = folder / "assist.response"
        if response.exists() and response.read_text(encoding="ascii").split("\t")[:5] == f[:5]:
            return
        observed = None
        for position in dict.fromkeys((world(binding, before)[:3], world(binding, after)[:3])):
            actual = self.console.observe(int(computer), position)
            if actual is not None:
                if observed is not None:
                    raise RuntimeError("Duplicate computer ID in both candidate cells")
                observed = actual
        if observed is None:
            raise RuntimeError(f"Computer {computer}: live turtle not found at either saved cell")
        if path.read_text(encoding="ascii") != raw:
            return
        current, _ = heartbeat((folder / "assist.heartbeat").read_text(encoding="ascii"))
        if current[:9] != hb[:9]:
            return
        actual = relative(binding, observed)
        # A differing pose is returned too: Lua enters recovery without moving.
        atomic(response, "\t".join(f[:5] + [str(v) for v in actual]) + "\n")
        print(f"Computer {computer}: observed {observed}, journal {f[3]} verified", flush=True)

    def step(self):
        records = []
        for computer, binding in self.bindings.items():
            folder = self.folder(computer)
            if not (folder / "server-assist").exists():
                continue
            position = binding["seed"]
            try:
                hb, pose = heartbeat((folder / "assist.heartbeat").read_text(encoding="ascii"))
                if hb[1] != computer:
                    raise ValueError("Heartbeat belongs to another computer")
                if hb[2] != binding["job"]:
                    binding = self.calibrate(computer, folder, hb)
                position = world(binding, pose)[:3]
                records.append((computer, binding, folder, hb))
            except FileNotFoundError:
                # Lua's replace-by-rename can briefly hide the heartbeat.
                # Keep the last confirmed ticket rather than jumping to seed.
                if computer in self.centers:
                    continue
            except ValueError as error:
                if self.last_error != str(error):
                    print(str(error), flush=True)
                self.last_error = str(error)
                continue
            self.centers[computer] = (position[0] // 16, position[2] // 16)
        self.tickets()
        for args in records:
            try:
                self.answer(*args)
            except (OSError, ValueError, RuntimeError) as error:
                if self.last_error != str(error):
                    print(str(error), flush=True)
                self.last_error = str(error)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--state", default="/var/lib/branchminer-assist/tickets.json")
    args = parser.parse_args()
    assist = Assist(json.loads(Path(args.config).read_text()), Console(), args.state)
    last_error = None
    while True:
        try:
            assist.step()
            last_error = None
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            if str(error) != last_error:
                print(str(error), flush=True)
            last_error = str(error)
        time.sleep(0.5)


if __name__ == "__main__":
    main()
