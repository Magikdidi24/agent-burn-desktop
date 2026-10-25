# Tests du journal : masquage de chaque type de secret, fichier tournant dans le dossier des journaux,
# exceptions non rattrapées journalisées sans arrêter l'app, messages Qt sur le logger « qt ».
#   cd app && python -m unittest discover -s tests -v
import io
import logging
import logging.handlers
import re
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_app import gui  # noqa: E402

from PySide6.QtCore import QObject, QTimer, Signal, qInstallMessageHandler, qWarning  # noqa: E402

from agentburn import logs  # noqa: E402

SECRETS = {
    "jeton OAuth Anthropic": "sk-ant-oat01-Ab3_dE-fGhIjKlMnOpQrStUvWxYz0123456789",
    "en-tête Bearer": "Authorization: Bearer abc.DEF-ghi_123",
    "JWT": "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl",
    "access_token JSON": '{"access_token": "ya29-AbC_123", "x": 1}',
    "refreshToken": "refreshToken=rt_Q2Fz&next=1",
    "id_token": "id_token: idt.123.abc",
    "e-mail": "connecté en tant que jean.dupont+test@example.co.uk",
    "hex long": "clé 0123456789abcdef0123456789ABCDEF fin",
    "base64 long": "blob QWxhZGRpbjpvcGVuIHNlc2FtZQ0123456789xyz== fin",
    # Juste après « = » : variable d'environnement, code OAuth d'une URL, clé=valeur.
    "clé d'API après =": "OPENAI_API_KEY=sk-proj-Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56Qr78St90Uv12Wx34",
    "code OAuth d'une URL": "https://x/y?code=Zq81Rt5vWx0yAb2cDe4fGh6iJk8lMn0oPq2rSt4u&state=1",
    "hex après =": "key=fedcba9876543210fedcba9876543210ab01",
    # Erreur du CLI en Debug Rust : JSON aux guillemets échappés.
    "accessToken JSON échappé": 'Error: CliError("bad body: {\\"accessToken\\":\\"opaque.tok/en+with=chars\\"}")',
}
HIDDEN = {"sk-ant-oat01", "abc.DEF", "eyJhbGci", "ya29", "rt_Q2Fz", "idt.123", "jean.dupont", "example.co.uk",
          "0123456789abcdef0123456789ABCDEF", "QWxhZGRpbjpvcGVuIHNlc2FtZQ0123456789xyz", "sk-proj-Ab12", "Zq81Rt5v",
          "fedcba98", "opaque.tok"}


class Redaction(unittest.TestCase):
    def test_each_secret_kind_masked(self):
        for kind, text in SECRETS.items():
            out = logs.redact(text)
            self.assertIn(logs.MASK, out, kind)
            for secret in HIDDEN:
                self.assertNotIn(secret, out, kind)

    def test_ordinary_text_kept(self):
        for text in ("/tmp/build-1000/-home-sam/a1b2c3d4/agent-burn/app/tests/fake-agent-burn summary --json",
                     "/home/sam/.local/share/agent-burn-desktop/agent-burn-cli.json : code 0, 1.20 s, 4288 octets",
                     r"C:\Users\sam\AppData\Local\AgentBurn\logs", "révision 9ce6d8e1f9ae", "qml-f22edf61ad55",
                     "agent-burn a échoué (code 1) : Error: CliError(\"home directory is not set\")",
                     "unmotassezlongsanschiffrepourpasseravecuneregle", "QT_QPA_PLATFORMTHEME=xdgdesktopportal"):
            self.assertEqual(logs.redact(text), text)
        self.assertEqual(logs.redact(logs.redact(SECRETS["JWT"])), logs.redact(SECRETS["JWT"]))


