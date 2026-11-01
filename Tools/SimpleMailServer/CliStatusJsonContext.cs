/*
FILE SUMMARY
Purpose: Source-generated JSON for CliStatusSnapshot (trimmed / reflection-disabled publish).
Key Types: CliStatusJsonContext.
External Dependencies: System.Text.Json source generator.
Internal Coupling: CliHost status file writes.
*/
using System.Text.Json.Serialization;

namespace SimpleMailServer;

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(CliStatusSnapshot))]
internal partial class CliStatusJsonContext : JsonSerializerContext;
