"""Talk to the cleaning engine: `clean-my-ubuntu.sh --json …`.

The GUI never decides what to delete itself. It runs the same tested engine as
the terminal app and reads one JSON event per line from it, asynchronously, so
the window never freezes.
"""
import json
import os

from gi.repository import Gio, GLib

# Same groups and order as the terminal app's Smart Scan.
CATEGORY_TITLES = {
    "system": "System Junk",
    "logs": "Logs",
    "user": "User Junk",
    "browser": "Browsers",
    "apps": "App Caches",
    "ai": "AI Tools",
    "models": "AI Models",
    "dev": "Developer Junk",
    "privacy": "Privacy",
}
SMART_SCAN = ["system", "logs", "user", "browser", "apps", "ai", "models", "dev"]


def human(n):
    """Bytes → '1.8 GB', identical to the engine's formatting."""
    n = int(n or 0)
    if n < 1024:
        return f"{n} B"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    d, i = 1, 0
    while n // d >= 1024 and i < 5:
        d, i = d * 1024, i + 1
    t = (n * 10 + d // 2) // d
    if t >= 10240 and i < 5:
        d, i = d * 1024, i + 1
        t = (n * 10 + d // 2) // d
    return f"{t // 10}.{t % 10} {units[i]}"


class Engine:
    """Runs `clean-my-ubuntu.sh --json …` and streams its events."""

    def __init__(self, path, dry_run=False):
        self.path = os.path.abspath(path)
        self.dry_run = dry_run

    def run(self, args, on_event, on_done, as_root=False):
        """Start the engine. on_event(dict) per event, on_done(ok, exit_status) at the end.

        Returns a Gio.Cancellable that stops it. With as_root, the command goes
        through pkexec (the standard Ubuntu password dialog).
        """
        argv = ["bash", self.path, "--json"]
        if as_root:
            argv = ["pkexec", self.path, "--json"]
        if self.dry_run:
            argv.append("--dry-run")
        argv += list(args)
        cancellable = Gio.Cancellable()
        try:
            proc = Gio.Subprocess.new(
                argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE
            )
        except GLib.Error as e:
            GLib.idle_add(on_event, {"event": "error", "message": e.message})
            GLib.idle_add(on_done, False, -1)
            return cancellable
        stream = Gio.DataInputStream.new(proc.get_stdout_pipe())
        cancellable.connect(lambda *_: proc.force_exit())

        def finished(p, result):
            try:
                p.wait_finish(result)
            except GLib.Error:
                pass
            status = p.get_exit_status() if p.get_if_exited() else -1
            on_done(status == 0, status)

        def got_line(s, result):
            try:
                line, _ = s.read_line_finish_utf8(result)
            except GLib.Error:
                line = None
            if line is None:  # end of output
                proc.wait_async(None, finished)
                return
            line = line.strip()
            if line:
                try:
                    on_event(json.loads(line))
                except ValueError:
                    pass  # never trust a stray line to be JSON
            s.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, got_line)

        stream.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, got_line)
        return cancellable

    # ── convenience wrappers ──
    def scan(self, categories, on_event, on_done):
        return self.run(["--only", ",".join(categories), "scan"], on_event, on_done)

    def details(self, item_id, on_event, on_done):
        return self.run(["details", item_id], on_event, on_done)

    def clean(self, ids, on_event, on_done, as_root=False):
        return self.run(["clean", *ids], on_event, on_done, as_root=as_root)

    def version(self):
        try:
            out = GLib.spawn_sync(None, ["bash", self.path, "--version"], None,
                                  GLib.SpawnFlags.SEARCH_PATH, None)[1]
            return out.decode().split()[-1]
        except (GLib.Error, IndexError):
            return "?"


class Selection:
    """Remembered choices, shared with the terminal app
    (~/.config/clean-my-ubuntu/selection, lines of `id=0|1`)."""

    def __init__(self):
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
        self.path = os.path.join(base, "clean-my-ubuntu", "selection")

    def _read(self):
        prefs = {}
        try:
            with open(self.path, encoding="utf-8") as f:
                for line in f:
                    k, _, v = line.strip().partition("=")
                    if k and v in ("0", "1"):
                        prefs[k] = v
        except OSError:
            pass
        return prefs

    def remember(self, item_id, selected):
        prefs = self._read()
        prefs[item_id] = "1" if selected else "0"
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(f"{k}={v}\n" for k, v in sorted(prefs.items()))
        os.replace(tmp, self.path)
