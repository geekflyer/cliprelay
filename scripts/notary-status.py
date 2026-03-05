#!/usr/bin/env python3
"""TUI dashboard for Apple Notary submission status."""

import subprocess
import sys

try:
    import textual  # noqa: F401
except ImportError:
    print("Installing textual...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "textual"])

import json
import re
from datetime import datetime

from textual.app import App, ComposeResult
from textual.widgets import Header, Footer, DataTable, Static, RichLog
from textual.containers import Vertical

KEYCHAIN_PROFILE = "ClipRelay"
REFRESH_SECONDS = 30

STATUS_STYLE = {
    "Accepted": "[green]Accepted[/]",
    "Rejected": "[red]Rejected[/]",
    "In Progress": "[yellow]In Progress[/]",
    "Invalid": "[red dim]Invalid[/]",
}


def fetch_history() -> list[dict]:
    result = subprocess.run(
        ["xcrun", "notarytool", "history", "--keychain-profile", KEYCHAIN_PROFILE],
        capture_output=True,
        text=True,
    )
    entries = []
    current: dict = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("---"):
            if current:
                entries.append(current)
            current = {}
            continue
        m = re.match(r"(\w+):\s*(.*)", line)
        if m:
            current[m.group(1)] = m.group(2)
    if current:
        entries.append(current)
    return entries


def fetch_log(submission_id: str) -> dict | None:
    result = subprocess.run(
        [
            "xcrun", "notarytool", "log", submission_id,
            "--keychain-profile", KEYCHAIN_PROFILE,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def fmt_date(iso: str) -> str:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        local = dt.astimezone()
        return local.strftime("%b %d %H:%M")
    except Exception:
        return iso


def enrich_entries(entries: list[dict]) -> None:
    for entry in entries:
        status = entry.get("status", "")
        if status in ("Accepted", "Rejected", "Invalid"):
            log = fetch_log(entry["id"])
            if log:
                entry["_log"] = log


class NotaryApp(App):
    CSS = """
    #table {
        height: 1fr;
    }
    #detail {
        height: auto;
        max-height: 40%;
        border-top: solid $accent;
        padding: 0 1;
    }
    #status-bar {
        dock: bottom;
        height: 1;
        background: $surface;
        color: $text-muted;
        padding: 0 1;
    }
    """
    BINDINGS = [
        ("r", "refresh", "Refresh"),
        ("q", "quit", "Quit"),
    ]
    TITLE = "Notary Submissions"

    def __init__(self) -> None:
        super().__init__()
        self._entries: list[dict] = []

    def compose(self) -> ComposeResult:
        yield Header()
        yield Vertical(
            DataTable(id="table"),
            RichLog(id="detail", markup=True, wrap=True),
            Static("Loading...", id="status-bar"),
        )
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns("Date", "Name", "Status", "Summary", "ID")
        self.load_data()
        self.set_interval(REFRESH_SECONDS, self.load_data)

    def load_data(self) -> None:
        table = self.query_one(DataTable)
        table.clear()
        self._entries = fetch_history()
        enrich_entries(self._entries)
        for e in self._entries:
            status = e.get("status", "?")
            styled = STATUS_STYLE.get(status, status)
            summary = self._get_summary(e)
            table.add_row(
                fmt_date(e.get("createdDate", "")),
                e.get("name", "?"),
                styled,
                summary,
                e.get("id", "?")[:12] + "...",
            )
        now = datetime.now().strftime("%H:%M:%S")
        self.query_one("#status-bar", Static).update(
            f" {len(self._entries)} submissions | Last refresh: {now} | Auto-refresh: {REFRESH_SECONDS}s | Select a row for details"
        )

    def _get_summary(self, entry: dict) -> str:
        log = entry.get("_log")
        if not log:
            return ""
        status = entry.get("status", "")
        summary = log.get("statusSummary", "")
        if len(summary) > 50:
            summary = summary[:47] + "..."
        if status == "Rejected":
            return f"[red]{summary}[/]"
        if status == "Accepted":
            return f"[green]{summary}[/]"
        return summary

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        detail = self.query_one("#detail", RichLog)
        detail.clear()
        idx = event.cursor_row
        if idx < 0 or idx >= len(self._entries):
            return
        entry = self._entries[idx]
        sid = entry.get("id", "?")
        status = entry.get("status", "?")

        detail.write(f"[bold]Submission:[/] {sid}")
        detail.write(f"[bold]Name:[/] {entry.get('name', '?')}  [bold]Status:[/] {STATUS_STYLE.get(status, status)}")
        detail.write(f"[bold]Created:[/] {entry.get('createdDate', '?')}")

        log = entry.get("_log")
        if log is None and status != "In Progress":
            log = fetch_log(sid)
            if log:
                entry["_log"] = log

        if log is None:
            if status == "In Progress":
                detail.write("[yellow]Log not yet available (submission in progress)[/]")
            else:
                detail.write("[dim]No log available[/]")
            return

        detail.write(f"[bold]Summary:[/] {log.get('statusSummary', 'N/A')}")
        detail.write(f"[bold]SHA-256:[/] [dim]{log.get('sha256', 'N/A')}[/]")

        issues = log.get("issues")
        if issues:
            detail.write("")
            detail.write(f"[bold red]Issues ({len(issues)}):[/]")
            for issue in issues:
                severity = issue.get("severity", "?")
                path = issue.get("path", "?")
                message = issue.get("message", "?")
                color = "red" if severity == "error" else "yellow"
                detail.write(f"  [{color}]{severity}[/] {path}: {message}")

        tickets = log.get("ticketContents")
        if tickets:
            detail.write("")
            detail.write(f"[bold]Notarized items ({len(tickets)}):[/]")
            for t in tickets:
                arch = f" ({t['arch']})" if "arch" in t else ""
                detail.write(f"  [dim]{t.get('path', '?')}{arch}[/]")

    def action_refresh(self) -> None:
        self.load_data()


if __name__ == "__main__":
    NotaryApp().run()
