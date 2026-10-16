"""Main window: sidebar on the left, the selected page on the right."""
import os
import shutil
import subprocess

from gi.repository import Adw, Gio, GLib, Gtk

from .engine import SMART_SCAN, Selection, human
from .scanpage import ScanPage

# (id, title, icon, categories, description) — same order as the terminal app's menu
PAGES = [
    ("smart", "Smart Scan", "starred-symbolic", SMART_SCAN,
     "Scan everything in one go and clean what you don't need. Nothing is removed until you confirm."),
    None,  # section: Cleanup
    ("system", "System Junk", "computer-symbolic", ["system"],
     "Package cache, unused packages and kernels, leftover configs, old Snap revisions, temp files."),
    ("logs", "Logs", "text-x-generic-symbolic", ["logs"],
     "Systemd journal, oversized and rotated logs, crash reports, old app logs."),
    ("user", "User & App Junk", "user-home-symbolic", ["user", "browser", "apps"],
     "Trash, thumbnails, stale caches — and every browser and app cache on its own."),
    ("ai", "AI Tools", "applications-science-symbolic", ["ai", "models"],
     "Caches, logs and old chat sessions of Claude, Codex, Gemini/Antigravity, opencode, Zed and more — "
     "and downloaded Ollama, Hugging Face and LM Studio models, each on its own."),
    ("dev", "Developer Junk", "applications-engineering-symbolic", ["dev"],
     "Stale node_modules, npm, pip, Go, Cargo, Conda, Docker and Podman leftovers."),
    ("privacy", "Privacy", "security-high-symbolic", ["privacy"],
     "Terminal history, recent files, run dialog and emoji history."),
]
REPO_URL = "https://github.com/homielab/clean-my-ubuntu"


