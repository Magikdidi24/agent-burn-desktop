# App log: rotating file (1 MB × 3, UTF-8) in the logs directory, plus stderr outside the frozen
# exe; secrets redacted on every handler; Qt messages (QML warnings included) and uncaught exceptions
# (main thread, Qt slots, threads) logged, the app keeps running.
import datetime
import logging
import logging.handlers
import re
import sys
import threading
import traceback

from PySide6.QtCore import QtMsgType, qInstallMessageHandler

MASK = "[redacted]"
_B64 = r"A-Za-z0-9+_\-"
# shortcut: a base64 containing "/" is cut into pieces, each redacted only if it is ≥ 32 chars;
# add "/" to _B64 if such a secret shows up (paths longer than 32 chars would then be redacted).
_SECRETS = (
    # Also in escaped JSON (\"accessToken\":\"…\" of a CLI error in Rust Debug format).
    (re.compile(r"(?i)((?:access|refresh|id)[_-]?token\\?[\"']?\s*[:=]\s*\\?[\"']?)[^\s\"'\\,;}&]+"), r"\1" + MASK),
    (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]+"), r"\1" + MASK),
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]+"), MASK),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]*){0,2}"), MASK),   # JWT
    (re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"), MASK),   # email
    # hex or base64 of 32 chars or more, digits and letters mixed (a long word is not a secret), also
    # right after "=" (KEY=value, ?code= of a URL)
    (re.compile(rf"(?<![{_B64}])(?=[{_B64}]*[0-9])(?=[{_B64}]*[A-Za-z])[{_B64}]{{32,}}={{0,2}}"), MASK),
)
_LEVELS = {QtMsgType.QtDebugMsg: logging.DEBUG, QtMsgType.QtInfoMsg: logging.INFO, QtMsgType.QtWarningMsg: logging.WARNING,
           QtMsgType.QtCriticalMsg: logging.ERROR, QtMsgType.QtFatalMsg: logging.CRITICAL}
_qt_handler = None   # kept alive: Qt only keeps a pointer to it


def redact(text):
    for pattern, repl in _SECRETS:
        text = pattern.sub(repl, text)
    return text


class _Redact(logging.Filter):
    def filter(self, record):
        # Message, traceback and stack rendered here then redacted: the formatter has nothing left to add.
        text = record.getMessage()
        if record.exc_info:
            text += "\n" + "".join(traceback.format_exception(*record.exc_info)).rstrip()
        if record.stack_info:
            text += "\n" + record.stack_info
        record.msg, record.args, record.exc_info, record.exc_text, record.stack_info = redact(text), None, None, None, None
        return True


class _Format(logging.Formatter):
    def formatTime(self, record, datefmt=None):
        return datetime.datetime.fromtimestamp(record.created).astimezone().isoformat(timespec="milliseconds")


def _uncaught(kind, value, tb, where="main thread"):
    logging.getLogger("agentburn").critical("uncaught exception (%s)", where, exc_info=(kind, value, tb))


def setup(directory, stderr=None, qt_hook=None):
    """Root logger handlers, level INFO; qt_hook(kind, context, message) also receives every Qt message
    (selftest). Returns the log file, None if it could not be opened (stated in the log)."""
    global _qt_handler
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    handlers, path, problem = [], directory / "agent-burn.log", None
    try:
        directory.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.handlers.RotatingFileHandler(path, maxBytes=1 << 20, backupCount=3, encoding="utf-8"))
    except OSError as e:
        path, problem = None, e
    if stderr is not None:
        if hasattr(stderr, "reconfigure"):   # redirected on Windows: ANSI code page, unreadable next to the UTF-8 file
            stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
        handlers.append(logging.StreamHandler(stderr))
    for h in handlers:
        h.setFormatter(_Format("%(asctime)s %(levelname)s %(name)s: %(message)s"))
        h.addFilter(_Redact())
        root.addHandler(h)
    if problem:
        logging.getLogger("agentburn").warning("log not written to %s: %s", directory, problem)
    sys.excepthook = _uncaught
    threading.excepthook = lambda a: _uncaught(a.exc_type, a.exc_value, a.exc_traceback,
                                               f"thread {getattr(a.thread, 'name', '?')}")
    qt = logging.getLogger("qt")

    def on_qt(kind, context, message):
        category = context.category or "default"
        # Platform limit (raise() offscreen, selftest), not a problem: detailed log only.
        level = logging.DEBUG if message.startswith("This plugin does not support") else _LEVELS.get(kind, logging.WARNING)
        qt.log(level, "%s", message if category == "default" else f"{category}: {message}")
        if qt_hook:
            qt_hook(kind, context, message)

    _qt_handler = on_qt
    qInstallMessageHandler(on_qt)
    return path


def debug(on):
    """Detailed log (debugLogging setting), without restarting."""
    logging.getLogger().setLevel(logging.DEBUG if on else logging.INFO)
