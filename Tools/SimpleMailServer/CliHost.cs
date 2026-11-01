/*
FILE SUMMARY
Purpose: Headless Simple SMTP Server for automated mail-agent E2E tests.
Key Types: CliHost.
External Dependencies: Microsoft.Extensions.Configuration; SmtpServerHost.
Internal Coupling: SmtpServerSettings, CliStatusSnapshot, Program (--cli entry).
Observations: Writes status JSON on startup and after each message; Ctrl+C stops listener.
*/
using System.Text.Json;
using Microsoft.Extensions.Configuration;

namespace SimpleMailServer;

internal static class CliHost
{
    public static bool TryRun(string[] args, out int exitCode)
    {
        exitCode = 0;
        if (!ContainsCliSwitch(args))
            return false;

        try
        {
            exitCode = Run(args);
            return true;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"SimpleMailServer CLI fatal: {ex.Message}");
            exitCode = 1;
            return true;
        }
    }

    private static bool ContainsCliSwitch(string[] args)
    {
        foreach (string arg in args)
        {
            if (arg is "--cli" or "-c" or "cli")
                return true;
        }

        return false;
    }

    private static int Run(string[] args)
    {
        if (IsHelp(args))
        {
            PrintHelp();
            return 0;
        }

        CliOptions options = CliOptions.Parse(args);
        SmtpServerSettings settings = LoadSettings(options);

        if (options.PortOverride is int portOverride)
            settings.Port = portOverride;
        if (options.DelayOverride is double delayOverride)
            settings.ResponseDelaySeconds = delayOverride;
        if (!string.IsNullOrWhiteSpace(options.SaveFolderOverride))
            settings.SavedMessageFolder = options.SaveFolderOverride;
        if (options.SaveIncoming is bool saveIncoming)
            settings.SaveIncomingEmails = saveIncoming;

        ValidateSettings(settings);

        string statusPath = options.StatusFilePath
            ?? Path.Combine(Path.GetFullPath(settings.SavedMessageFolder), "..", "simple-mail-server-status.json");

        statusPath = Path.GetFullPath(statusPath);
        Directory.CreateDirectory(Path.GetDirectoryName(statusPath)!);

        if (options.WipeSaveFolder && Directory.Exists(settings.SavedMessageFolder))
        {
            foreach (string file in Directory.GetFiles(settings.SavedMessageFolder))
            {
                try
                {
                    File.Delete(file);
                }
                catch
                {
                }
            }
        }

        Directory.CreateDirectory(settings.SavedMessageFolder);

        using SmtpServerHost host = new(settings);
        host.SaveIncomingEmails = settings.SaveIncomingEmails;

        int messageCount = 0;
        string? lastSubject = null;
        string? lastSavedPath = null;
        string? lastOutcome = null;
        string? lastReceivedUtc = null;
        DateTime startedUtc = DateTime.UtcNow;

        void WriteStatus()
        {
            CliStatusSnapshot snapshot = new()
            {
                Port = settings.Port,
                ResponseDelaySeconds = settings.ResponseDelaySeconds,
                SavedMessageFolder = Path.GetFullPath(settings.SavedMessageFolder),
                MessageCount = messageCount,
                LastSubject = lastSubject,
                LastReceivedAtUtc = lastReceivedUtc,
                LastSavedFilePath = lastSavedPath,
                LastOutcome = lastOutcome,
                StartedAtUtc = startedUtc.ToString("o")
            };

            string json = JsonSerializer.Serialize(snapshot, CliStatusJsonContext.Default.CliStatusSnapshot);
            File.WriteAllText(statusPath, json);
        }

        host.MessageReceived += entry =>
        {
            messageCount++;
            lastSubject = entry.Subject;
            lastSavedPath = entry.SavedFilePath;
            lastOutcome = entry.Outcome.ToString();
            lastReceivedUtc = entry.ReceivedAt.ToUniversalTime().ToString("o");
            WriteStatus();
            Console.WriteLine(
                $"[SimpleMailServer] message #{messageCount} subject={entry.Subject ?? "(none)"} outcome={entry.Outcome}");
        };

        using CancellationTokenSource cts = new();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
        };

        host.Start();
        WriteStatus();
        Console.WriteLine(
            $"[SimpleMailServer] listening on port {settings.Port} delay={settings.ResponseDelaySeconds}s save={settings.SaveIncomingEmails} status={statusPath}");

        try
        {
            cts.Token.WaitHandle.WaitOne();
        }
        finally
        {
            host.StopAsync().GetAwaiter().GetResult();
            WriteStatus();
            Console.WriteLine("[SimpleMailServer] stopped.");
        }

        return 0;
    }

    private static SmtpServerSettings LoadSettings(CliOptions options)
    {
        string configFile = options.ConfigPath ?? Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        if (!Path.IsPathRooted(configFile))
            configFile = Path.Combine(AppContext.BaseDirectory, configFile);

        if (!File.Exists(configFile))
            throw new FileNotFoundException($"Configuration file not found: {configFile}");

        IConfiguration configuration = new ConfigurationBuilder()
            .SetBasePath(Path.GetDirectoryName(configFile)!)
            .AddJsonFile(Path.GetFileName(configFile), optional: false)
            .Build();

        SmtpSettingsRoot root = configuration.Get<SmtpSettingsRoot>() ?? new SmtpSettingsRoot();
        return root.SmtpSettings;
    }

    private static void ValidateSettings(SmtpServerSettings settings)
    {
        if (settings.Port is < 1 or > 65535)
            throw new InvalidOperationException("SmtpSettings:Port must be between 1 and 65535.");
        if (string.IsNullOrWhiteSpace(settings.SavedMessageFolder))
            throw new InvalidOperationException("SmtpSettings:SavedMessageFolder is required.");
        if (settings.ResponseDelaySeconds < 0)
            throw new InvalidOperationException("SmtpSettings:ResponseDelaySeconds must be >= 0.");
    }

    private static bool IsHelp(string[] args)
    {
        foreach (string arg in args)
        {
            if (arg is "--help" or "-h" or "/?")
                return true;
        }

        return false;
    }

    private static void PrintHelp()
    {
        Console.WriteLine();
        Console.WriteLine("Simple SMTP Server — headless mode");
        Console.WriteLine();
        Console.WriteLine("Usage:");
        Console.WriteLine("  SimpleMailServer.exe --cli [options]");
        Console.WriteLine();
        Console.WriteLine("Options:");
        Console.WriteLine("  --cli, -c, cli       Run without WinForms (for E2E scripts).");
        Console.WriteLine("  --config, -f PATH    appsettings.json (default: beside executable).");
        Console.WriteLine("  --port PORT          Override SmtpSettings:Port.");
        Console.WriteLine("  --delay, --response-delay SECONDS");
        Console.WriteLine("                       Pause before the post-DATA SMTP reply (extends outbound send time).");
        Console.WriteLine("  --save-folder PATH   Override SmtpSettings:SavedMessageFolder.");
        Console.WriteLine("  --save-incoming      Save each message as .eml (required for delivery asserts).");
        Console.WriteLine("  --no-save-incoming   Do not write .eml files.");
        Console.WriteLine("  --wipe-save-folder   Delete existing files in save folder before listen.");
        Console.WriteLine("  --status-file PATH   JSON status file (default: parent of save folder).");
        Console.WriteLine("  --help, -h           Show this help.");
        Console.WriteLine();
    }

    private sealed class CliOptions
    {
        public string? ConfigPath { get; init; }
        public int? PortOverride { get; init; }
        public double? DelayOverride { get; init; }
        public string? SaveFolderOverride { get; init; }
        public bool? SaveIncoming { get; init; }
        public bool WipeSaveFolder { get; init; }
        public string? StatusFilePath { get; init; }

        public static CliOptions Parse(string[] args)
        {
            string? configPath = null;
            int? port = null;
            double? delay = null;
            string? saveFolder = null;
            bool? saveIncoming = null;
            bool wipe = false;
            string? statusFile = null;

            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                switch (arg)
                {
                    case "--cli":
                    case "-c":
                    case "cli":
                        continue;
                    case "--config":
                    case "-f":
                        configPath = RequireNext(args, ref i, arg);
                        break;
                    case "--port":
                        port = int.Parse(RequireNext(args, ref i, arg), System.Globalization.CultureInfo.InvariantCulture);
                        break;
                    case "--delay":
                    case "--response-delay":
                        delay = double.Parse(RequireNext(args, ref i, arg), System.Globalization.CultureInfo.InvariantCulture);
                        break;
                    case "--save-folder":
                        saveFolder = RequireNext(args, ref i, arg);
                        break;
                    case "--save-incoming":
                        saveIncoming = true;
                        break;
                    case "--no-save-incoming":
                        saveIncoming = false;
                        break;
                    case "--wipe-save-folder":
                        wipe = true;
                        break;
                    case "--status-file":
                        statusFile = RequireNext(args, ref i, arg);
                        break;
                    default:
                        throw new InvalidOperationException($"Unknown argument: {arg}");
                }
            }

            return new CliOptions
            {
                ConfigPath = configPath,
                PortOverride = port,
                DelayOverride = delay,
                SaveFolderOverride = saveFolder,
                SaveIncoming = saveIncoming,
                WipeSaveFolder = wipe,
                StatusFilePath = statusFile
            };
        }

        private static string RequireNext(string[] args, ref int index, string flag)
        {
            if (index + 1 >= args.Length)
                throw new InvalidOperationException($"{flag} requires a value.");
            index++;
            return args[index];
        }
    }
}
