namespace SimpleMailServer;

internal sealed class MessageHistoryEntry
{
    public DateTime ReceivedAt { get; init; }
    public string? From { get; init; }
    public string? To { get; init; }
    public string? Subject { get; init; }
    public SmtpMessageOutcome Outcome { get; init; }
    public string? SavedFilePath { get; set; }
}