class Setup(unittest.TestCase):
    def setUp(self):
        gui()
        root = logging.getLogger()
        saved = (list(root.handlers), root.level, sys.excepthook, threading.excepthook)

        def restore():
            for h in root.handlers[:]:
                if h not in saved[0]:
                    root.removeHandler(h)
                    h.close()
            root.setLevel(saved[1])
            sys.excepthook, threading.excepthook = saved[2], saved[3]
            qInstallMessageHandler(None)

        self.addCleanup(restore)
        self.dir = Path(tempfile.mkdtemp(prefix="agent-burn-logs-"))
        self.stderr = io.StringIO()
        self.qt = []
        self.path = logs.setup(self.dir / "logs", self.stderr, lambda kind, context, message: self.qt.append(message))

    def text(self):
        return self.path.read_text(encoding="utf-8")

    def test_rotating_file_in_log_dir(self):
        self.assertEqual(self.path, self.dir / "logs" / "agent-burn.log")
        h = next(h for h in logging.getLogger().handlers if isinstance(h, logging.handlers.RotatingFileHandler))
        self.assertEqual(Path(h.baseFilename), self.path)
        self.assertEqual((h.maxBytes, h.backupCount, h.encoding), (1 << 20, 3, "utf-8"))

    def test_lines_iso_time_level_logger_and_masked_on_every_handler(self):
        logging.getLogger("agentburn.cli").info("run : %s", SECRETS["jeton OAuth Anthropic"])
        line = self.text().splitlines()[-1]
        self.assertRegex(line, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d INFO agentburn\.cli : run : ")
        for out in (self.text(), self.stderr.getvalue()):
            self.assertIn(logs.MASK, out)
            self.assertNotIn("sk-ant-oat01", out)

    def test_debug_switch(self):
        logging.getLogger("agentburn").debug("détail 1")
        logs.debug(True)
        logging.getLogger("agentburn").debug("détail 2")
        logs.debug(False)
        self.assertNotIn("détail 1", self.text())
        self.assertIn("DEBUG agentburn : détail 2", self.text())

    def test_uncaught_exceptions_logged_and_app_keeps_running(self):
        try:
            raise ValueError("boum " + SECRETS["JWT"])
        except ValueError:
            sys.excepthook(*sys.exc_info())   # ne lève rien, ne quitte pas

        class Source(QObject):
            fired = Signal()

        def slot():
            raise RuntimeError("dans un slot")

        src = Source()
        src.fired.connect(slot)
        src.fired.emit()   # PySide passe l'exception à sys.excepthook et continue
        t = threading.Thread(target=lambda: 1 / 0, name="relevé")
        t.start()
        t.join()
        text = self.text()
        self.assertEqual(len(re.findall(r" CRITICAL agentburn : exception non rattrapée", text)), 3, text)
        self.assertIn("ValueError: boum", text)
        self.assertIn("Traceback (most recent call last)", text)
        self.assertNotIn("eyJhbGci", text)   # traceback masqué aussi
        self.assertIn("RuntimeError: dans un slot", text)
        self.assertIn("(thread relevé)", text)
        self.assertIn("ZeroDivisionError", text)

    def test_qt_messages_on_qt_logger_and_hook(self):
        qWarning("avertissement de test")
        self.assertIn("WARNING qt : avertissement de test", self.text())
        self.assertEqual(self.qt, ["avertissement de test"])

    def test_stderr_in_utf8_even_when_redirected_in_the_ansi_code_page(self):
        # Windows : stderr redirigé (selftest du build) en cp1252, à côté d'un journal UTF-8.
        raw = io.BytesIO()
        stream = io.TextIOWrapper(raw, encoding="cp1252")
        logs.setup(self.dir / "logs", stream)
        logging.getLogger("agentburn").warning("épinglé ✓")   # ✓ : hors de cp1252
        self.assertIn("épinglé ✓".encode("utf-8"), raw.getvalue())

    def test_unwritable_dir_still_logs_elsewhere(self):
        blocker = self.dir / "fichier"
        blocker.write_text("x")
        root = logging.getLogger()
        before = list(root.handlers)
        self.assertIsNone(logs.setup(blocker / "logs", self.stderr))
        self.assertIn("journal non écrit", self.stderr.getvalue())
        for h in root.handlers[:]:
            if h not in before:
                root.removeHandler(h)


if __name__ == "__main__":
    unittest.main()
