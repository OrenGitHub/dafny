// Verify the Dafny specification (works today, independent of the EVM backend).
// RUN: %testDafnyForEachResolver "%s"

// Once the EVM MVP codegen gains map support, enable:
//   RUN: %baredafny build -t:evm %args "%s" > "%t"
//   RUN: %diff "%s.expect" "%t"

include "../common/MapSum.dfy"
import opened MapSum

/// Core ERC-20 — contract 2/3 of the benchmark set tracked by issue #2.
///
/// Reference Solidity (audited):
///   OpenZeppelin `ERC20.sol`
///   https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
///
/// Scope (first pass, by design):
///   * state  : `totalSupply`, `balances : address -> uint`
///   * methods: constructor, mint, burn, transfer
///   * NO allowances / transferFrom / approve yet
///   * NO uint256 overflow yet (we use `nat`)
///
/// Proof shape: *global state invariant* preserved across every mutating method.
///   Invariant:  totalSupply == Σ_a balances[a]
///
/// This is the proof-shape the escrow didn't exercise. Z3 cannot discharge
/// the sum lemma by itself — see the explicit `SumUpdate` lemma below.

class ERC20Core {
  var totalSupply: nat
  var balances: map<nat, nat>   // address -> balance (missing key means 0)

  // ------------------------------------------------------------------
  // Ghost machinery for the sum-of-balances invariant is now provided
  // by `evm/common/MapSum.dfy` — SumMap + SumUpdate. First entry in the
  // Dafny-for-EVM proof library.
  // ------------------------------------------------------------------

  ghost predicate Valid()
    reads this
  {
    totalSupply == SumMap(balances)
  }

  constructor()
    ensures Valid()
    ensures totalSupply == 0
    ensures balances == map[]
  {
    totalSupply := 0;
    balances := map[];
  }

  function BalanceOf(a: nat): nat
    reads this
  {
    if a in balances then balances[a] else 0
  }

  /// Mint `v` fresh tokens to `to`. Increases both the recipient's
  /// balance and the total supply by `v`.
  method mint(to: nat, v: nat)
    requires Valid()
    modifies this
    ensures  Valid()
    ensures  totalSupply == old(totalSupply) + v
    ensures  BalanceOf(to) == old(BalanceOf(to)) + v
    ensures  forall a: nat :: a != to ==> BalanceOf(a) == old(BalanceOf(a))
  {
    var oldBal := BalanceOf(to);
    SumUpdate(balances, to, oldBal + v);
    balances    := balances[to := oldBal + v];
    totalSupply := totalSupply + v;
  }

  /// Burn `v` tokens from `from`. Decreases both the balance and the
  /// total supply by `v`. Requires sufficient balance.
  method burn(from: nat, v: nat)
    requires Valid()
    requires BalanceOf(from) >= v
    modifies this
    ensures  Valid()
    ensures  totalSupply == old(totalSupply) - v
    ensures  BalanceOf(from) == old(BalanceOf(from)) - v
    ensures  forall a: nat :: a != from ==> BalanceOf(a) == old(BalanceOf(a))
  {
    var oldBal := BalanceOf(from);
    SumUpdate(balances, from, oldBal - v);
    balances    := balances[from := oldBal - v];
    totalSupply := totalSupply - v;
  }

  /// Transfer `v` tokens from `sender` to `to`. Total supply unchanged.
  method transfer(sender: nat, to: nat, v: nat) returns (success: bool)
    requires Valid()
    modifies this
    ensures  Valid()
    ensures  totalSupply == old(totalSupply)
    // Insufficient-funds path: no state change.
    ensures  old(BalanceOf(sender)) < v
             ==> !success && balances == old(balances)
    // LIVENESS / completeness: sufficient balance ==> MUST succeed.
    // Without this, a transfer that always returns false satisfies the
    // rest of the spec (verified empirically — same bug as the escrow).
    ensures  old(BalanceOf(sender)) >= v ==> success
    // Successful cross-account transfer: balances update correctly.
    ensures  (success && sender != to) ==> (
               BalanceOf(sender) == old(BalanceOf(sender)) - v
            && BalanceOf(to)     == old(BalanceOf(to))     + v
            && (forall a: nat :: a != sender && a != to
                                 ==> BalanceOf(a) == old(BalanceOf(a)))
             )
    // Self-transfer is a no-op on balances.
    ensures  (success && sender == to) ==> balances == old(balances)
  {
    var sBal := BalanceOf(sender);
    if sBal < v {
      success := false;
      return;
    }
    if sender == to {
      success := true;
      return;
    }
    SumUpdate(balances, sender, sBal - v);
    var afterDebit := balances[sender := sBal - v];
    var tBal := if to in afterDebit then afterDebit[to] else 0;
    SumUpdate(afterDebit, to, tBal + v);
    balances := afterDebit[to := tBal + v];
    success := true;
  }
}
