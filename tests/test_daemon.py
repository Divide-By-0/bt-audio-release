import importlib.util
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('daemon', Path(__file__).parents[1] / 'bt-audio-release.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Fake:
    def __init__(self):
        self.closed = False
        self.connected = True
        self.active = 1
        self.fail_switch = False
        self.fail_connect = False
        self.calls = []
    def __call__(self, *args):
        self.calls.append(args)
        if args[0] == 'ioreg':
            return 0, '"AppleClamshellState" = ' + ('Yes' if self.closed else 'No')
        if any(flag in args for flag in ('--paired', '--is-connected', '--disconnect', '--connect')):
            if '--paired' in args:
                return 0, '[{"name":"Headset", "address":"aa-bb", "connected":%s}]' % str(self.connected).lower()
            if '--is-connected' in args:
                return 0, '1' if self.connected else '0'
            if '--disconnect' in args:
                self.connected = False
            if '--connect' in args:
                if self.fail_connect:
                    return 2, ''
                self.connected = True
            return 0, ''
        if args[0] == 'SwitchAudioSource':
            return 0, 'Headset\nMacBook Pro Speakers' if '-a' in args else 'MacBook Pro Speakers'
        if '--is-active' in args:
            return self.active, ''
        return (2 if self.fail_switch else 0), 'auto-detected built-in speakers'
    def connects(self):
        return [c for c in self.calls if '--connect' in c]


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fake = Fake()
        self.now = 0
        self.daemon = m.Daemon(self.temp.name, self.fake, lambda: self.now)
    def test_idle_disconnect_does_not_bounce_or_restore_on_lid_open(self):
        self.daemon.poll()
        self.now = 301
        self.daemon.poll()
        self.assertFalse(self.fake.connected)
        self.fake.closed = True
        self.daemon.poll()
        self.fake.closed = False
        self.daemon.poll()
        self.assertEqual(self.fake.connects(), [])
    def test_lid_owned_disconnect_restores_once(self):
        self.fake.closed = True
        self.daemon.poll()
        self.assertFalse(self.fake.connected)
        self.fake.closed = False
        self.daemon.poll()
        self.daemon.poll()
        self.assertEqual(len(self.fake.connects()), 1)
    def test_failed_lid_reconnect_is_not_retried_by_audio(self):
        self.fake.closed = True
        self.daemon.poll()
        self.fake.closed = False
        self.fake.fail_connect = True
        self.daemon.poll()
        self.fake.active = 0
        self.daemon.poll()
        self.assertEqual(len(self.fake.connects()), 1)
    def test_manual_disconnect_never_claimed(self):
        self.fake.connected = False
        self.fake.closed = True
        self.daemon.poll()
        self.fake.closed = False
        self.daemon.poll()
        self.assertEqual(self.fake.connects(), [])
    def test_route_failure_does_not_disconnect_or_claim(self):
        self.fake.fail_switch = True
        self.fake.closed = True
        self.daemon.poll()
        self.assertTrue(self.fake.connected)
        self.assertEqual(self.daemon.lid_owned, {})
    def test_active_audio_and_unknown_activity_are_preserved(self):
        for activity in (0, 124, 2):
            self.fake.active = activity
            self.now += 1000
            self.daemon.poll()
            self.assertTrue(self.fake.connected)
    def test_restart_keeps_only_lid_ownership(self):
        self.fake.closed = True
        self.daemon.poll()
        restored = m.Daemon(self.temp.name, self.fake, lambda: self.now)
        self.fake.closed = False
        restored.poll()
        self.assertEqual(len(self.fake.connects()), 1)
    def test_notification_cannot_restore_lid_claim_without_open_edge(self):
        self.fake.closed = True
        self.daemon.poll()
        self.daemon.poll()
        self.assertEqual(self.fake.connects(), [])
    def test_policy_exits_when_host_is_stopped(self):
        module_path = str(Path(__file__).parents[1] / 'bt-audio-release.py')
        child_code = "import importlib.util; s=importlib.util.spec_from_file_location('bt',%r); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.Daemon.poll=lambda self: None; m.main()" % module_path
        host_code = "import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c',%r],stdout=subprocess.DEVNULL); print(p.pid,flush=True); time.sleep(30)" % child_code
        env = dict(os.environ, HOME=self.temp.name)
        host = subprocess.Popen([sys.executable, '-c', host_code], stdout=subprocess.PIPE, text=True, env=env)
        child_pid = int(host.stdout.readline())
        try:
            # Wait for the daemon to install its host watcher and signal handler.
            log = Path(self.temp.name) / '.local/bt-audio-release.log'
            deadline = time.monotonic() + 3
            while not log.exists() or 'started:' not in log.read_text():
                if time.monotonic() > deadline:
                    self.fail('policy startup timed out')
                time.sleep(.02)
            host.terminate()
            host.wait(timeout=2)
            deadline = time.monotonic() + 2
            while True:
                status = subprocess.run(['ps', '-p', str(child_pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                if not status or status.startswith('Z'):
                    break
                if time.monotonic() > deadline:
                    self.fail('policy child survived its host')
                time.sleep(.05)
        finally:
            if host.poll() is None:
                host.kill(); host.wait()
            host.stdout.close()
            try: os.kill(child_pid, signal.SIGTERM)
            except ProcessLookupError: pass
    def test_timeout_returns_and_kills_descendants(self):
        start = time.monotonic()
        rc, _ = m.command(sys.executable, '-c', 'import subprocess,time; subprocess.Popen(["sleep","30"]); time.sleep(30)', timeout=.1)
        self.assertEqual(rc, 124)
        self.assertLess(time.monotonic() - start, 2)


if __name__ == '__main__':
    unittest.main()
