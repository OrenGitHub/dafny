// Verify the library in isolation.
// RUN: %testDafnyForEachResolver "%s"

/// Reusable lemmas: sum of a finite map's values.
///
/// This is the first entry in `evm/common/` — the Dafny-for-EVM proof
/// library. Any contract that maintains a scalar equal to the sum of a
/// per-account balance map depends on `SumUpdate` to prove invariant
/// preservation across writes.
///
/// Known clients:
///   * ERC-20   : `totalSupply == Σ_a balances[a]`
///   * ERC-721  : `balanceOf[owner] == |{ id : tokenOwner[id] == owner }|`  (shape-adjacent)
///   * ERC-1155 : `totalSupply[id] == Σ_a balances[id][a]`
///   * Vesting / staking / escrow pools, AMM reserves, etc.
///
/// Proof status:
///   * `SumMap`     — concrete definition, verifies.
///   * `SumUpdate`  — **axiomatized** (`{:axiom}`). True combinatorial fact;
///                    the mechanical proof is induction on `|m|` with
///                    case-splitting over the nondet pick in `SumMap`,
///                    roughly 40–60 lines of ghost code. Deferred — see
///                    issue #2 proof-debt entry.
///
/// Prove it once here, and every downstream contract inherits a real
/// proof instead of an axiom.
module MapSum {

  /// Sum of all values in a finite map keyed by `nat`.
  /// Deterministic recursion over `|m|`; the nondet `:|` is well-defined
  /// because Dafny ghost functions are deterministic on their inputs.
  ghost function SumMap(m: map<nat, nat>): nat
    decreases |m|
  {
    if |m| == 0 then 0
    else
      var k :| k in m;
      m[k] + SumMap(m - {k})
  }

  /// Helper: `SumMap` is pivot-independent — for *any* key in the map,
  /// we can split off that key's value and sum the rest.
  ///
  /// This is the lemma that unlocks `SumUpdate` and all downstream work.
  /// Proof is by induction on `|m|`, with a `forall`-block in the
  /// inductive case to express pivot-independence (needed because
  /// `SumMap`'s `:|` picks a nondeterministic witness we can't name).
  lemma SumRemove(m: map<nat, nat>, k: nat)
    requires k in m
    ensures SumMap(m) == m[k] + SumMap(m - {k})
    decreases |m|
  {
    if |m| == 1 {
      // Only one key in m; it must be k.
      assert m.Keys == {k};
      assert m - {k} == map[];
    } else {
      // Pivot-independence: for every k0 in m, the "pivot on k0" value
      // equals the "pivot on k" value. Since SumMap(m) is defined as
      // "pivot on some chosen witness in m", it must equal "pivot on k".
      forall k0 | k0 in m
        ensures m[k0] + SumMap(m - {k0}) == m[k] + SumMap(m - {k})
      {
        if k0 != k {
          SumRemove(m - {k0}, k);        // IH: SumMap(m-{k0}) = m[k] + SumMap((m-{k0})-{k})
          SumRemove(m - {k}, k0);        // IH: SumMap(m-{k})  = m[k0] + SumMap((m-{k})-{k0})
          assert (m - {k0}) - {k} == (m - {k}) - {k0};  // set-diff commutes
        }
      }
    }
  }

  /// Pointwise update of a map by one key changes the sum by
  /// `(new value) - (old value, or 0 if the key was absent)`.
  ///
  /// Proven from `SumRemove`. This is the lemma clients call on every
  /// map write to propagate `scalar == SumMap(mapField)`.
  lemma SumUpdate(m: map<nat, nat>, k: nat, v: nat)
    ensures SumMap(m[k := v]) ==
            SumMap(m) + v - (if k in m then m[k] else 0)
  {
    // Pivot the updated map on k (always present, since we just set it).
    SumRemove(m[k := v], k);
    // Removing k from the updated map gives back the original without k.
    assert m[k := v] - {k} == m - {k};
    // If k was in m, pivot the original on k too; otherwise m - {k} == m.
    if k in m {
      SumRemove(m, k);
    } else {
      assert m - {k} == m;
    }
  }
}
