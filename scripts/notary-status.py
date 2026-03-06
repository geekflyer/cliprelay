#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.12"
# dependencies = ["textual"]
# ///
"""TUI dashboard for Apple Notary submission status."""

import json
import subprocess
import re
from datetime import datetime, timezone
from pathlib import Path

from textual.app import App, ComposeResult
from textual.widgets import Header, Footer, DataTable, Static, RichLog
from textual.containers import Vertical

KEYCHAIN_PROFILE = "ClipRelay"
REFRESH_SECONDS = 30
ROOT_DIR = Path(__file__).resolve().parent.parent
NOTARY_DIR = ROOT_DIR / "dist" / "notary"
GITHUB_REPO = "geekflyer/cliprelay"

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


def fmt_elapsed(iso: str) -> str:
    """Return a human-readable elapsed time like '2h 15m' or '3d 4h'."""
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        total_seconds = int(delta.total_seconds())
        if total_seconds < 0:
            return "just now"
        days, remainder = divmod(total_seconds, 86400)
        hours, remainder = divmod(remainder, 3600)
        minutes = remainder // 60
        if days > 0:
            return f"{days}d {hours}h"
        if hours > 0:
            return f"{hours}h {minutes}m"
        return f"{minutes}m"
    except Exception:
        return ""


def read_notary_info(submission_id: str) -> dict:
    """Read info.txt from the notary tracking directory for a submission."""
    info_path = NOTARY_DIR / submission_id / "info.txt"
    info = {}
    if info_path.is_file():
        for line in info_path.read_text().splitlines():
            m = re.match(r"(\w+):\s*(.*)", line)
            if m:
                info[m.group(1)] = m.group(2)
    return info


def git_commit_url(git_hash: str) -> str:
    return f"https://github.com/{GITHUB_REPO}/commit/{git_hash}"


def enrich_entries(entries: list[dict]) -> None:
    for entry in entries:
        sid = entry.get("id", "")
        # Load local tracking info (git hash, etc.)
        entry["_notary_info"] = read_notary_info(sid)
        status = entry.get("status", "")
        if status in ("Accepted", "Rejected", "Invalid"):
            log = fetch_log(sid)
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
        table.add_columns("Date", "Elapsed", "Name", "Status", "Summary", "Git", "ID")
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
            elapsed = fmt_elapsed(e.get("createdDate", ""))
            git_hash = e.get("_notary_info", {}).get("git", "")
            git_short = git_hash[:10] if git_hash else "[dim]—[/]"
            table.add_row(
                fmt_date(e.get("createdDate", "")),
                elapsed,
                e.get("name", "?"),
                styled,
                summary,
                git_short,
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

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
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
        created = entry.get("createdDate", "?")
        elapsed = fmt_elapsed(created)
        detail.write(f"[bold]Created:[/] {created}  ({elapsed} ago)")
        git_hash = entry.get("_notary_info", {}).get("git", "")
        if git_hash:
            detail.write(f"[bold]Git:[/] {git_commit_url(git_hash)}")

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
