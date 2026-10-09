# EVM backend — progress

Experimental Dafny backend that emits EVM smart-contract code so that
verified Dafny programs can be deployed on Ethereum-compatible chains.

**Status:** scaffolding + MVP codegen pass 1 complete. `dotnet build` is green.
`Counter.dfy` **verifies** against Z3 (`5 verified, 0 errors`). The EVM pipeline
successfully walks module → class → field (`#define constant COUNT_SLOT = 0x00`) →
method header (`#define macro _CTOR0()` and friends) and enters each method body.
It currently halts at the **first real statement** of the constructor
(`count := 1`) with `NotImplementedException: EmitMemberSelect` — that is the
single next frontier method and the entry point for the next contributor
(see **Current frontier** below).

---

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Output format | **Huff** (`.huff`) | Low-level EVM macro assembler. No `solc` dependency, auditable 1:1 mapping to opcodes, and closer to EVM semantics than Solidity — matches a verification-first workflow. Yul and raw bytecode were considered; Solidity rejected because its own semantics (overflow checks, implicit conversions, inheritance) would get in the way of Dafny's semantics. |
| Scope | **MVP** | One Dafny `class` → one Huff contract. `uint256`-shaped integer fields in storage, pure/view/mutating methods, locals, `if`/`while`, arithmetic. Everything else is unsupported. |
| Subset enforcement | **`UnsupportedFeatures` set** | Rely on Dafny's existing `Feature` enum machinery. The driver rejects programs that use unsupported features *before* codegen runs, so our generator only ever sees legal input. No ad-hoc validation inside `EvmCodeGenerator`. |
| CLI id / extension | `-t:evm`, `.huff` | Short, unambiguous. Output goes to `<name>-evm/<name>.huff`. |
| `dafny run` | **Not supported** | Smart contracts aren't CLI-executable. `RunTargetProgram` emits an actionable error pointing users at `huffc` + deployment tooling. |
| `dafny build` post-step | **None (for now)** | We emit source only. Invoking `huffc` to produce bytecode is left to the user's build pipeline until the backend stabilises. |
| Native integer types | **None** | Everything is `uint256` on the EVM stack. `SupportedNativeTypes` is empty on purpose. |
| Scaffolding strategy | **Stub all abstracts, then grow** | Every `SinglePassCodeGenerator` abstract starts as `throw new NotImplementedException`. We implement only what the MVP needs. Any accidental escape of an unsupported construct fails loudly instead of silently emitting bad Huff. |

---

## Progress

### Done
- [x] Located backend layout (`Source/DafnyCore/Backends/`).
- [x] `EvmBackend.cs` skeleton — target id, extension, output dir, no-run behaviour.
- [x] Registered in `InternalBackendsPluginConfiguration.cs`.
- [x] `EvmCodeGenerator.cs` stub — all 73 `SinglePassCodeGenerator` abstracts overridden with `NotImplementedException`; conservative `UnsupportedFeatures` set.
- [x] `dotnet build Source/DafnyCore/DafnyCore.csproj` green (13s on a cold build).
- [x] `dafny build -t:evm --no-verify` recognised end-to-end — fails at `CreateModule` stub as designed, proving the pipeline reaches our generator. First smoke-test file: `Source/IntegrationTests/TestFiles/LitTests/LitTest/evm/Counter.dfy`.
- [x] **MVP codegen pass 1 — module / class / field / method scaffolding:**
  - `CreateModule` emits `<name>.huff` with a header comment, returns the file writer.
  - `CreateClass` emits the class header and returns a new `EvmClassWriter`.
  - `EvmClassWriter.DeclareField` emits `#define constant <NAME>_SLOT = 0x..`.
  - `EvmClassWriter.CreateMethod` / `CreateFunction` emits `#define macro <NAME>()` and returns a body writer.
  - `EvmClassWriter.Finish` emits a `MAIN()` dispatcher using `__FUNC_SIG` + `jumpi`.
  - `PublicIdProtect` sanitises Dafny names to valid Huff identifiers.
  - `TypeName` / `TypeInitializationValue` / `TypeName_UDT` / `TypeName_Companion` return trivial `uint256` / `0` / name / `null` values (every Dafny value is a 256-bit word on the EVM stack).

### Next — MVP codegen pass 2 (statements and expressions)
- [ ] `EmitMemberSelect` → return a `StorageSlotLvalue` whose read emits `[<SLOT>] sload` and whose write emits `<value> [<SLOT>] sstore`.
- [ ] Thread a `Field → slot` map through `EvmClassWriter` and expose it to the generator (today only `EvmClassWriter` knows the slot number; the generator needs it too).
- [ ] `EmitLiteralExpr` → push integer literal (`0x<hex>`).
- [ ] `EmitThis` → no-op (receiver is implicit for storage-backed classes).
- [ ] `EmitReturn` → store result at memory offset 0 and emit `0x20 0x00 return`.
- [ ] `EmitBinaryExpr` for `+`, `-`, `*`, `/`, `==`, `<`, `<=` (map to `add`, `sub`, `mul`, `div`, `eq`, `lt`, `gt` with operand swap).
- [ ] Local variables (prototype: just use additional memory slots; later: stack scheduling).
- [ ] Finally: smoke-test `Counter.dfy` compiles with `huffc`.

