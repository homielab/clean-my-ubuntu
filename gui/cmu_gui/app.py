"""Application entry point."""
import argparse
import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, Gtk  # noqa: E402

from .engine import Engine  # noqa: E402

APP_ID = "com.homielab.CleanMyUbuntu"

CSS = """
.size-large  { color: @error_color; }
.size-medium { color: @warning_color; }
.size-small  { color: @success_color; }
levelbar block.filled { background-color: @accent_bg_color; }
"""


class App(Adw.Application):
    def __init__(self, engine, selftest=False):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.engine = engine
        self.selftest = selftest

    def do_startup(self):
        Adw.Application.do_startup(self)
        Gtk.Window.set_default_icon_name(APP_ID)  # installed by `cmu --install`
        settings = Gtk.Settings.get_default()
        if settings.get_property("gtk-xft-dpi") <= 0:  # headless displays report no DPI
            settings.set_property("gtk-xft-dpi", 96 * 1024)
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        quit_action = Gio.SimpleAction(name="quit")
        quit_action.connect("activate", lambda *_: self.quit())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Control>q"])

    def do_activate(self):
        from .window import Window
        win = Window(self, self.engine)
        if getattr(self, "window_size", None):
            win.set_default_size(*self.window_size)
        win.present()
        if self.selftest:
            from .selftest import run
            run(self, win)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="clean-my-ubuntu --gui")
    parser.add_argument("--engine", default=os.environ.get("CMU_ENGINE"),
                        help="path to clean-my-ubuntu.sh")
    parser.add_argument("--dry-run", action="store_true", help="show what would happen, delete nothing")
    parser.add_argument("--selftest", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--screenshot", metavar="PNG", help=argparse.SUPPRESS)
    parser.add_argument("--scene", default="results", help=argparse.SUPPRESS)  # results details confirm done privacy ai
    parser.add_argument("--window-size", default="", help=argparse.SUPPRESS)  # e.g. 1280x800
    args = parser.parse_args(argv)
    engine_path = args.engine or os.path.join(os.path.dirname(__file__), "..", "..", "clean-my-ubuntu.sh")
    if not os.path.isfile(engine_path):
        print(f"Engine not found: {engine_path}", file=sys.stderr)
        return 2
    app = App(Engine(engine_path, dry_run=args.dry_run), selftest=args.selftest or bool(args.screenshot))
    app.selftest_failed = False
    app.screenshot = args.screenshot
    app.scene = args.scene
    app.window_size = tuple(int(x) for x in args.window_size.split("x")) if args.window_size else None
    status = app.run([sys.argv[0]])
    return 1 if app.selftest_failed else status
