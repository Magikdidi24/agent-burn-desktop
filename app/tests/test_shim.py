# Tests of the desktop app's Quickshell shim: environment of launched processes (frozen bundle leaks,
# inherited CLI settings, HOME on Windows), stderr read before exited, working directory, run log,
# running declared before command, waiting for runs at shutdown, detached xdg-open.
#   cd app && python -m unittest discover -s tests -v
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP))

from PySide6.QtCore import QCoreApplication, QEventLoop, QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine  # noqa: E402

from agentburn import runtime, shim  # noqa: E402

# What the PyInstaller bootloader and the PySide6 hook set for the frozen app (observed on a Linux bundle).
LEAKS = {"LD_LIBRARY_PATH": "/bundle", "LD_LIBRARY_PATH_ORIG": "/opt/lib", "QT_PLUGIN_PATH": "/bundle/plugins",
         "QML2_IMPORT_PATH": "/bundle/qml", "QML_IMPORT_PATH": "/bundle/qml", "_PYI_ARCHIVE_FILE": "/bundle/AgentBurn",
         "_PYI_PARENT_PROCESS_LEVEL": "1"}

# Fake CLI: its environment and working directory on stdout, a CLI error on stderr.
CHILD = r'''import json, os, sys
names = ("AGENT_BURN_QUOTA_ONLY", "AGENT_BURN_FORCE_REFRESH", "LOG_LEVEL", "AB_DROP")
print(json.dumps({"cwd": os.getcwd(), **{n: os.environ.get(n) for n in names}}))
sys.stderr.write("WARN  before\n" + 'Error: CliError("no fixture")' + "\n")
sys.exit(int(sys.argv[1]))
'''

# Like a Cli of Burn.qml: collectors read in exited, explicit environment (null = removed).
QML = b'''import Quickshell.Io
import QtQuick
Process {
    property string out
    property string err
    property int code: -1
    environment: ({ AGENT_BURN_QUOTA_ONLY: "1", AB_DROP: null })
    stdout: StdioCollector { id: o }
    stderr: StdioCollector { id: e }
    onExited: c => { out = o.text; err = e.text; code = c; }
}
'''

# running: true written before command: (declaration order of Stats.qml): qs starts it after loading.
DECL = '''import Quickshell.Io
import QtQuick
Process {
    id: proc
    property string out
    property int starts: 0
    running: true
    command: [%s, "-I", "-c", "print('started-ok')"]
    stdout: StdioCollector { onStreamFinished: proc.out = text.trim() }
    onStarted: starts++
}
'''

tmp = data = None


def setUpModule():
    global tmp, data
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    QCoreApplication.setApplicationName("AgentBurn")
    QGuiApplication.instance() or QGuiApplication([])
    tmp = Path(tempfile.mkdtemp(prefix="agent-burn-shim-"))
    data = tmp / "data"
    qml = runtime.assemble()
    if shim._global is None:
        shim.register(qml, data)
    else:   # already done by test_app: a 2nd registration of the types makes them incompatible (PySide)
        shim._global = shim.QuickshellGlobal(data, qml)
    (tmp / "child.py").write_text(CHILD, encoding="utf-8")


def tearDownModule():
    shutil.rmtree(tmp, ignore_errors=True)


def env_of(e):
    return dict(kv.split("=", 1) for kv in e.toStringList())


def frozen():
    return mock.patch.object(sys, "frozen", True, create=True)


def wait_for(cond, seconds=10):
    end = time.monotonic() + seconds
    while not cond() and time.monotonic() < end:
        QCoreApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 50)
    return cond()


