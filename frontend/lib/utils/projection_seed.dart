/// F4: stable Monte Carlo seed derivation for the wealth projection.
///
/// The backend's `/projections/calculate` accepts an `mc_seed` (u64) that
/// makes the simulation deterministic per parameter set. Deriving the seed
/// from the canonical query-parameter string means identical inputs always
/// produce the identical uncertainty fan (no more KPIs wobbling between
/// fetches), while any changed input naturally re-rolls the simulation.
///
/// FNV-1a, 32-bit. 32-bit (not 64) on purpose: Flutter web compiles ints to
/// JS doubles, where 64-bit wrapping multiplication silently loses precision.
/// All arithmetic here stays far below 2^53 (the multiply is split into
/// 16-bit limbs), so the result is bit-identical on the VM and on the web.
/// The value is non-negative and well within u64 — exactly what the API
/// expects.
int projectionSeed(String canonicalParams) {
  var hash = 0x811C9DC5; // FNV-1a 32-bit offset basis.
  const prime = 0x01000193; // FNV-1a 32-bit prime.
  for (final unit in canonicalParams.codeUnits) {
    // Fold both bytes of the UTF-16 code unit, low byte first.
    hash = _fnvRound(hash ^ (unit & 0xFF), prime);
    hash = _fnvRound(hash ^ ((unit >> 8) & 0xFF), prime);
  }
  return hash;
}

/// One `hash * prime (mod 2^32)` step, decomposed into 16-bit limbs so no
/// intermediate exceeds ~2^48 (JS-safe).
int _fnvRound(int hash, int prime) {
  final lo = (hash & 0xFFFF) * prime;
  final hi = ((hash >> 16) * prime) & 0xFFFF;
  return (lo + (hi << 16)) & 0xFFFFFFFF;
}
