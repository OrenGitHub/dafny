// Verify the Dafny specification (works today, independent of the EVM backend).
// RUN: %testDafnyForEachResolver "%s"

// Once the EVM MVP codegen (pass 2) lands, enable the next lines to compile
// to Huff and compare against TimeLockedEscrow.dfy.expect:
//   RUN: %baredafny build -t:evm %args "%s" > "%t"
//   RUN: %diff "%s.expect" "%t"

/// Time-Locked Escrow — contract 3/3 of the benchmark set tracked by issue #2.
///
/// Reference Solidity implementation (audited):
///   OpenZeppelin `TokenTimelock`
///   https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/utils/TokenTimelock.sol
///
/// Proof shape: *temporal / block-context* property.
///   Funds held by the escrow can be released to the beneficiary — and only to
///   the beneficiary — once `block.timestamp` has reached `unlockTime`. Any
///   earlier call, or any call from a non-beneficiary, is a no-op and leaves
///   the escrow balance untouched. This is the property that neutralises the
///   "release early" and "wrong caller withdraws" bug classes.
///
/// Properties proven below (every one is an `ensures` on `release`):
///   1. SAFETY: `blockTimestamp < unlockTime ==> payout == 0 && amount unchanged`
///              (cannot release early — not even by the beneficiary)
///   2. AUTH:   `sender != beneficiary ==> payout == 0 && amount unchanged`
///              (only the beneficiary can collect)
///   3. CORRECT: on a successful release the beneficiary receives *exactly*
///               the escrowed amount, the balance drops to zero, and the
///               time + authorization pre-conditions must have held
///   4. IMMUTABILITY: `beneficiary` and `unlockTime` are frozen after
///                    construction (nobody can retro-actively extend or
///                    re-target the lock)
///
/// MVP translation plan (for the EVM/Huff backend):
///   * `beneficiary`             -> storage slot 0  (`BENEFICIARY_SLOT`)
///   * `unlockTime`              -> storage slot 1  (`UNLOCK_TIME_SLOT`)
///   * `amount`                  -> storage slot 2  (`AMOUNT_SLOT`)
///   * constructor(_b, _u, _a)   -> `#define macro CONSTRUCTOR()`
///   * `release(sender, ts)`     -> `#define macro RELEASE()` using
///                                  `caller` and `timestamp` opcodes
///                                  for the two arguments
class TimeLockedEscrow {
  /// The only account that is ever allowed to withdraw. Stored as a 256-bit
  /// word (Solidity `address` is 20 bytes but is zero-extended on the stack).
  var beneficiary: nat

  /// Unix seconds after which `release` becomes callable. Set once at
  /// construction and never updated — see IMMUTABILITY property.
  var unlockTime: nat

  /// Current wei balance held in escrow. Reduced to 0 by a successful
  /// `release`. We encode "already released" as `amount == 0` so that
  /// the whole state is a flat tuple of three `uint256`s and no boolean
  /// flag is needed (keeps storage layout 1:1 with the Huff translation).
  var amount: nat

  /// Class invariant. Nothing beyond well-formedness is required by the
  /// temporal properties, but we expose it to mirror `Counter.dfy` so that
  /// the pattern is uniform across the benchmark set.
  ghost predicate Valid()
    reads this
  {
    true
  }

  constructor(initBeneficiary: nat, initUnlockTime: nat, initAmount: nat)
    requires initAmount > 0
    ensures Valid()
    ensures beneficiary == initBeneficiary
    ensures unlockTime  == initUnlockTime
    ensures amount      == initAmount
  {
    beneficiary := initBeneficiary;
    unlockTime  := initUnlockTime;
    amount      := initAmount;
  }

  /// Attempt to release the escrowed funds.
  ///
  /// On the EVM, `sender` is `msg.sender` and `blockTimestamp` is
  /// `block.timestamp`. We thread them as explicit parameters so that the
  /// Dafny side is pure logic — the Huff translation will replace them
  /// with the `caller` and `timestamp` opcodes.
  ///
  /// Returns the amount paid out. `payout == 0` means the call was a no-op
  /// (either too early or wrong caller); `payout > 0` means a successful
  /// release of the full escrowed amount.
  method release(sender: nat, blockTimestamp: nat) returns (payout: nat)
    requires Valid()
    modifies this
    ensures  Valid()

    // --- 1. SAFETY: cannot release before unlockTime ----------------------
    ensures blockTimestamp < old(unlockTime)
            ==> payout == 0 && amount == old(amount)

    // --- 2. AUTH: only the beneficiary can collect ------------------------
    ensures sender != old(beneficiary)
            ==> payout == 0 && amount == old(amount)

    // --- 3. CORRECTNESS (soundness, success => conditions):
    //        a successful release transfers exactly the full escrowed amount,
    //        zeros the balance, and witnesses that both preconditions held.
    ensures payout > 0 ==> (
      payout == old(amount) &&
      amount == 0 &&
      blockTimestamp >= old(unlockTime) &&
      sender == old(beneficiary)
    )

    // --- 4. COMPLETENESS / LIVENESS (conditions => success):
    //        this is the other half of the issue's "succeeds iff". Without it,
    //        a `release` that always returns 0 would trivially satisfy the
    //        rest of the spec (and did — verified empirically). With it, a
    //        well-formed call (right caller, right time, non-empty escrow)
    //        MUST pay out the full balance.
    ensures ( sender == old(beneficiary)
           && blockTimestamp >= old(unlockTime)
           && old(amount) > 0 )
            ==> payout == old(amount) && amount == 0

    // --- 5. IMMUTABILITY: lock target and lock time never change ----------
    ensures beneficiary == old(beneficiary)
    ensures unlockTime  == old(unlockTime)
  {
    if blockTimestamp < unlockTime {
      payout := 0;
      return;
    }
    if sender != beneficiary {
      payout := 0;
      return;
    }
    payout := amount;
    amount := 0;
  }
}