class Window(Adw.ApplicationWindow):
    def __init__(self, app, engine):
        super().__init__(application=app, title="Clean My Ubuntu", default_width=1060, default_height=720,
                         width_request=360, height_request=320)
        self.engine = engine
        self.selection = Selection()
        self.pages = {}
        self._busy = 0

        # ── sidebar ──
        self.sidebar_list = Gtk.ListBox(css_classes=["navigation-sidebar"])
        self.sidebar_list.set_header_func(self._section_header)
        for spec in PAGES:
            if spec is None:
                continue
            pid, title, icon, _, _ = spec
            box = Gtk.Box(spacing=12)
            box.append(Gtk.Image(icon_name=icon))
            box.append(Gtk.Label(label=title, xalign=0))
            row = Gtk.ListBoxRow(child=box)
            row.page_id = pid
            self.sidebar_list.append(row)
        more = Gtk.Box(spacing=12)
        more.append(Gtk.Image(icon_name="utilities-terminal-symbolic"))
        more.append(Gtk.Label(label="All tools (terminal)", xalign=0))
        more_row = Gtk.ListBoxRow(child=more, tooltip_text="Space Lens, Duplicates, Uninstaller, Startup Items, "
                                                          "Maintenance, Settings… in the terminal app")
        more_row.page_id = "terminal"
        self.sidebar_list.append(more_row)
        self.sidebar_list.connect("row-activated", self._on_row_activated)

        self.disk_bar = Gtk.LevelBar(min_value=0, max_value=1)
        self.disk_label = Gtk.Label(xalign=0, css_classes=["caption", "dim-label"])
        disk = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6,
                       margin_start=12, margin_end=12, margin_top=6, margin_bottom=12)
        disk.append(self.disk_bar)
        disk.append(self.disk_label)

        menu = Gio.Menu()
        menu.append("Open the terminal app", "win.terminal")
        menu.append("Source code", "win.source")
        menu.append("Report a problem", "win.issues")
        menu.append("HomieLab", "win.homepage")
        menu.append("About Clean My Ubuntu", "win.about")
        side_header = Adw.HeaderBar()
        side_header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                                            tooltip_text="Main menu"))
        side = Adw.ToolbarView(content=Gtk.ScrolledWindow(child=self.sidebar_list, vexpand=True))
        side.add_top_bar(side_header)
        side.add_bottom_bar(disk)
        sidebar_page = Adw.NavigationPage(title="Clean My Ubuntu", child=side)

        # ── content ──
        self.content_stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.spinner = Gtk.Spinner()
        content_header = Adw.HeaderBar()
        content_header.pack_end(self.spinner)
        content = Adw.ToolbarView(content=self.content_stack)
        content.add_top_bar(content_header)
        if engine.dry_run:
            banner = Adw.Banner(title="Dry run — nothing will be deleted", revealed=True)
            content.add_top_bar(banner)
        self.content_page = Adw.NavigationPage(title="Smart Scan", child=content)

        self.split = Adw.NavigationSplitView(sidebar=sidebar_page, content=self.content_page,
                                             min_sidebar_width=220, max_sidebar_width=280)
        self.toasts = Adw.ToastOverlay(child=self.split)
        self.set_content(self.toasts)

        bp = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 640sp"))
        bp.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(bp)

        for name, cb in (("terminal", self.open_terminal), ("about", self.show_about),
                         ("source", lambda *_: self._open_url(REPO_URL)),
                         ("issues", lambda *_: self._open_url(REPO_URL + "/issues")),
                         ("homepage", lambda *_: self._open_url("https://homielab.com"))):
            action = Gio.SimpleAction(name=name)
            action.connect("activate", cb)
            self.add_action(action)

        self.refresh_disk()
        self.show_page("smart")
        self.sidebar_list.select_row(self.sidebar_list.get_row_at_index(0))

    # ── navigation ──
    def _section_header(self, row, before):
        titles = {"system": "Cleanup", "terminal": "More"}
        title = titles.get(getattr(row, "page_id", ""))
        if title:
            label = Gtk.Label(label=title, xalign=0, margin_start=12, margin_top=12, margin_bottom=6,
                              css_classes=["heading", "dim-label"])
            row.set_header(label)
        else:
            row.set_header(None)

    def _on_row_activated(self, _list, row):
        if row.page_id == "terminal":
            self.open_terminal()
            return
        self.show_page(row.page_id)
        self.split.set_show_content(True)

    def show_page(self, pid):
        spec = next(s for s in PAGES if s and s[0] == pid)
        if pid not in self.pages:
            page = ScanPage(self, spec[1], spec[3], spec[2], spec[4])
            self.pages[pid] = page
            self.content_stack.add_named(page, pid)
        self.content_stack.set_visible_child_name(pid)
        self.content_page.set_title(spec[1])

    # ── helpers used by pages ──
    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(text), timeout=4))

    def set_busy(self, busy):
        self._busy += 1 if busy else -1
        self.spinner.set_spinning(self._busy > 0)

    def refresh_disk(self):
        st = os.statvfs("/")
        total, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
        used = 1 - free / total if total else 0
        self.disk_bar.set_value(used)
        self.disk_label.set_text(f"{human(free)} free of {human(total)}")

    def open_terminal(self, *_):
        for term in ("x-terminal-emulator", "gnome-terminal", "ptyxis", "kgx"):
            if shutil.which(term):
                argv = [term, "--", "bash", self.engine.path] if term in ("gnome-terminal", "ptyxis", "kgx") \
                    else [term, "-e", f"bash {self.engine.path}"]
                if self.engine.dry_run:
                    argv[-1:] = [argv[-1] + " --dry-run"] if term == "x-terminal-emulator" else [argv[-1], "--dry-run"]
                subprocess.Popen(argv, start_new_session=True)
                return
        self.toast("No terminal app found — run cmu in a terminal.")

    def _open_url(self, url):
        Gtk.UriLauncher.new(url).launch(self, None, None)

    def show_about(self, *_):
        about = Adw.AboutDialog(
            application_name="Clean My Ubuntu", application_icon="com.homielab.CleanMyUbuntu",
            version=self.engine.version(), developer_name="HomieLab", developers=["HomieLab https://homielab.com"],
            copyright="© 2026 HomieLab", license_type=Gtk.License.MIT_X11, website=REPO_URL,
            issue_url=REPO_URL + "/issues",
            comments="A friendly system cleaner for Ubuntu, inspired by CleanMyMac. "
                     "Not affiliated with MacPaw.")
        about.present(self)
