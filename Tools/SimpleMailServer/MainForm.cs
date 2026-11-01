/*
FILE SUMMARY
Purpose: WinForms UI for the SMTP test server — response mode, save/.eml controls, message history.
Key Types: MainForm.
External Dependencies: System.Windows.Forms; Process.Start for opening .eml files.
Internal Coupling: SmtpServerHost, SmtpServerSettings, AppSettingsFile, MessageHistoryEntry.
Observations: History grid row order matches _history (newest first). Erase deletes all .eml under SavedMessageFolder, including previous runs.
*/
using System.Diagnostics;

namespace SimpleMailServer;

internal sealed class MainForm : Form
{
    private readonly SmtpServerSettings _settings;
    private readonly SmtpServerHost _server;
    private readonly RadioButton _modeOk;
    private readonly RadioButton _modeTempFailure;
    private readonly RadioButton _modeNoSuchUser;
    private readonly Button _noAckNextButton;
    private readonly NumericUpDown _responseDelaySeconds;
    private readonly CheckBox _saveIncomingCheckBox;
    private readonly Button _eraseSavedEmailsButton;
    private readonly DataGridView _historyGrid;
    private readonly Label _listenPortLabel;
    private readonly Label _statusLabel;
    private readonly ToolTip _toolTip = new();
    private readonly List<MessageHistoryEntry> _history = [];
    private bool _suppressDelayChange;

    public MainForm(SmtpServerSettings settings)
    {
        _settings = settings;
        _server = new SmtpServerHost(settings);
        _server.MessageReceived += OnMessageReceived;

        Text = "Simple SMTP Server";
        ApplyExecutableIcon();
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(820, 480);
        Size = new Size(900, 560);
        Font = new Font("Segoe UI", 9F);

        _listenPortLabel = new Label
        {
            Dock = DockStyle.Top,
            AutoSize = false,
            Height = 32,
            Padding = new Padding(10, 8, 10, 4),
            Font = new Font(Font.FontFamily, Font.Size, FontStyle.Bold),
            Text = $"SMTP listener — port {_settings.Port} (starting…)"
        };

        _statusLabel = new Label
        {
            Dock = DockStyle.Bottom,
            Height = 28,
            Padding = new Padding(10, 4, 10, 4),
            Text = "Starting…"
        };

        _saveIncomingCheckBox = new CheckBox
        {
            Text = "Save incoming messages to",
            AutoSize = true,
            Checked = _settings.SaveIncomingEmails,
            Margin = new Padding(0, 4, 8, 0),
            Anchor = AnchorStyles.Left
        };
        _saveIncomingCheckBox.CheckedChanged += (_, _) =>
        {
            _server.SaveIncomingEmails = _saveIncomingCheckBox.Checked;
            if (_server.IsRunning)
            {
                _statusLabel.Text =
                    $"{BuildListenStatus()} | Mode: {DescribeMode(_server.ResponseMode)}";
            }
        };

        _eraseSavedEmailsButton = new Button
        {
            Text = "Erase saved emails",
            AutoSize = true,
            Margin = new Padding(8, 0, 0, 0),
            Anchor = AnchorStyles.Right
        };
        _eraseSavedEmailsButton.Click += (_, _) => EraseSavedEmails();

        _modeOk = new RadioButton
        {
            Text = "250 OK",
            AutoSize = true,
            Checked = true,
            Margin = new Padding(0, 0, 12, 0)
        };
        _modeTempFailure = new RadioButton
        {
            Text = "451 Temporary failure",
            AutoSize = true,
            Margin = new Padding(0, 0, 12, 0)
        };
        _modeNoSuchUser = new RadioButton
        {
            Text = "550 No such user",
            AutoSize = true,
            Margin = new Padding(0, 0, 12, 0)
        };
        _noAckNextButton = new Button
        {
            Text = "No ack on next message (once)",
            AutoSize = true,
            Margin = new Padding(8, 0, 0, 0)
        };
        _noAckNextButton.Click += (_, _) =>
        {
            _server.ArmSilentNextMessage();
            _statusLabel.Text =
                "Armed for next message: no SMTP acknowledgment (client may time out waiting for a reply).";
        };

        _responseDelaySeconds = new NumericUpDown
        {
            Minimum = 0,
            Maximum = 3600,
            DecimalPlaces = 2,
            Increment = 0.5M,
            Width = 80,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(8, 2, 0, 0)
        };
        LoadResponseDelayIntoSpinner();
        _responseDelaySeconds.ValueChanged += OnResponseDelayChanged;

        var delayLabel = new Label
        {
            Text = "Delay before post-DATA outcome (sec, 0 = none):",
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0, 6, 0, 0)
        };

