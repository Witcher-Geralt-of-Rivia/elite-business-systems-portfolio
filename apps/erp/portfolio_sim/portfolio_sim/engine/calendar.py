"""US business calendar for the distributor (pure Python).

Trading days are Monday-Friday except the federal-style holidays a wholesale business closes on.
Fixed-date holidays falling on a weekend are observed on the nearest weekday.
"""

from __future__ import annotations

from datetime import date, timedelta
from functools import cache


def _nth_weekday(year: int, month: int, weekday: int, n: int) -> date:
	d = date(year, month, 1)
	d += timedelta(days=(weekday - d.weekday()) % 7)
	return d + timedelta(weeks=n - 1)


def _last_weekday(year: int, month: int, weekday: int) -> date:
	d = date(year, month + 1, 1) - timedelta(days=1) if month < 12 else date(year, 12, 31)
	return d - timedelta(days=(d.weekday() - weekday) % 7)


def _observed(d: date) -> date:
	if d.weekday() == 5:
		return d - timedelta(days=1)
	if d.weekday() == 6:
		return d + timedelta(days=1)
	return d


@cache
def holidays(year: int) -> frozenset[date]:
	thanksgiving = _nth_weekday(year, 11, 3, 4)
	return frozenset(
		{
			_observed(date(year, 1, 1)),
			_last_weekday(year, 5, 0),  # Memorial Day
			_observed(date(year, 7, 4)),
			_nth_weekday(year, 9, 0, 1),  # Labor Day
			thanksgiving,
			thanksgiving + timedelta(days=1),
			_observed(date(year, 12, 25)),
		}
	)


def is_business_day(d: date) -> bool:
	return d.weekday() < 5 and d not in holidays(d.year) and d not in holidays(d.year + 1)


def next_business_day(d: date, days: int = 1) -> date:
	"""The business day `days` business days after d (days >= 1)."""
	while days > 0:
		d += timedelta(days=1)
		if is_business_day(d):
			days -= 1
	return d


def on_or_after(d: date) -> date:
	while not is_business_day(d):
		d += timedelta(days=1)
	return d


def on_or_before(d: date) -> date:
	while not is_business_day(d):
		d -= timedelta(days=1)
	return d


def business_days(start: date, end: date) -> list[date]:
	"""All business days in [start, end]."""
	out, d = [], start
	while d <= end:
		if is_business_day(d):
			out.append(d)
		d += timedelta(days=1)
	return out


def month_day(year: int, month: int, day: int) -> date:
	"""Business day for a monthly due day: day 1 -> first business day on/after, otherwise on/before
	(day 31 = last business day of the month)."""
	last = (date(year, month + 1, 1) if month < 12 else date(year + 1, 1, 1)) - timedelta(days=1)
	target = date(year, month, min(day, last.day))
	return on_or_after(target) if day == 1 else on_or_before(target)


def is_last_business_day_of_month(d: date) -> bool:
	return is_business_day(d) and next_business_day(d).month != d.month
