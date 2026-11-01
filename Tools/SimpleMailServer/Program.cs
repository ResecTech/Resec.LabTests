/*
FILE SUMMARY
Purpose: WinForms host for the test SMTP server with mode selection and capped message history.
Key Types: Program (entry).
External Dependencies: Microsoft.Extensions.Configuration (appsettings.json), Windows Forms.
Internal Coupling: MainForm, SmtpServerHost, SmtpServerSettings.
Observations: Server starts when the form is shown; history size comes from SmtpSettings:MaxHistoryEntries.
*/
using Microsoft.Extensions.Configuration;

namespace SimpleMailServer;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (CliHost.TryRun(args, out int cliExitCode))
        {
            Environment.Exit(cliExitCode);
            return;
        }

        ApplicationConfiguration.Initialize();

        IConfiguration configuration = new ConfigurationBuilder()
            .SetBasePath(AppContext.BaseDirectory)
            .AddJsonFile("appsettings.json", optional: false)
            .Build();

        SmtpSettingsRoot root = configuration.Get<SmtpSettingsRoot>() ?? new SmtpSettingsRoot();
        SmtpServerSettings settings = root.SmtpSettings;

        if (settings.Port is < 1 or > 65535)
        {
            MessageBox.Show("SmtpSettings:Port must be between 1 and 65535.", "Simple SMTP Server",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        if (string.IsNullOrWhiteSpace(settings.SavedMessageFolder))
        {
            MessageBox.Show("SmtpSettings:SavedMessageFolder is required.", "Simple SMTP Server",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        if (settings.MaxHistoryEntries < 1)
        {
            MessageBox.Show("SmtpSettings:MaxHistoryEntries must be at least 1.", "Simple SMTP Server",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        if (settings.ResponseDelaySeconds < 0)
        {
            MessageBox.Show("SmtpSettings:ResponseDelaySeconds must be >= 0.", "Simple SMTP Server",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        Application.Run(new MainForm(settings));
    }
}