class ChildEnvironment(unittest.TestCase):
    def test_app_own_render_loop_not_inherited_user_one_kept(self):
        with mock.patch.dict(os.environ, {"QSG_RENDER_LOOP": "basic"}), mock.patch.object(shim, "APP_VARS", {"QSG_RENDER_LOOP"}):
            self.assertNotIn("QSG_RENDER_LOOP", env_of(shim.child_environment()))
        with mock.patch.dict(os.environ, {"QSG_RENDER_LOOP": "threaded"}), mock.patch.object(shim, "APP_VARS", set()):
            self.assertEqual(env_of(shim.child_environment()).get("QSG_RENDER_LOOP"), "threaded")

    def test_frozen_bundle_leaks_removed_library_path_restored(self):
        with mock.patch.dict(os.environ, LEAKS), frozen():
            env = env_of(shim.child_environment())
        self.assertEqual(env.get("LD_LIBRARY_PATH"), "/opt/lib")   # value from before the bootloader
        for name in LEAKS.keys() - {"LD_LIBRARY_PATH"}:
            self.assertNotIn(name, env)

    def test_frozen_without_original_library_path_drops_it(self):
        leaks = {k: v for k, v in LEAKS.items() if k != "LD_LIBRARY_PATH_ORIG"}
        with mock.patch.dict(os.environ, leaks), frozen():
            self.assertNotIn("LD_LIBRARY_PATH", env_of(shim.child_environment()))

    def test_dev_run_keeps_library_paths(self):
        with mock.patch.dict(os.environ, LEAKS):
            env = env_of(shim.child_environment())
        self.assertEqual(env.get("LD_LIBRARY_PATH"), "/bundle")
        self.assertEqual(env.get("QT_PLUGIN_PATH"), "/bundle/plugins")

    def test_inherited_cli_settings_removed_others_kept(self):
        with mock.patch.dict(os.environ, {"AGENT_BURN_QUOTA_ONLY": "1", "AGENT_BURN_FORCE_REFRESH": "1", "LOG_LEVEL": "5",
                                          "AGENT_BURN_FAKE_DIR": "/fixtures", "CODEX_HOME": "/codex"}):
            env = env_of(shim.child_environment())
        for name in ("AGENT_BURN_QUOTA_ONLY", "AGENT_BURN_FORCE_REFRESH", "LOG_LEVEL"):
            self.assertNotIn(name, env)
        self.assertEqual(env.get("AGENT_BURN_FAKE_DIR"), "/fixtures")   # fake CLI of the frozen selftest
        self.assertEqual(env.get("CODEX_HOME"), "/codex")

    def test_windows_home_is_userprofile(self):
        with mock.patch.dict(os.environ, {"HOME": "/elsewhere", "USERPROFILE": r"C:\Users\me"}), \
                mock.patch.object(sys, "platform", "win32"):
            env = env_of(shim.child_environment())
        self.assertEqual(env["HOME"], r"C:\Users\me")

    def test_linux_home_untouched(self):
        with mock.patch.dict(os.environ, {"HOME": "/home/me", "USERPROFILE": "/nope"}), \
                mock.patch.object(sys, "platform", "linux"):
            self.assertEqual(env_of(shim.child_environment())["HOME"], "/home/me")


def create(test, qml):
    engine = QQmlEngine()
    component = QQmlComponent(engine)
    component.setData(qml, QUrl.fromLocalFile(str(tmp / "t.qml")))
    p = component.create()
    test.assertIsNotNone(p, [e.toString() for e in component.errors()])
    test.qml = getattr(test, "qml", ()) + (engine, component, p)   # alive until the end of the test
    return p


def sleeper(seconds):
    return [sys.executable, "-I", "-c", f"import time; time.sleep({seconds})"]


class Runs(unittest.TestCase):   # no tests: base of the classes that start a run
    def start_child(self, command):
        p = create(self, QML)
        p.setProperty("command", command)
        p.setProperty("running", True)
        return p

    def run_child(self, command):
        p = self.start_child(command)
        self.assertTrue(wait_for(lambda: not p.property("running")), "run never ended")
        return p


class ProcessRun(Runs):
    def test_stderr_working_dir_environment_and_log(self):
        with mock.patch.dict(os.environ, {"AGENT_BURN_FORCE_REFRESH": "1", "LOG_LEVEL": "5", "AB_DROP": "x"}), \
                self.assertLogs("agentburn.cli", "INFO") as logs:
            p = self.run_child([sys.executable, "-I", str(tmp / "child.py"), "3"])
        self.assertEqual(p.property("code"), 3)
        out = json.loads(p.property("out"))
        self.assertEqual(Path(out["cwd"]).resolve(), data.resolve())   # not the app's working directory
        self.assertEqual(out["AGENT_BURN_QUOTA_ONLY"], "1")             # set by the QML
        self.assertIsNone(out["AGENT_BURN_FORCE_REFRESH"])              # inherited: removed
        self.assertIsNone(out["LOG_LEVEL"])
        self.assertIsNone(out["AB_DROP"])                               # QML null: removed
        self.assertEqual(p.property("err").splitlines(), ["WARN  before", 'Error: CliError("no fixture")'])
        info = [r.getMessage() for r in logs.records if r.levelname == "INFO"]
        warn = [r.getMessage() for r in logs.records if r.levelname == "WARNING"]
        self.assertEqual(len(info), 1, logs.output)
        self.assertIn("child.py 3: code 3,", info[0])
        self.assertTrue(info[0].endswith(f" {len(p.property('out').encode())} bytes"), info[0])
        self.assertEqual(len(warn), 1, logs.output)
        self.assertTrue(warn[0].endswith(': Error: CliError("no fixture")'), warn[0])   # the Error: line, not the WARN
        self.assertNotIn(str(data.resolve()), "\n".join(logs.output))   # stdout never logged

    def test_success_logs_one_info_line(self):
        with self.assertLogs("agentburn.cli", "INFO") as logs:
            p = self.run_child([sys.executable, "-I", str(tmp / "child.py"), "0"])
        self.assertEqual(p.property("code"), 0)
        self.assertEqual([r.levelname for r in logs.records], ["INFO"])

    def test_missing_binary_logged(self):
        with self.assertLogs("agentburn.cli", "WARNING") as logs:
            p = self.run_child([str(tmp / "absent")])
        self.assertEqual(p.property("code"), -1)   # no exited: Burn.qml sees it through running without started
        self.assertIn("cannot launch", logs.output[0])

    def test_stderr_tail_logged_at_debug_only(self):
        with self.assertLogs("agentburn.cli", "DEBUG") as logs:
            self.run_child([sys.executable, "-I", str(tmp / "child.py"), "0"])
            self.run_child([sys.executable, "-I", "-c", "import sys; sys.stderr.write('start' + 'x' * 5000 + 'end')"])
        debug = [r.getMessage() for r in logs.records if r.levelname == "DEBUG"]
        self.assertEqual(len(debug), 2, logs.output)
        lines = debug[0].splitlines()
        self.assertTrue(lines[0].endswith("child.py 0: stderr"), lines[0])
        self.assertEqual(lines[1:], ["WARN  before", 'Error: CliError("no fixture")'])
        self.assertEqual(debug[1].split(": stderr\n")[1], ("x" * 5000 + "end")[-4000:])   # the end only
        with self.assertLogs("agentburn.cli", "INFO") as logs:
            self.run_child([sys.executable, "-I", str(tmp / "child.py"), "0"])
        self.assertNotIn("WARN  before", "\n".join(logs.output))   # INFO level: no stderr from a successful run


