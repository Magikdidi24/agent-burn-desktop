# Journal de l'app : fichier tournant (1 Mo × 3, UTF-8) dans le dossier des journaux, plus stderr hors
# exe gelé ; secrets masqués sur chaque handler ; messages Qt (avertissements QML compris) et exceptions
# non rattrapées (fil principal, slots Qt, threads) journalisés, l'app continue.
import datetime
import logging
import logging.handlers
import re
import sys
import threading
import traceback

from PySide6.QtCore import QtMsgType, qInstallMessageHandler

MASK = "[masqué]"
_B64 = r"A-Za-z0-9+_\-"
# shortcut: un base64 contenant « / » est coupé en morceaux, chacun masqué seulement s'il fait ≥ 32 car. ;
# ajouter « / » à _B64 si un tel secret apparaît (les chemins de plus de 32 car. seraient alors masqués).
_SECRETS = (
    (re.compile(r"(?i)((?:access|refresh|id)[_-]?token[\"']?\s*[:=]\s*[\"']?)[^\s\"',;}&]+"), r"\1" + MASK),
    (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]+"), r"\1" + MASK),
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]+"), MASK),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]*){0,2}"), MASK),   # JWT
    (re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"), MASK),   # e-mail
    # hex ou base64 de 32 car. et plus, chiffres et lettres mêlés (un mot long n'est pas un secret)
    (re.compile(rf"(?<![{_B64}=])(?=[{_B64}]*[0-9])(?=[{_B64}]*[A-Za-z])[{_B64}]{{32,}}={{0,2}}"), MASK),
)
_LEVELS = {QtMsgType.QtDebugMsg: logging.DEBUG, QtMsgType.QtInfoMsg: logging.INFO, QtMsgType.QtWarningMsg: logging.WARNING,
           QtMsgType.QtCriticalMsg: logging.ERROR, QtMsgType.QtFatalMsg: logging.CRITICAL}
_qt_handler = None   # gardé en vie : Qt n'en garde qu'un pointeur


def redact(text):
    for pattern, repl in _SECRETS:
        text = pattern.sub(repl, text)
    return text


class _Redact(logging.Filter):
    def filter(self, record):
        # Message, traceback et pile rendus ici puis masqués : le formateur n'a plus rien à ajouter.
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


def _uncaught(kind, value, tb, where="fil principal"):
    logging.getLogger("agentburn").critical("exception non rattrapée (%s)", where, exc_info=(kind, value, tb))


def setup(directory, stderr=None, qt_hook=None):
    """Handlers du logger racine, niveau INFO ; qt_hook(kind, context, message) reçoit aussi chaque message
    Qt (selftest). Renvoie le fichier du journal, None s'il n'a pas pu être ouvert (dit dans le journal)."""
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
        handlers.append(logging.StreamHandler(stderr))
    for h in handlers:
        h.setFormatter(_Format("%(asctime)s %(levelname)s %(name)s : %(message)s"))
        h.addFilter(_Redact())
        root.addHandler(h)
    if problem:
        logging.getLogger("agentburn").warning("journal non écrit dans %s : %s", directory, problem)
    sys.excepthook = _uncaught
    threading.excepthook = lambda a: _uncaught(a.exc_type, a.exc_value, a.exc_traceback,
                                               f"thread {getattr(a.thread, 'name', '?')}")
    qt = logging.getLogger("qt")

    def on_qt(kind, context, message):
        category = context.category or "default"
        qt.log(_LEVELS.get(kind, logging.WARNING), "%s", message if category == "default" else f"{category} : {message}")
        if qt_hook:
            qt_hook(kind, context, message)

    _qt_handler = on_qt
    qInstallMessageHandler(on_qt)
    return path


def debug(on):
    """Journal détaillé (réglage debugLogging), sans redémarrer."""
    logging.getLogger().setLevel(logging.DEBUG if on else logging.INFO)
