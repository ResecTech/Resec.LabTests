/*
FILE SUMMARY
Purpose: Machine-readable SMTP server status for headless CLI (E2E scripts poll delivery).
Key Types: CliStatusSnapshot.
External Dependencies: System.Text.Json.
Internal Coupling: CliHost writes this file on each received message.
Observations: UTC timestamps; camelCase JSON for PowerShell ConvertFrom-Json.
*/
using System.Text.Json.Serialization;

namespace SimpleMailServer;

internal sealed class CliStatusSnapshot
{
    [JsonPropertyName("port")]
    public int Port { get; init; }

    [JsonPropertyName("responseDelaySeconds")]
    public double ResponseDelaySeconds { get; init; }

    [JsonPropertyName("savedMessageFolder")]
    public string SavedMessageFolder { get; init; } = "";

    [JsonPropertyName("messageCount")]
    public int MessageCount { get; init; }

    [JsonPropertyName("lastSubject")]
    public string? LastSubject { get; init; }

    [JsonPropertyName("lastReceivedAtUtc")]
    public string? LastReceivedAtUtc { get; init; }

    [JsonPropertyName("lastSavedFilePath")]
    public string? LastSavedFilePath { get; init; }

    [JsonPropertyName("lastOutcome")]
    public string? LastOutcome { get; init; }

    [JsonPropertyName("startedAtUtc")]
    public string StartedAtUtc { get; init; } = "";
}