        _modeOk.CheckedChanged += (_, _) => ApplyModeFromUi();
        _modeTempFailure.CheckedChanged += (_, _) => ApplyModeFromUi();
        _modeNoSuchUser.CheckedChanged += (_, _) => ApplyModeFromUi();

        var modeFlow = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = true,
            Margin = new Padding(0)
        };
        modeFlow.Controls.Add(_modeOk);
        modeFlow.Controls.Add(_modeTempFailure);
        modeFlow.Controls.Add(_modeNoSuchUser);
        modeFlow.Controls.Add(_noAckNextButton);

        var modeLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 3,
            Padding = new Padding(0)
        };
        modeLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        modeLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        modeLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        modeLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        modeLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        string savedFolderDisplay = string.IsNullOrWhiteSpace(_settings.SavedMessageFolder)
            ? "(not configured)"
            : _settings.SavedMessageFolder;
        var saveFolderLabel = new Label
        {
            Text = $" {savedFolderDisplay} ",
            AutoSize = false,
            AutoEllipsis = true,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            Margin = new Padding(0, 2, 0, 2),
            Padding = new Padding(6, 2, 6, 2),
            BackColor = SystemColors.Info,
            ForeColor = SystemColors.InfoText,
            BorderStyle = BorderStyle.FixedSingle
        };
        _toolTip.SetToolTip(saveFolderLabel, savedFolderDisplay);

        var saveRow = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 3,
            RowCount = 1,
            Margin = new Padding(0, 2, 0, 2),
            Padding = new Padding(0)
        };
        saveRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        saveRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        saveRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        saveRow.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        saveRow.Controls.Add(_saveIncomingCheckBox, 0, 0);
        saveRow.Controls.Add(saveFolderLabel, 1, 0);
        saveRow.Controls.Add(_eraseSavedEmailsButton, 2, 0);

        modeLayout.Controls.Add(modeFlow, 0, 0);
        modeLayout.SetColumnSpan(modeFlow, 2);
        modeLayout.Controls.Add(saveRow, 0, 1);
        modeLayout.SetColumnSpan(saveRow, 2);
        modeLayout.Controls.Add(delayLabel, 0, 2);
        modeLayout.Controls.Add(_responseDelaySeconds, 1, 2);

        var modePanel = new GroupBox
        {
            Text = "Response mode for incoming mail",
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(10, 14, 10, 10)
        };
        modePanel.Controls.Add(modeLayout);

        _historyGrid = new DataGridView
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            AllowUserToAddRows = false,
            AllowUserToDeleteRows = false,
            AllowUserToResizeRows = false,
            RowHeadersVisible = false,
            SelectionMode = DataGridViewSelectionMode.FullRowSelect,
            AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.None,
            ScrollBars = ScrollBars.Both,
            BackgroundColor = SystemColors.Window
        };
        _historyGrid.DefaultCellStyle.WrapMode = DataGridViewTriState.False;
        _historyGrid.CellMouseClick += OnHistoryCellMouseClick;
        _historyGrid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "Time",
            HeaderText = "Received",
            Width = 140,
            MinimumWidth = 120
        });
        _historyGrid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "Subject",
            HeaderText = "Subject",
            Width = 220,
            MinimumWidth = 80
        });
        _historyGrid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "From",
            HeaderText = "From",
            Width = 160,
            MinimumWidth = 80
        });
        _historyGrid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "To",
            HeaderText = "To",
            Width = 160,
            MinimumWidth = 80
        });
        _historyGrid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "Outcome",
            HeaderText = "Response",
            Width = 110,
            MinimumWidth = 80
        });
        _historyGrid.Columns.Add(new DataGridViewTextBoxColumn
        {
            Name = "Saved",
            HeaderText = "Saved file",
            Width = 280,
            MinimumWidth = 120
        });

        var historyHeader = new Panel
        {
            Dock = DockStyle.Top,
            Height = 32,
            Padding = new Padding(10, 4, 10, 0)
        };
        var historyLabel = new Label
        {
            Text = $"Message history (max {_settings.MaxHistoryEntries} entries) — right-click a row to open the saved email",
            AutoSize = true,
            Dock = DockStyle.Left,
            Padding = new Padding(0, 4, 0, 0)
        };
        var clearHistoryButton = new Button
        {
            Text = "Clear",
            AutoSize = true,
            Dock = DockStyle.Right
        };
        clearHistoryButton.Click += (_, _) => ClearHistory();
        historyHeader.Controls.Add(historyLabel);
        historyHeader.Controls.Add(clearHistoryButton);

        Controls.Add(_historyGrid);
        Controls.Add(historyHeader);
        Controls.Add(modePanel);
        Controls.Add(_listenPortLabel);
        Controls.Add(_statusLabel);

        Shown += OnShown;
        FormClosing += OnFormClosing;
    }

    private void OnShown(object? sender, EventArgs e)
    {
        _server.SaveIncomingEmails = _saveIncomingCheckBox.Checked;
        ApplyModeFromUi();
        try
        {
            _server.Start();
            _listenPortLabel.Text = FormatListeningOnPort();
            _statusLabel.Text = BuildListenStatus();
        }
        catch (Exception ex)
        {
            _listenPortLabel.Text = $"SMTP listener — port {_settings.Port} (failed to start)";
            _statusLabel.Text = "Failed to start SMTP listener.";
            MessageBox.Show(this, ex.Message, "Simple SMTP Server", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private async void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        await _server.StopAsync();
    }

    private void ApplyModeFromUi()
    {
        if (_modeOk.Checked)
            _server.ResponseMode = SmtpResponseMode.Ok;
        else if (_modeTempFailure.Checked)
            _server.ResponseMode = SmtpResponseMode.TempFailure;
        else if (_modeNoSuchUser.Checked)
            _server.ResponseMode = SmtpResponseMode.NoSuchUser;

        if (_server.IsRunning)
        {
            _statusLabel.Text =
                $"{BuildListenStatus()} | Mode: {DescribeMode(_server.ResponseMode)}";
        }
    }

    private string FormatListeningOnPort() =>
        $"Listening on port {_settings.Port}";

    private string BuildListenStatus()
    {
        string savePart = _server.SaveIncomingEmails
            ? $"Save .eml → {_settings.SavedMessageFolder}"
            : "Save .eml: off";
        return $"Response delay {FormatDelay(_settings.ResponseDelaySeconds)} | {savePart}";
    }

    private void LoadResponseDelayIntoSpinner()
    {
        _suppressDelayChange = true;
        decimal clamped = (decimal)Math.Clamp(_settings.ResponseDelaySeconds, 0, 3600);
        _responseDelaySeconds.Value = clamped;
        _suppressDelayChange = false;
    }

    private void OnResponseDelayChanged(object? sender, EventArgs e)
    {
        if (_suppressDelayChange)
            return;

        _settings.ResponseDelaySeconds = (double)_responseDelaySeconds.Value;
        try
        {
            AppSettingsFile.SaveResponseDelaySeconds(_settings.ResponseDelaySeconds);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Save settings", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            LoadResponseDelayIntoSpinner();
            return;
        }

        if (_server.IsRunning)
            _statusLabel.Text = $"{BuildListenStatus()} | Mode: {DescribeMode(_server.ResponseMode)}";
    }

    private static string FormatDelay(double seconds) =>
        seconds <= 0 ? "0s (none)" : $"{seconds:G}s";

    private void ClearHistory()
    {
        _history.Clear();
        _historyGrid.Rows.Clear();
        if (_server.IsRunning)
        {
            _statusLabel.Text =
                $"{BuildListenStatus()} | Mode: {DescribeMode(_server.ResponseMode)}";
        }
    }

    private void EraseSavedEmails()
    {
        string folder = _settings.SavedMessageFolder;
        if (string.IsNullOrWhiteSpace(folder))
        {
            MessageBox.Show(
                this,
                "Saved message folder is not configured.",
                "Erase saved emails",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        if (!Directory.Exists(folder))
        {
            MessageBox.Show(
                this,
                $"Folder does not exist:\n{folder}",
                "Erase saved emails",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        DialogResult confirm = MessageBox.Show(
            this,
            $"Delete all .eml files in:\n{folder}\n\nThis includes messages from previous runs.",
            "Erase saved emails",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (confirm != DialogResult.Yes)
            return;

        string[] files = Directory.GetFiles(folder, "*.eml");
        int deleted = 0;
        int failed = 0;
        foreach (string file in files)
        {
            try
            {
                File.Delete(file);
                deleted++;
            }
            catch
            {
                failed++;
            }
        }

        foreach (MessageHistoryEntry entry in _history)
            entry.SavedFilePath = null;

        RefreshHistoryGrid();

        string status =
            failed == 0
                ? $"Erased {deleted} saved .eml file(s)."
                : $"Erased {deleted} saved .eml file(s); {failed} could not be deleted.";
        _statusLabel.Text = _server.IsRunning
            ? $"{BuildListenStatus()} | {status} | Mode: {DescribeMode(_server.ResponseMode)}"
            : status;

        if (failed > 0)
        {
            MessageBox.Show(
                this,
                status,
                "Erase saved emails",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private void OnHistoryCellMouseClick(object? sender, DataGridViewCellMouseEventArgs e)
    {
        if (e.Button != MouseButtons.Right || e.RowIndex < 0 || e.RowIndex >= _history.Count)
            return;

        _historyGrid.ClearSelection();
        _historyGrid.Rows[e.RowIndex].Selected = true;

        string? path = _history[e.RowIndex].SavedFilePath;
        if (string.IsNullOrWhiteSpace(path))
        {
            MessageBox.Show(
                this,
                "This message was not saved to a file.",
                "Open email",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        if (!File.Exists(path))
        {
            MessageBox.Show(
                this,
                $"File not found:\n{path}",
                "Open email",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = path,
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                ex.Message,
                "Open email",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private void OnMessageReceived(MessageHistoryEntry entry)
    {
        void Apply()
        {
            _history.Insert(0, entry);
            while (_history.Count > _settings.MaxHistoryEntries)
                _history.RemoveAt(_history.Count - 1);

            RefreshHistoryGrid();

            _statusLabel.Text =
                $"{BuildListenStatus()} | Last: {OutcomeText(entry.Outcome)} from {entry.From} | Mode: {DescribeMode(_server.ResponseMode)}";
        }

        if (InvokeRequired)
            BeginInvoke(Apply);
        else
            Apply();
    }

    private void RefreshHistoryGrid()
    {
        _historyGrid.Rows.Clear();
        foreach (MessageHistoryEntry row in _history)
        {
            _historyGrid.Rows.Add(
                row.ReceivedAt.ToString("yyyy-MM-dd HH:mm:ss"),
                row.Subject ?? "",
                row.From ?? "",
                row.To ?? "",
                OutcomeText(row.Outcome),
                row.SavedFilePath ?? "");
        }
    }

    private static string DescribeMode(SmtpResponseMode mode) => mode switch
    {
        SmtpResponseMode.Ok => "250 OK",
        SmtpResponseMode.TempFailure => "451 temp failure",
        SmtpResponseMode.NoSuchUser => "550 no such user",
        _ => "?"
    };

    private static string OutcomeText(SmtpMessageOutcome outcome) => outcome switch
    {
        SmtpMessageOutcome.Ok => "250 OK",
        SmtpMessageOutcome.TempFailure => "451 temp failure",
        SmtpMessageOutcome.NoSuchUser => "550 no such user",
        SmtpMessageOutcome.Silent => "No acknowledgment",
        _ => "?"
    };

    private void ApplyExecutableIcon()
    {
        Icon? executableIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        if (executableIcon is not null)
            Icon = executableIcon;
    }
}
