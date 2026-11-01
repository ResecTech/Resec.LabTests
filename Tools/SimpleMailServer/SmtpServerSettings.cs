namespace SimpleMailServer;

internal sealed class SmtpServerSettings
{
    public int Port { get; set; } = 26;
    public string SavedMessageFolder { get; set; } = "";
    public int MaxHistoryEntries { get; set; } = 100;
    /// <summary>Artificial pause before each SMTP response; 0 = no delay.</summary>
    public double ResponseDelaySeconds { get; set; }
    public bool SaveIncomingEmails { get; set; }
}

internal sealed class SmtpSettingsRoot
{
    public SmtpServerSettings SmtpSettings { get; set; } = new();
}
