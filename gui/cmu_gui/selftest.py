"""`--selftest`: drive the real window like a user would, print results, quit.

Used by tests/gui_smoke.sh on a virtual display. Only cleans in dry-run mode and
never touches system items (so no password prompt can appear).
"""
from gi.repository import GLib


def screenshot(win, path, then=None, tries=15):
    """Render the window to a PNG (works on any backend, including broadway).

    Right after a page switch the window may not have drawn yet; retry briefly.
    """
    from gi.repository import Gtk
    paintable = Gtk.WidgetPaintable.new(win)
    snap = Gtk.Snapshot()
    paintable.snapshot(snap, win.get_width(), win.get_height())
    node = snap.to_node()
    if node is None:
        if tries > 0:
            GLib.timeout_add(200, lambda: (screenshot(win, path, then, tries - 1), False)[1])
        else:
            print(f"SELFTEST FAIL nothing drawn for {path}", flush=True)
            then and then()
        return
    win.get_native().get_renderer().render_texture(node, None).save_to_png(path)
    print(f"SELFTEST ok   screenshot saved: {path}", flush=True)
    then and then()


def run(app, win):
    page = win.pages["smart"]
    win.selection.remember = lambda *_: None  # never change the user's remembered choices
    if app.screenshot:  # headless displays may not animate: no transitions or fade-ins
        from gi.repository import Gtk
        Gtk.Settings.get_default().set_property("gtk-enable-animations", False)
        page.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        win.content_stack.set_transition_type(Gtk.StackTransitionType.NONE)

    def report(ok, msg):
        print(f"SELFTEST {'ok  ' if ok else 'FAIL'} {msg}", flush=True)
        if not ok:
            app.selftest_failed = True

    def wait(cond, then, timeout=60.0, what="condition"):
        deadline = GLib.get_monotonic_time() + int(timeout * 1e6)

        def tick():
            if cond():
                then()
                return False
            if GLib.get_monotonic_time() > deadline:
                report(False, f"timed out waiting for {what}")
                finish()
                return False
            return True
        GLib.timeout_add(100, tick)

    def finish():
        print("SELFTEST done", flush=True)
        app.quit()

    def after_scan():
        found = [e for e in page.items.values() if e["status"] == "found"]
        report(page.stack.get_visible_child_name() == "results", "results page shown")
        report(len(page.items) > 0, f"{len(page.items)} items scanned, {len(found)} with junk")
        report(page.bar.get_revealed() == bool(found), "action bar matches the results")
        if app.screenshot:
            GLib.timeout_add(1500, lambda: (screenshot(win, app.screenshot, finish), False)[1])
            return
        if not found:
            return finish()
        first = sorted(found, key=lambda e: -e["bytes"])[0]
        before = page.summary.get_text()
        page.checks[first["id"]].set_active(not page.selected[first["id"]])
        report(page.summary.get_text() != before, f"toggling “{first['label']}” updates the summary")
        page.checks[first["id"]].set_active(not page.checks[first["id"]].get_active())  # restore
        page.show_details(first)
        GLib.timeout_add(1500, lambda: (after_details(), False)[1])

    def after_details():
        user_items = [e for e in page.items.values() if e["status"] == "found" and not e["root"]]
        if not (win.engine.dry_run and user_items):
            report(True, "clean skipped (not a dry run, or nothing to clean)")
            return finish()
        target = user_items[0]["id"]
        for i in list(page.selected):
            page.selected[i] = i == target
        page.clean([target])
        wait(lambda: page.clean_title.get_text().startswith("Dry run"), after_clean, 60, "dry-run clean")

    def after_clean():
        report(True, f"dry-run clean finished: {page.clean_title.get_text()}")
        finish()

    if app.screenshot:
        return run_scene(app, win, app.scene, app.screenshot, report, wait, finish)
    page.scan()
    wait(lambda: page.running is None and page.stack.get_visible_child_name() != "scanning",
         after_scan, 120, "scan")


def run_scene(app, win, scene, path, report, wait, finish):
    """Screenshot scenes for docs and app stores (packaging/make-screenshots.sh)."""
    page_id = {"privacy": "privacy", "ai": "ai", "user": "user"}.get(scene, "smart")
    win.show_page(page_id)
    page = win.pages[page_id]

    def shoot(delay_ms=1200):
        GLib.timeout_add(delay_ms, lambda: (screenshot(win, path, finish), False)[1])

    def scanned():
        return page.running is None and page.stack.get_visible_child_name() not in ("start", "scanning")

    def after_scan():
        found = sorted((e for e in page.items.values() if e["status"] == "found"), key=lambda e: -e["bytes"])
        user_items = [e for e in found if not e["root"]]
        if scene == "details" and user_items:
            # an item whose details list real folders (not the demo's stubbed Docker)
            pick = [e for e in user_items if not e["id"].startswith("docker_")] or user_items
            page.show_details(pick[0])
            return shoot(2500)
        if scene == "confirm":
            page.confirm_clean()
            return shoot(1200)
        if scene == "done":
            # only caches inside the (demo) home folder — never /tmp or anything system-wide
            safe = {"npm", "pip", "gobuild", "yarn", "thumbs", "ai_claude_cache", "ai_codex_cache", "browser_chrome"}
            ids = [e["id"] for e in user_items if e["id"] in safe]
            if not ids:
                return shoot()
            for i in list(page.selected):
                page.selected[i] = i in ids
            page.clean(ids)
            # the page rescans 1.2 s after finishing: capture the summary before that
            return wait(lambda: page.clean_title.get_text().startswith(("Freed", "Dry run", "History")),
                        lambda: shoot(300), 120, "clean")
        shoot()

    page.scan()
    wait(scanned, after_scan, 120, "scan")
