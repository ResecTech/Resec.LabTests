/*
FILE SUMMARY
Purpose: Accepts SMTP connections, optionally saves messages to disk, and applies configurable response modes for testing.
Key Types: SmtpServerHost.
External Dependencies: TcpListener, appsettings-driven folder/port.
Internal Coupling: MainForm via MessageReceived event.
Observations: SaveIncomingEmails gates .eml writes (default off). Silent-next mode sends no reply after DATA; thread-safe mode flags for concurrent clients. ResponseDelaySeconds applies once before the post-DATA outcome only; all other SMTP replies are immediate.
*/
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace SimpleMailServer;

internal sealed class SmtpServerHost : IDisposable
{
    private readonly SmtpServerSettings _settings;
    private readonly object _modeLock = new();
    private SmtpResponseMode _responseMode = SmtpResponseMode.Ok;
    private bool _silentNextMessage;
    private bool _saveIncomingEmails;
    private TcpListener? _listener;
    private CancellationTokenSource? _runCts;
    private Task? _acceptLoop;

    public SmtpServerHost(SmtpServerSettings settings)
    {
        _settings = settings;
    }

    public event Action<MessageHistoryEntry>? MessageReceived;

    public SmtpResponseMode ResponseMode
    {
        get
        {
            lock (_modeLock)
                return _responseMode;
        }
        set
        {
            lock (_modeLock)
                _responseMode = value;
        }
    }

    public void ArmSilentNextMessage()
    {
        lock (_modeLock)
            _silentNextMessage = true;
    }

    public bool SaveIncomingEmails
    {
        get
        {
            lock (_modeLock)
                return _saveIncomingEmails;
        }
        set
        {
            lock (_modeLock)
                _saveIncomingEmails = value;
        }
    }

    public bool IsRunning => _runCts is { IsCancellationRequested: false };

