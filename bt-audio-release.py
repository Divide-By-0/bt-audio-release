#!/usr/bin/env python3
"""Release idle headsets; restore only our lid-close disconnections."""
import argparse
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import subprocess
import time

LOG = logging.getLogger("bt-audio-release")


def command(*args, timeout=None):
    """Bound the whole command group, including grandchildren holding pipes."""
    timeout = timeout or float(os.environ.get("BT_AUDIO_COMMAND_TIMEOUT", "8"))
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, err = proc.communicate()
        LOG.warning("command timeout: %s", args[0])
        return 124, out
    except BaseException:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        raise
    if proc.returncode not in (0, 1):
        LOG.warning("command failed: %s rc=%s %s", args[0], proc.returncode, err.strip()[:200])
    return proc.returncode, out.strip()


class Daemon:
    def __init__(self, state_dir, run=command, clock=time.monotonic):
        self.run, self.clock = run, clock
        self.helper = str(Path(__file__).parent / "bt-kill-a2dp")
        self.state_file = Path(state_dir) / "lid-state.json"
        self.idle_timeout = float(os.environ.get("BT_AUDIO_IDLE_TIMEOUT", "300"))
        self.idle_polls = int(os.environ.get("BT_AUDIO_IDLE_POLLS_BEFORE_RELEASE", "2"))
        self.last_active, self.streak = {}, {}
        self.previous_lid = None
        self.lid_owned = {}
        try:
            saved = json.loads(self.state_file.read_text())
            # Old claims must never survive indefinitely or migrate to another Mac.
            if time.time() - saved["saved_at"] < 86400:
                self.previous_lid = saved["closed"]
                self.lid_owned = saved["devices"]
        except (OSError, ValueError, KeyError, TypeError):
            pass

    def save(self):
        data = dict(saved_at=time.time(), closed=self.previous_lid, devices=self.lid_owned)
        temp = self.state_file.with_suffix(".tmp")
        temp.write_text(json.dumps(data))
        temp.replace(self.state_file)

    def read(self, *args):
        rc, out = self.run(*args)
        if rc != 0:
            raise RuntimeError("cannot read " + args[0])
        return out

    def snapshot(self):
        lid = self.read("ioreg", "-r", "-k", "AppleClamshellState", "-d", "4")
        if '"AppleClamshellState" = Yes' not in lid and '"AppleClamshellState" = No' not in lid:
            raise RuntimeError("lid state unavailable")
        closed = '"AppleClamshellState" = Yes' in lid
        devices = json.loads(self.read(self.helper, "--paired"))
        outputs = self.read("SwitchAudioSource", "-a", "-t", "output").splitlines()
        inputs = self.read("SwitchAudioSource", "-a", "-t", "input").splitlines()
        audio_names = set(outputs + inputs)
        connected = [d for d in devices if d.get("connected") and d.get("name") in audio_names]
        return closed, connected

    def release(self, device, reason):
        addr, name = device["address"], device["name"]
        # Native helper chooses built-in transport, switches input if this headset
        # is selected, and moves default/system output only when they use it.
        args = [self.helper, addr, "--release-input", "--mute"]
        if os.environ.get("BT_AUDIO_SPEAKERS"):
            args += ["--speakers", os.environ["BT_AUDIO_SPEAKERS"]]
        rc, detail = self.run(*args)
        if rc != 0:
            LOG.warning("release skipped: %s reason=%s route switch failed", name, reason)
            return False
        rc, _ = self.run(self.helper, "--disconnect", addr)
        if rc != 0:
            LOG.warning("disconnect failed: %s reason=%s", name, reason)
            return False
        rc, connected = self.run(self.helper, "--is-connected", addr)
        if rc != 0 or connected != "0":
            LOG.warning("disconnect unverified: %s reason=%s", name, reason)
            return False
        LOG.info("released: %s reason=%s %s", name, reason, detail.replace("\n", "; "))
        return True

    def restore_lid(self):
        # Consume claims on the edge. Failed attempts do not retry on notifications.
        owned, self.lid_owned = self.lid_owned, {}
        self.save()
        for addr, name in owned.items():
            rc, connected = self.run(self.helper, "--is-connected", addr)
            if rc != 0:
                LOG.warning("lid restore skipped: %s connection state unknown", name)
                continue
            if connected == "1":
                LOG.info("lid restore unnecessary: %s already connected", name)
                continue
            if connected != "0":
                continue
            output = self.read("SwitchAudioSource", "-c", "-t", "output")
            rc, _ = self.run(self.helper, "--connect", addr)
            if rc != 0:
                LOG.warning("lid restore failed: %s; no automatic retry", name)
                continue
            rc, connected = self.run(self.helper, "--is-connected", addr)
            if rc != 0 or connected != "1":
                LOG.warning("lid restore unverified: %s; no automatic retry", name)
                continue
            # macOS may automatically make a reconnected headset the default.
            # Keep prior output and built-in mic, instead of claiming its stream.
            rc, detail = self.run(self.helper, addr, "--release-input", "--mute")
            if rc == 0 and output != name:
                self.run("SwitchAudioSource", "-s", output, "-t", "output")
            LOG.info("lid restore: %s route_rc=%s %s", name, rc, detail.replace("\n", "; "))
            self.last_active[addr] = self.clock()
            self.streak[addr] = 0

    def poll(self):
        closed, devices = self.snapshot()
        just_opened = self.previous_lid is True and not closed
        self.previous_lid = closed
        if just_opened:
            self.restore_lid()
        now = self.clock()
        present = {d["address"] for d in devices}
        for addr in set(self.last_active) - present:
            self.last_active.pop(addr, None)
            self.streak.pop(addr, None)
        for device in devices:
            addr, name = device["address"], device["name"]
            if closed:
                if self.release(device, "lid closed"):
                    self.lid_owned[addr] = name
                    self.save()
                continue
            rc, _ = self.run(self.helper, addr, "--is-active")
            self.last_active.setdefault(addr, now)
            if rc == 0:
                self.last_active[addr], self.streak[addr] = now, 0
            elif rc == 1:
                self.streak[addr] = self.streak.get(addr, 0) + 1
                elapsed = now - self.last_active[addr]
                LOG.info("idle: %s %.0fs/%.0fs polls=%s", name, elapsed, self.idle_timeout, self.streak[addr])
                if elapsed >= self.idle_timeout and self.streak[addr] >= self.idle_polls:
                    if self.release(device, "idle"):
                        self.last_active.pop(addr, None)
                        self.streak.pop(addr, None)
                        # An idle release never creates a lid restore claim.
                        self.lid_owned.pop(addr, None)
            else:
                self.last_active[addr], self.streak[addr] = now, 0
                LOG.warning("activity unknown: %s rc=%s; leaving connected", name, rc)
        self.save()
        LOG.info("status: lid=%s connected_audio=%s lid_claims=%s", "closed" if closed else "open", len(devices), len(self.lid_owned))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    state_dir = Path.home() / ".local/state/bt-audio-release"
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = (state_dir / "daemon.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("bt-audio-release is already running")
    handler = RotatingFileHandler(Path.home() / ".local/bt-audio-release.log", maxBytes=1_000_000, backupCount=3)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)
    def terminate(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    daemon = Daemon(state_dir)
    LOG.info("started: reconnect=lid-owned-only idle_timeout=%s command_timeout=%s", daemon.idle_timeout, os.environ.get("BT_AUDIO_COMMAND_TIMEOUT", "8"))
    while True:
        try:
            daemon.poll()
        except (RuntimeError, OSError, ValueError, KeyError, TypeError) as exc:
            LOG.warning("poll skipped safely: %s", exc)
        if args.once:
            break
        time.sleep(max(1, float(os.environ.get("BT_AUDIO_POLL_INTERVAL", "15"))))


if __name__ == "__main__":
    main()
