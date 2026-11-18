"""bench commands (`bench --site <site> portfolio-sim <command>`), discovered by Frappe through
`<app>.commands.commands` (frappe/utils/bench_helper.py get_app_commands)."""

from __future__ import annotations

import json
from datetime import date, datetime

import click
from frappe.commands import get_site, pass_context

DEFAULT_SEED = 20261119
DEFAULT_START = "2025-08-01"


def _connect(context):
	import frappe

	site = get_site(context)
	frappe.init(site=site)
	frappe.connect()
	frappe.set_user("Administrator")
	return frappe


def _print(data) -> None:
	click.echo(json.dumps(data, indent=2, default=str))


@click.group("portfolio-sim")
def portfolio_sim():
	"""Sable Ridge Electronics Supply: deterministic wholesale-distribution simulation."""


@portfolio_sim.command("setup")
@click.option("--seed", default=DEFAULT_SEED, show_default=True, type=int)
@click.option("--start", default=DEFAULT_START, show_default=True, help="First simulated day (moved to a business day).")
@pass_context
def setup_cmd(context, seed, start):
	"""Company, settings and master data (idempotent)."""
	frappe = _connect(context)
	try:
		from .services.setup import setup

		_print(setup(seed, date.fromisoformat(start)))
	finally:
		frappe.destroy()


@portfolio_sim.command("backfill")
@click.option("--until", default=None, help="ISO datetime; default: now. History is generated up to this point.")
@click.option("--max-events", default=None, type=int, help="Stop after this many events (resume later).")
@pass_context
def backfill_cmd(context, until, max_events):
	"""Generate history up to --until. Safe to interrupt and run again (exactly-once)."""
	frappe = _connect(context)
	try:
		from frappe.utils import now_datetime

		from .services.simulator import advance

		_print(advance(datetime.fromisoformat(until) if until else now_datetime(), max_events=max_events, respect_pause=False))
	finally:
		frappe.destroy()


@portfolio_sim.command("status")
@pass_context
def status_cmd(context):
	frappe = _connect(context)
	try:
		from .services.simulator import status

		_print(status())
	finally:
		frappe.destroy()


@portfolio_sim.command("live")
@click.argument("mode", type=click.Choice(["on", "off"]))
@pass_context
def live_cmd(context, mode):
	"""Let the scheduler advance the simulation every minute (on) or not (off)."""
	frappe = _connect(context)
	try:
		frappe.db.set_single_value("Distribution Sim Settings", "live", 1 if mode == "on" else 0)
		frappe.db.commit()
		_print({"live": mode})
	finally:
		frappe.destroy()


@portfolio_sim.command("pause")
@pass_context
def pause_cmd(context):
	frappe = _connect(context)
	try:
		frappe.db.set_single_value("Distribution Sim Settings", "paused", 1)
		frappe.db.commit()
		_print({"paused": True})
	finally:
		frappe.destroy()


@portfolio_sim.command("resume")
@pass_context
def resume_cmd(context):
	frappe = _connect(context)
	try:
		frappe.db.set_single_value("Distribution Sim Settings", "paused", 0)
		frappe.db.commit()
		_print({"paused": False})
	finally:
		frappe.destroy()


@portfolio_sim.command("integrity")
@click.option("--only", default=None, help="Comma-separated check names.")
@pass_context
def integrity_cmd(context, only):
	"""Run the read-only integrity checks (all must be 0)."""
	frappe = _connect(context)
	try:
		from .services.integrity import run

		result = run(only.split(",") if only else None)
		_print(result)
		if result["failing"]:
			raise SystemExit(1)
	finally:
		frappe.destroy()


@portfolio_sim.command("replay-check")
@pass_context
def replay_cmd(context):
	"""Recompute the deterministic plan and compare it with the event ledger (read-only)."""
	frappe = _connect(context)
	try:
		from .services.simulator import replay_check

		result = replay_check()
		_print(result)
		if result["missing_count"] or result["unexpected_count"] or result["mismatch_count"] or not result["state_matches"]:
			raise SystemExit(1)
	finally:
		frappe.destroy()


commands = [portfolio_sim]
