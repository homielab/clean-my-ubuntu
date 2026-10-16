"""One scan page: start → scanning → results (checkboxes, sizes) → cleaning."""
from gi.repository import Adw, GLib, Gtk, Pango

from .engine import CATEGORY_TITLES, human


def size_class(n):
    if n >= 1 << 30:
        return "size-large"
    if n >= 100 << 20:
        return "size-medium"
    return "size-small" if n > 0 else "dim-label"


class ScanPage(Gtk.Box):
    """Scan some categories, review the results, clean the selection."""

    def __init__(self, window, title, categories, icon, description):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.engine = window.engine
        self.title = title
        self.categories = categories
        self.privacy = categories == ["privacy"]
        self.items = {}  # id → item event (from the last scan)
        self.selected = {}  # id → bool
        self.checks = {}  # id → Gtk.CheckButton
        self.group_buttons = []  # (button, ids) — "Select all" / "Deselect all"
        self.running = None  # Gio.Cancellable of the current engine run

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.append(self.stack)

        # 1. start
        button = Gtk.Button(label="Scan", halign=Gtk.Align.CENTER)
        button.add_css_class("pill")
        button.add_css_class("suggested-action")
        button.connect("clicked", lambda *_: self.scan())
        start = Adw.StatusPage(icon_name=icon, title=title, description=description, child=button)
        self.stack.add_named(start, "start")

        # 2. scanning
        self.progress = Gtk.ProgressBar(show_text=False, width_request=320, halign=Gtk.Align.CENTER)
        self.progress_label = Gtk.Label(css_classes=["dim-label"], ellipsize=Pango.EllipsizeMode.END)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER)
        box.append(self.progress)
        box.append(self.progress_label)
        scanning = Adw.StatusPage(icon_name="system-search-symbolic", title="Scanning…", child=box)
        self.stack.add_named(scanning, "scanning")

        # 3. results (filled in by show_results)
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                               margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        clamp = Adw.Clamp(maximum_size=820, child=self.results)
        self.stack.add_named(Gtk.ScrolledWindow(child=clamp, vexpand=True,
                                                hscrollbar_policy=Gtk.PolicyType.NEVER), "results")

        # 4. cleaning
        self.clean_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
        self.clean_progress = Gtk.ProgressBar()
        self.clean_title = Gtk.Label(css_classes=["title-2"], xalign=0)
        cbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18,
                       margin_top=24, margin_bottom=24, margin_start=12, margin_end=12)
        cbox.append(self.clean_title)
        cbox.append(self.clean_progress)
        cbox.append(self.clean_list)
        self.stack.add_named(Gtk.ScrolledWindow(child=Adw.Clamp(maximum_size=820, child=cbox),
                                                vexpand=True), "cleaning")

        # bottom bar: selection summary + Clean
        self.bar = Gtk.ActionBar(revealed=False)
        self.summary = Gtk.Label(xalign=0)
        self.bar.pack_start(self.summary)
        self.clean_button = Gtk.Button(label="Clear" if self.privacy else "Clean")
        self.clean_button.add_css_class("suggested-action")
        self.clean_button.connect("clicked", lambda *_: self.confirm_clean())
        self.bar.pack_end(self.clean_button)
        rescan = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Scan again")
        rescan.connect("clicked", lambda *_: self.scan())
        self.bar.pack_end(rescan)
        self.append(self.bar)

    # ── scanning ──
    def scan(self):
        if self.running:
            return
        self.items.clear()
        self.progress.set_fraction(0)
        self.progress_label.set_text("Starting…")
        self.stack.set_visible_child_name("scanning")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] == "progress":
                self.progress.set_fraction(e["done"] / max(e["total"], 1))
                self.progress_label.set_text(f"Checking {e['current']}…" if e["current"] else "")
            elif e["event"] == "item":
                self.items[e["id"]] = e
            elif e["event"] == "done":
                self.scan_info = e

        def on_done(ok, status):
            self.running = None
            self.window.set_busy(False)
            if not ok and not self.items:
                self.window.toast("The scan failed — try the terminal app (cmu) for details.")
                self.stack.set_visible_child_name("start")
                return
            self.show_results()

        self.running = self.engine.scan(self.categories, on_event, on_done)

    # ── results ──
    def show_results(self):
        child = self.results.get_first_child()
        while child:
            self.results.remove(child)
            child = self.results.get_first_child()
        self.checks.clear()
        self.group_buttons.clear()
        self.selected = {i: e["selected"] for i, e in self.items.items() if e["status"] == "found"}

        found = [e for e in self.items.values() if e["status"] == "found"]
        total = sum(e["bytes"] for e in found)
        if self.privacy:
            head = f"{len(found)} history lists with entries" if found else "Nothing to clear"
            sub = "Pick what to clear — nothing happens until you confirm."
        elif found:
            head = f"{human(total)} of junk found in {len(found)} items"
            sub = f"{getattr(self, 'scan_info', {}).get('locations', 0)} locations scanned in " \
                  f"{getattr(self, 'scan_info', {}).get('ms', 0) / 1000:.1f}s"
        else:
            head, sub = "Your system is clean", "Nothing worth removing was found."
        title = Gtk.Label(label=head, xalign=0, wrap=True, css_classes=["title-1"])
        subtitle = Gtk.Label(label=sub, xalign=0, css_classes=["dim-label"])
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        header.append(title)
        header.append(subtitle)
        self.results.append(header)

        biggest = max([e["bytes"] for e in found] or [1])
        for cat in self.categories:
            items = [e for e in self.items.values() if e["category"] == cat]
            if not items:
                continue
            junk = sorted((e for e in items if e["status"] == "found"), key=lambda e: -e["bytes"])
            clean = [e for e in items if e["status"] != "found"]
            group = Adw.PreferencesGroup(title=CATEGORY_TITLES.get(cat, cat))
            if junk and not self.privacy:
                group.set_description(human(sum(e["bytes"] for e in junk)))
            if len(junk) > 1:
                toggle = Gtk.Button(label="Select all", valign=Gtk.Align.CENTER, css_classes=["flat"])
                toggle.connect("clicked", self.on_group_toggle, [e["id"] for e in junk])
                group.set_header_suffix(toggle)
                self.group_buttons.append((toggle, [e["id"] for e in junk]))
            for e in junk:
                group.add(self.item_row(e, biggest))
            if clean:
                more = Adw.ExpanderRow(title=f"{len(clean)} more {'item is' if len(clean) == 1 else 'items are'} clean",
                                       use_markup=False)
                more.add_prefix(Gtk.Image(icon_name="emblem-ok-symbolic", css_classes=["success"]))
                for e in clean:
                    row = Adw.ActionRow(title=e["label"], subtitle=e["note"] or "clean", use_markup=False)
                    row.add_css_class("dim-label")
                    more.add_row(row)
                group.add(more)
            self.results.append(group)

        self.stack.set_visible_child_name("results")
        self.bar.set_revealed(bool(found))
        self.update_summary()

    def item_row(self, e, biggest):
        row = Adw.ActionRow(title=e["label"], subtitle=e["note"], use_markup=False,
                            subtitle_lines=1, tooltip_text=e["description"])
        check = Gtk.CheckButton(active=self.selected.get(e["id"], False), valign=Gtk.Align.CENTER)
        check.connect("toggled", self.on_toggled, e["id"])
        self.checks[e["id"]] = check
        row.add_prefix(check)
        row.set_activatable_widget(check)
        if e["root"]:
            row.add_suffix(Gtk.Image(icon_name="system-lock-screen-symbolic", tooltip_text="Needs your password"))
        if not self.privacy:
            bar = Gtk.LevelBar(min_value=0, max_value=1, value=max(e["bytes"] / biggest, 0.02),
                               width_request=90, valign=Gtk.Align.CENTER)
            bar.remove_offset_value("low")
            bar.remove_offset_value("high")
            bar.remove_offset_value("full")
            row.add_suffix(bar)
            size = Gtk.Label(label=human(e["bytes"]), width_chars=9, xalign=1,
                             css_classes=["numeric", size_class(e["bytes"])])
            row.add_suffix(size)
        info = Gtk.Button(icon_name="go-next-symbolic", valign=Gtk.Align.CENTER,
                          css_classes=["flat"], tooltip_text="Show what's inside")
        info.connect("clicked", lambda *_: self.show_details(e))
        row.add_suffix(info)
        return row

    def on_toggled(self, check, item_id):
        self.selected[item_id] = check.get_active()
        self.window.selection.remember(item_id, check.get_active())
        self.update_summary()

    def on_group_toggle(self, button, ids):
        target = not all(self.selected.get(i) for i in ids)
        for i in ids:
            self.checks[i].set_active(target)

    def update_summary(self):
        ids = [i for i, on in self.selected.items() if on]
        if self.privacy:
            self.summary.set_text(f"{len(ids)} selected")
        else:
            self.summary.set_markup(
                f"Selected <b>{human(sum(self.items[i]['bytes'] for i in ids))}</b> in {len(ids)} "
                f"item{'s' if len(ids) != 1 else ''}")
        self.clean_button.set_sensitive(bool(ids))
        for button, group_ids in self.group_buttons:
            button.set_label("Deselect all" if all(self.selected.get(i) for i in group_ids) else "Select all")

    # ── details ──
    def show_details(self, e):
        text = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                            top_margin=12, bottom_margin=12, left_margin=12, right_margin=12)
        text.get_buffer().set_text("Collecting details…")
        desc = Gtk.Label(label=e["description"], wrap=True, xalign=0,
                         margin_start=12, margin_end=12, margin_top=6, css_classes=["dim-label"])
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(desc)
        box.append(Gtk.ScrolledWindow(child=text, vexpand=True))
        toolbar = Adw.ToolbarView(content=box)
        toolbar.add_top_bar(Adw.HeaderBar())
        dialog = Adw.Dialog(title=e["label"], child=toolbar, content_width=640, content_height=440)
        dialog.present(self.window)

        lines = []

        def on_event(ev):
            if ev["event"] == "details":
                lines.extend(ev["lines"])

        def on_done(ok, status):
            text.get_buffer().set_text("\n".join(lines) if lines else "Nothing more to show.")

        self.engine.details(e["id"], on_event, on_done)

    # ── cleaning ──
    def confirm_clean(self):
        ids = [i for i, on in self.selected.items() if on]
        if not ids:
            return
        total = sum(self.items[i]["bytes"] for i in ids)
        needs_root = any(self.items[i]["root"] for i in ids)
        lines = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for i in ids[:12]:
            e = self.items[i]
            row = Gtk.Box(spacing=12)
            row.append(Gtk.Label(label=e["label"], xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            if e["root"]:
                row.append(Gtk.Image(icon_name="system-lock-screen-symbolic"))
            if not self.privacy:
                row.append(Gtk.Label(label=human(e["bytes"]), css_classes=["numeric", "dim-label"]))
            lines.append(row)
        if len(ids) > 12:
            lines.append(Gtk.Label(label=f"… and {len(ids) - 12} more", xalign=0, css_classes=["dim-label"]))

        if self.privacy:
            heading, body = f"Clear {len(ids)} history list{'s' if len(ids) != 1 else ''}?", "This can't be undone."
        else:
            heading = f"Clean {len(ids)} item{'s' if len(ids) != 1 else ''}?"
            body = f"About {human(total)} will be removed."
        if needs_root:
            body += " Items with a lock need your password."
        dialog = Adw.AlertDialog(heading=heading, body=body, extra_child=lines)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("clean", "Clear" if self.privacy else "Clean")
        dialog.set_response_appearance("clean", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("clean")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda d, r: r == "clean" and self.clean(ids))
        dialog.present(self.window)

    def clean(self, ids):
        user_ids = [i for i in ids if not self.items[i]["root"]]
        root_ids = [i for i in ids if self.items[i]["root"]]
        self.task_rows = {}
        self.freed = 0
        self.done_count = 0
        self.total_count = len(ids)
        child = self.clean_list.get_first_child()
        while child:
            self.clean_list.remove(child)
            child = self.clean_list.get_first_child()
        for i in user_ids + root_ids:
            row = Adw.ActionRow(title=self.items[i]["label"], subtitle="waiting", use_markup=False)
            spinner = Gtk.Image(icon_name="content-loading-symbolic", css_classes=["dim-label"])
            row.add_prefix(spinner)
            row.icon = spinner
            self.clean_list.append(row)
            self.task_rows[i] = row
        self.clean_title.set_text("Cleaning…")
        self.clean_progress.set_fraction(0)
        self.stack.set_visible_child_name("cleaning")
        self.bar.set_revealed(False)
        self.window.set_busy(True)

        def on_event(e):
            if e["event"] != "task" or e["id"] not in self.task_rows:
                return
            row = self.task_rows[e["id"]]
            if e["state"] == "run":
                row.set_subtitle("working…")
                return
            icon = {"ok": "emblem-ok-symbolic", "skip": "dialog-warning-symbolic"}.get(e["state"], "dialog-error-symbolic")
            row.icon.set_from_icon_name(icon)
            row.icon.set_css_classes([{"ok": "success", "skip": "warning"}.get(e["state"], "error")])
            row.set_subtitle(e["info"] or e["state"])
            self.freed += e["freed"]
            self.done_count += 1
            self.clean_progress.set_fraction(self.done_count / max(self.total_count, 1))

        def run_root():
            if not root_ids:
                return finish()
            for i in root_ids:
                self.task_rows[i].set_subtitle("waiting for your password…")
            self.engine.clean(root_ids, on_event, root_done, as_root=True)

        def root_done(ok, status):
            if status in (126, 127):  # password dialog dismissed / not authorized
                for i in root_ids:
                    row = self.task_rows[i]
                    if row.get_subtitle().startswith("waiting"):
                        row.icon.set_from_icon_name("dialog-warning-symbolic")
                        row.icon.set_css_classes(["warning"])
                        row.set_subtitle("Skipped — no password was entered")
            finish()

        def finish():
            self.window.set_busy(False)
            if self.engine.dry_run:
                msg = f"Dry run: {human(self.freed)} would be freed"
            elif self.privacy:
                msg = "History cleared"
            else:
                msg = f"Freed {human(self.freed)}"
            self.clean_title.set_text(msg)
            self.window.toast(msg)
            self.window.refresh_disk()
            GLib.timeout_add(1200, lambda: (self.scan(), False)[1])

        if user_ids:
            self.engine.clean(user_ids, on_event, lambda ok, st: run_root())
        else:
            run_root()
