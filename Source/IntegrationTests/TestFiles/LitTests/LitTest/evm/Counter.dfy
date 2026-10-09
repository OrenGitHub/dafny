// Verify the Dafny specification (works today, independent of the EVM backend).
// RUN: %testDafnyForEachResolver "%s"

// Once the EVM MVP codegen lands, enable the next line to compile to Huff
// and compare against Counter.dfy.expect:
//   RUN: %baredafny build -t:evm %args "%s" > "%t"
//   RUN: %diff "%s.expect" "%t"

/// A minimal "hello world" smart contract.
///
/// Correctness properties we are proving with Dafny:
///   * `Valid()` is a class invariant stating `count > 0`.
///   * The constructor establishes `Valid()` (by initialising `count` to 1).
///   * `get()` requires and preserves `Valid()`, and returns a value `> 0`.
///   * `inc()` requires and preserves `Valid()`, and increments by exactly one.
///
/// MVP translation plan (for the EVM/Huff backend):
///   * field `count`     -> storage slot 0 (`#define constant COUNT_SLOT = 0x00`)
///   * method `get()`    -> `#define macro GET()` returning `sload(COUNT_SLOT)`
///   * method `inc()`    -> `#define macro INC()` doing `sload; 1 add; sstore`
///   * constructor       -> `#define macro CONSTRUCTOR()` initialising slot 0 to 1
///   * class `Counter`   -> `MAIN()` dispatcher built from the ABI function selectors
class Counter {
  var count: nat

  /// Class invariant: a `Counter` is always strictly positive once constructed.
  ghost predicate Valid()
    reads this
  {
    count > 0
  }

  constructor()
    ensures Valid()
    ensures count == 1
  {
    count := 1;
  }

  method get() returns (c: nat)
    requires Valid()
    ensures c == count
    ensures c > 0            // follows from Valid() /\ c == count
  {
    c := count;
  }

  method inc()
    requires Valid()
    modifies this
    ensures Valid()
    ensures count == old(count) + 1
  {
    count := count + 1;
  }
}
