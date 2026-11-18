"""Deterministic random numbers for the distribution simulation (pure Python, no Frappe).

SplitMix64 is used instead of `random.Random` so that every draw is defined by this file alone: the
same seed gives the same history on any Python version and platform. Streams are derived from a
master seed and string labels (`derive_seed(seed, "day", "2025-08-04")`), so planning one day never
depends on how many numbers an earlier day consumed.
"""

from __future__ import annotations

import hashlib
import math
from collections.abc import Sequence
from typing import TypeVar

T = TypeVar("T")
MASK64 = (1 << 64) - 1


def derive_seed(*parts: object) -> int:
	"""Stable 64-bit seed from any labels (hash of their string forms)."""
	text = "|".join(str(p) for p in parts).encode()
	return int.from_bytes(hashlib.sha256(text).digest()[:8], "big")


class Rng:
	def __init__(self, seed: int):
		self.state = seed & MASK64

	def next_u64(self) -> int:
		self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
		z = self.state
		z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
		z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
		return z ^ (z >> 31)

	def random(self) -> float:
		"""Uniform in [0, 1)."""
		return (self.next_u64() >> 11) * (1.0 / (1 << 53))

	def uniform(self, a: float, b: float) -> float:
		return a + (b - a) * self.random()

	def randint(self, a: int, b: int) -> int:
		"""Uniform integer in [a, b] (inclusive)."""
		if b < a:
			raise ValueError("empty range")
		return a + min(int(self.random() * (b - a + 1)), b - a)

	def chance(self, p: float) -> bool:
		return self.random() < p

	def choice(self, seq: Sequence[T]) -> T:
		if not seq:
			raise ValueError("empty sequence")
		return seq[self.randint(0, len(seq) - 1)]

	def weighted(self, seq: Sequence[T], weights: Sequence[float]) -> T:
		total = float(sum(weights))
		if total <= 0 or len(seq) != len(weights):
			raise ValueError("invalid weights")
		r = self.random() * total
		acc = 0.0
		for item, w in zip(seq, weights, strict=True):
			acc += w
			if r < acc:
				return item
		return seq[-1]

	def normal(self, mu: float = 0.0, sigma: float = 1.0) -> float:
		# Box-Muller without caching the second value (keeps the stream position simple).
		u1 = max(self.random(), 1e-12)
		u2 = self.random()
		return mu + sigma * math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)

	def lognormal(self, mu: float, sigma: float) -> float:
		return math.exp(self.normal(mu, sigma))

	def exponential(self, mean: float) -> float:
		return -mean * math.log(max(1.0 - self.random(), 1e-12))

	def poisson(self, lam: float) -> int:
		if lam <= 0:
			return 0
		if lam > 30:
			return max(0, round(self.normal(lam, math.sqrt(lam))))
		limit = math.exp(-lam)
		k, p = 0, 1.0
		while True:
			p *= self.random()
			if p <= limit:
				return k
			k += 1

	def shuffle(self, items: list[T]) -> list[T]:
		for i in range(len(items) - 1, 0, -1):
			j = self.randint(0, i)
			items[i], items[j] = items[j], items[i]
		return items

	def sample(self, seq: Sequence[T], k: int) -> list[T]:
		return self.shuffle(list(seq))[: max(0, min(k, len(seq)))]