    public void Start()
    {
        if (IsRunning)
            return;

        _runCts = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Any, _settings.Port);
        _listener.Start();
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_runCts.Token));
    }

    public async Task StopAsync()
    {
        if (_runCts is null)
            return;

        await _runCts.CancelAsync();
        _listener?.Stop();
        if (_acceptLoop is not null)
        {
            try
            {
                await _acceptLoop;
            }
            catch (OperationCanceledException)
            {
            }
        }

        _runCts.Dispose();
        _runCts = null;
        _listener = null;
        _acceptLoop = null;
    }

    public void Dispose()
    {
        StopAsync().GetAwaiter().GetResult();
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                TcpClient client = await _listener!.AcceptTcpClientAsync(cancellationToken);
                _ = Task.Run(() => HandleClientAsync(client, cancellationToken), cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
        await using NetworkStream stream = client.GetStream();
        using var writer = new StreamWriter(stream, Encoding.ASCII) { AutoFlush = true };
        using var reader = new StreamReader(stream, Encoding.ASCII);

        await WriteResponseLineAsync(writer, "220 localhost Simple SMTP Server", cancellationToken);

        string? sender = null;
        string? recipient = null;
        var dataBuilder = new StringBuilder();
        bool dataMode = false;

        while (client.Connected && !cancellationToken.IsCancellationRequested)
        {
            string? line = await reader.ReadLineAsync(cancellationToken);
            if (line is null)
                break;

            if (dataMode)
            {
                if (line == ".")
                {
                    dataMode = false;
                    await CompleteDataPhaseAsync(writer, sender, recipient, dataBuilder.ToString(), cancellationToken);
                    dataBuilder.Clear();
                }
                else
                {
                    dataBuilder.AppendLine(line);
                }

                continue;
            }

            if (line.StartsWith("HELO", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("EHLO", StringComparison.OrdinalIgnoreCase))
            {
                await WriteResponseLineAsync(writer, "250 Hello", cancellationToken);
            }
            else if (line.StartsWith("MAIL FROM:", StringComparison.OrdinalIgnoreCase))
            {
                sender = line[10..].Trim();
                await WriteResponseLineAsync(writer, "250 OK", cancellationToken);
            }
            else if (line.StartsWith("RCPT TO:", StringComparison.OrdinalIgnoreCase))
            {
                recipient = line[8..].Trim();
                await WriteResponseLineAsync(writer, "250 OK", cancellationToken);
            }
            else if (line.Equals("DATA", StringComparison.OrdinalIgnoreCase))
            {
                await WriteResponseLineAsync(writer, "354 End data with <CR><LF>.<CR><LF>", cancellationToken);
                dataMode = true;
            }
            else if (line.Equals("QUIT", StringComparison.OrdinalIgnoreCase))
            {
                await WriteResponseLineAsync(writer, "221 Bye", cancellationToken);
                break;
            }
            else if (line.Equals("NOOP", StringComparison.OrdinalIgnoreCase))
            {
                await WriteResponseLineAsync(writer, "250 OK", cancellationToken);
            }
            else
            {
                await WriteResponseLineAsync(writer, "500 Command not recognized", cancellationToken);
            }
        }
        }
    }

    private async Task CompleteDataPhaseAsync(
        StreamWriter writer,
        string? sender,
        string? recipient,
        string body,
        CancellationToken cancellationToken)
    {
        bool silent;
        SmtpResponseMode mode;
        lock (_modeLock)
        {
            silent = _silentNextMessage;
            if (silent)
                _silentNextMessage = false;
            mode = _responseMode;
        }

        string? savedPath = null;
        bool saveToDisk;
        lock (_modeLock)
            saveToDisk = _saveIncomingEmails;

        if (saveToDisk)
        {
            Directory.CreateDirectory(_settings.SavedMessageFolder);
            string timestamp = DateTime.Now.ToString("yyyyMMddHHmmssfff");
            savedPath = Path.Combine(_settings.SavedMessageFolder, $"{timestamp}.eml");
            await File.WriteAllTextAsync(savedPath, body, cancellationToken);
        }

        await ApplyResponseDelayAsync(cancellationToken);

        SmtpMessageOutcome outcome;
        if (silent)
        {
            outcome = SmtpMessageOutcome.Silent;
        }
        else if (mode == SmtpResponseMode.Ok)
        {
            outcome = SmtpMessageOutcome.Ok;
            await WriteResponseLineAsync(writer, "250 OK", cancellationToken);
        }
        else if (mode == SmtpResponseMode.NoSuchUser)
        {
            outcome = SmtpMessageOutcome.NoSuchUser;
            await WriteResponseLineAsync(writer, "550 %No such user here%", cancellationToken);
        }
        else
        {
            outcome = SmtpMessageOutcome.TempFailure;
            await WriteResponseLineAsync(writer, "451 local error in processing", cancellationToken);
        }

        MessageReceived?.Invoke(new MessageHistoryEntry
        {
            ReceivedAt = DateTime.Now,
            From = sender,
            To = recipient,
            Subject = TryParseSubject(body),
            Outcome = outcome,
            SavedFilePath = savedPath
        });
    }

    private static string? TryParseSubject(string body)
    {
        if (string.IsNullOrEmpty(body))
            return null;

        using var reader = new StringReader(body);
        string? line;
        string? subject = null;
        while ((line = reader.ReadLine()) is not null)
        {
            if (line.Length == 0)
                break;

            if (subject is not null && (line[0] == ' ' || line[0] == '\t'))
            {
                subject += " " + line.Trim();
                continue;
            }

            subject = null;
            if (line.StartsWith("Subject:", StringComparison.OrdinalIgnoreCase))
                subject = line[8..].Trim();
        }

        return subject;
    }

    private static Task WriteResponseLineAsync(StreamWriter writer, string line, CancellationToken cancellationToken) =>
        writer.WriteLineAsync(line.AsMemory(), cancellationToken);

    private async Task ApplyResponseDelayAsync(CancellationToken cancellationToken)
    {
        if (_settings.ResponseDelaySeconds <= 0)
            return;

        int milliseconds = (int)Math.Round(_settings.ResponseDelaySeconds * 1000, MidpointRounding.AwayFromZero);
        if (milliseconds > 0)
            await Task.Delay(milliseconds, cancellationToken);
    }
}