class DeclaredRunning(unittest.TestCase):
    def test_running_before_command_starts_after_creation(self):
        p = create(self, (DECL % json.dumps(sys.executable)).encode())
        self.assertTrue(wait_for(lambda: p.property("out") == "started-ok"), "run never started")
        self.assertEqual(p.property("starts"), 1)

    def test_running_cleared_before_the_start_cancels_it(self):
        p = create(self, (DECL % json.dumps(sys.executable)).encode())
        p.setProperty("running", False)
        wait_for(lambda: False, 0.5)
        self.assertEqual(p.property("starts"), 0)


class WaitForRuns(Runs):
    def setUp(self):
        self.addCleanup(setattr, shim, "_closing", False)   # simulated shutdown: runs allowed again afterwards

    def test_waits_for_the_running_cli(self):
        p = self.start_child(sleeper(1))
        t0 = time.monotonic()
        self.assertTrue(shim.wait_for_runs(10000))
        self.assertLess(time.monotonic() - t0, 9)
        self.assertEqual(p.property("code"), 0)   # exited received during the wait, without an event loop
        self.assertFalse(p.property("running"))

    def test_bounded_and_no_run_started_afterwards(self):
        p = self.start_child(sleeper(30))

        def stop():
            with self.assertLogs("agentburn.cli", "WARNING"):   # killed, logged
                p.signal(9)
                self.assertTrue(wait_for(lambda: not p.property("running")))
        self.addCleanup(stop)
        t0 = time.monotonic()
        self.assertFalse(shim.wait_for_runs(300))
        self.assertLess(time.monotonic() - t0, 5)
        self.assertTrue(p.property("running"))
        q = self.start_child(sleeper(0))   # app shutting down: never started, it would be killed
        self.assertFalse(wait_for(lambda: q.property("running") or q.property("code") != -1, 0.5))


class Detached(unittest.TestCase):
    @unittest.skipIf(sys.platform == "win32", "xdg-open: Linux")
    def test_xdg_open_started_with_clean_environment(self):
        bin_dir, dump = tmp / "bin", tmp / "xdg-open.txt"
        bin_dir.mkdir(exist_ok=True)
        (bin_dir / "xdg-open").write_text(f'#!/bin/sh\n{{ echo "$1"; pwd; env; }} > "{dump}.part" && mv "{dump}.part" "{dump}"\n')
        (bin_dir / "xdg-open").chmod(0o755)
        with mock.patch.dict(os.environ, {**LEAKS, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}), frozen():
            shim._global.execDetached(["xdg-open", "/some/dir"])
        self.assertTrue(wait_for(dump.exists), "xdg-open never launched")
        lines = dump.read_text().splitlines()
        self.assertEqual(lines[0], "/some/dir")
        self.assertEqual(Path(lines[1]).resolve(), data.resolve())
        env = dict(x.split("=", 1) for x in lines[2:] if "=" in x)
        self.assertEqual(env.get("LD_LIBRARY_PATH"), "/opt/lib")
        for name in ("QT_PLUGIN_PATH", "_PYI_ARCHIVE_FILE", "LD_LIBRARY_PATH_ORIG"):
            self.assertNotIn(name, env)

    def test_windows_xdg_open_goes_to_the_explorer(self):
        path = r"C:\Users\me\AppData\Roaming\AgentBurn"
        with mock.patch.object(sys, "platform", "win32"), mock.patch.object(shim, "QDesktopServices") as services:
            shim._global.execDetached(["xdg-open", path])
        services.openUrl.assert_called_once_with(QUrl.fromUserInput(path))


if __name__ == "__main__":
    unittest.main()