### Later (post-MVP, for a serious upstream submission)
- [ ] Integration tests under `Source/IntegrationTests` with LitTest-style `.dfy` + `.expect`.
- [ ] Reference-manual section under `docs/DafnyRef/`.
- [ ] EVM context primitives: `msg.sender`, `msg.value`, `block.timestamp`, `block.number`, `address(this).balance`.
- [ ] Events → `LOG0..LOG4` opcodes.
- [ ] `require` / `revert` lowering (map Dafny `expect` or an explicit `Revert` method).
- [ ] Storage layout for `map<K, V>` via `keccak256(key . slot)`.
- [ ] ABI encoding/decoding beyond single `uint256` (tuples, dynamic bytes, address).
- [ ] Fallback / receive functions.
- [ ] Gas-aware local variable scheduling (prefer stack over memory where possible).
- [ ] Opt-in `huffc` invocation during `dafny build` with error forwarding.

---

## File layout

```
Source/DafnyCore/Backends/Evm/
├── EvmBackend.cs          # IExecutableBackend plumbing (target id, run step, etc.)
├── EvmCodeGenerator.cs    # SinglePassCodeGenerator subclass — the real work
└── PROGRESS.md            # this file

Source/IntegrationTests/TestFiles/LitTests/LitTest/evm/
└── Counter.dfy            # smoke-test smart contract (verifies today)
```

One-line change to `../InternalBackendsPluginConfiguration.cs` adds
`new EvmBackend(options)` to the compiler plugin list. **No other shared
infrastructure was modified.**

---

## How to resume (handoff)

### Prerequisites

- **.NET SDK 8.0.x** (matching the repo's `global.json` pin, currently `8.0.111`
  with `rollForward: latestFeature`). Verify with `dotnet --version`.
- **Z3 4.16.0** — only needed to run `dafny verify`. The backend itself
  (`dafny build -t:evm --no-verify`) does not depend on Z3.
  Known-good location on the dev machine: `C:\Users\tuna_\GitHub\z3\build\Release\z3.exe`.
  Pass with `--solver-path <path>` or put the folder on `PATH`.

### Build

```powershell
# From the repo root
dotnet build Source\DafnyCore\DafnyCore.csproj   # ~15–35s cold, <5s warm
dotnet build Source\Dafny\Dafny.csproj           # builds the CLI → Binaries\Dafny.dll
```

### Verify the example contract (needs Z3)

```powershell
dotnet Binaries\Dafny.dll verify `
  --solver-path C:\Users\tuna_\GitHub\z3\build\Release\z3.exe `
  Source\IntegrationTests\TestFiles\LitTests\LitTest\evm\Counter.dfy
# Expected: Dafny program verifier finished with 5 verified, 0 errors
```

### Run the EVM backend end-to-end (does not need Z3)

```powershell
dotnet Binaries\Dafny.dll build -t:evm --no-verify `
  Source\IntegrationTests\TestFiles\LitTests\LitTest\evm\Counter.dfy
# Expected today: NotImplementedException at EmitMemberSelect
# (see "Current frontier" below)
```

### Working-tree hygiene

Changes required for the backend are self-contained:
```
 M Source/DafnyCore/Backends/InternalBackendsPluginConfiguration.cs   (one line)
?? Source/DafnyCore/Backends/Evm/                                    (new folder)
?? Source/IntegrationTests/TestFiles/LitTests/LitTest/evm/           (new folder)
```
`global.json` must **not** be modified in any committed change.

---

## Current frontier

When you re-run `dafny build -t:evm --no-verify Counter.dfy` today the stack
trace is:

```
EvmCodeGenerator.EmitMemberSelect(...)                 ← first NotImplementedException
  ← SinglePassCodeGenerator.CreateLvalue(...)
    ← TrStmt   (translating `count := 1`)
      ← TrDividedBlockStmt   (constructor body)
        ← CompileMethod
```

**Minimum unblocking change** (concrete recipe for the next contributor):

1. In `EvmClassWriter`, expose the `Field → slot` map that `DeclareField` is
   already building, so the enclosing `EvmCodeGenerator` can look up slots.
2. Implement `EmitMemberSelect` to recognise `member is Field` and return a
   custom `ILvalue` (new nested class `StorageSlotLvalue`) with:
   - `EmitRead(wr)` → `wr.Write($"[{slot}] sload");`
   - `EmitWrite(wRhs, wr)` → emit `<RHS evaluation> [<slot>] sstore`.
3. Implement `EmitLiteralExpr` to push an integer as `0x<hex>`.
4. Implement `EmitThis` as a no-op (the receiver is implicit — the EVM has no
   `this` pointer; storage slots are globally addressed).

With just those four, the constructor body `count := 1` should compile to:
```huff
0x01 [COUNT_SLOT] sstore
```
and a `.huff` file will actually appear in `Counter-evm/_default.huff`.

The next frontier after that is almost certainly `EmitReturn` and one or two
`EmitBinaryExpr` ops, driven by `get()` and `inc()` respectively.

---

## Notes for reviewers

- The backend is **non-executable** by design (`TextualTargetIsExecutable = false`,
  `SupportsInMemoryCompilation = false`). This is a deliberate departure from
  every other built-in backend; it reflects the reality that contracts are
  deployed, not run.
- `IsStable = false` — the backend is advertised as experimental in `--help`.
- No changes to `SinglePassCodeGenerator` or any other shared infrastructure
  were needed to add this backend. All extension happens through the existing
  plugin + `Feature`-flag mechanisms, which should make upstream review easier.
