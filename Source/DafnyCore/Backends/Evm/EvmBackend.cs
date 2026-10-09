using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Threading.Tasks;

namespace Microsoft.Dafny.Compilers;

/// <summary>
/// EVM backend for Dafny.
///
/// Emits Huff (https://docs.huff.sh/) source code so that verified Dafny
/// programs can be deployed as Ethereum smart contracts.
///
/// Current status: MVP scaffolding. Supports a very restricted subset of
/// Dafny: a single class with `uint256`-shaped integer fields, pure/view/
/// mutating methods, local variables, if-statements, and simple arithmetic.
/// Everything else is advertised in <see cref="EvmCodeGenerator.UnsupportedFeatures"/>
/// and will be rejected by the Dafny driver before codegen runs.
/// </summary>
public class EvmBackend : ExecutableBackend {

  public override IReadOnlySet<string> SupportedExtensions => new HashSet<string> { ".huff" };

  public override string TargetName => "EVM (Huff)";
  public override string TargetId => "evm";
  public override bool IsStable => false;
  public override string TargetExtension => "huff";
  public override int TargetIndentSize => 4;

  public override string TargetBaseDir(string dafnyProgramName) =>
    $"{Path.GetFileNameWithoutExtension(dafnyProgramName)}-evm";

  public override string TargetBasename(string dafnyProgramName) =>
    Path.GetFileNameWithoutExtension(dafnyProgramName);

  // Huff is a textual target that produces a .huff file; it cannot be run
  // directly from the Dafny driver (deployment to a chain is out of scope).
  public override bool TextualTargetIsExecutable => false;

  // We write a .huff file to disk; there is no in-memory assembly step.
  public override bool SupportsInMemoryCompilation => false;

  // No native integer types are mapped: everything is uint256 on the EVM stack.
  public override IReadOnlySet<string> SupportedNativeTypes => new HashSet<string>();

  protected override SinglePassCodeGenerator CreateCodeGenerator() {
    return new EvmCodeGenerator(Options, Reporter);
  }

  public override Task<(bool Success, object CompilationResult)> CompileTargetProgram(string dafnyProgramName,
    string targetProgramText,
    string /*?*/ callToMain, string /*?*/ targetFilename,
    ReadOnlyCollection<string> otherFileNames,
    bool runAfterCompile, IDafnyOutputWriter outputWriter) {
    // Nothing to do: we only emit source code. Invoking huffc / solc to
    // produce bytecode is left to the user's build pipeline for now.
    return Task.FromResult((true, (object)null));
  }

  public override async Task<bool> RunTargetProgram(string dafnyProgramName, string targetProgramText,
    string callToMain,
    string targetFilename, ReadOnlyCollection<string> otherFileNames,
    object compilationResult, IDafnyOutputWriter outputWriter) {
    await using var ew = outputWriter.ErrorWriter();
    await ew.WriteLineAsync(
      "The EVM backend produces Huff source and does not support `dafny run`. " +
      "Compile the generated .huff file with huffc, then deploy to an EVM chain.");
    return false;
  }

  public EvmBackend(DafnyOptions options) : base(options) {
  }
}
