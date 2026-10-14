using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace AxiomDesktop {
    internal sealed class Desktop : Form {
        private readonly TextBox workspace = new TextBox();
        private readonly Label status = new Label();
        private readonly CheckBox starter = new CheckBox();
        private readonly Button tools = new Button();
        private readonly TextBox report = new TextBox();
        private readonly Color background = Color.FromArgb(12, 19, 31);
        private readonly Color card = Color.FromArgb(24, 36, 53);
        private readonly Color accent = Color.FromArgb(94, 234, 180);
        public Desktop() {
            Text = "Axiom OS"; ClientSize = new Size(820, 720); MinimumSize = new Size(760, 690);
            AutoScaleMode = AutoScaleMode.Dpi; BackColor = background; ForeColor = Color.FromArgb(231, 237, 246);
            Font = new Font("Segoe UI", 10F); StartPosition = FormStartPosition.CenterScreen;
            string icon = Path.Combine(AppCommon.Root, "axiom.ico"); if (File.Exists(icon)) Icon = new Icon(icon);
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(32, 22, 32, 22), ColumnCount = 1, RowCount = 12 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
            Controls.Add(layout);
            layout.Controls.Add(Label("Axiom OS", 27, accent), 0, 0);
            layout.Controls.Add(Label("Your developer workspace, ready to use.", 13, ForeColor), 0, 1);
            layout.Controls.Add(Label("Run project tasks, plan builds, manage background processes, and work with project snapshots. PowerShell is included; language SDKs are optional.", 10, Color.FromArgb(165, 181, 202)), 0, 2);
            layout.Controls.Add(Label("WORKSPACE FOLDER", 9, accent), 0, 3);
            var folder = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0) };
            folder.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); folder.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 106));
            workspace.Dock = DockStyle.Fill; workspace.Margin = new Padding(0, 5, 12, 0); workspace.BackColor = card; workspace.ForeColor = ForeColor; workspace.BorderStyle = BorderStyle.FixedSingle;
            workspace.Text = AppCommon.SavedWorkspace(); folder.Controls.Add(workspace, 0, 0);
            folder.Controls.Add(Button("Browse…", false, delegate { using (var picker = new FolderBrowserDialog { Description = "Choose your Axiom workspace", SelectedPath = Directory.Exists(workspace.Text) ? workspace.Text : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) }) if (picker.ShowDialog(this) == DialogResult.OK) workspace.Text = picker.SelectedPath; }), 1, 0);
            layout.Controls.Add(folder, 0, 4);
            starter.Text = "Add starter tasks (existing files are preserved)"; starter.Checked = !File.Exists(AppCommon.SettingsPath); starter.Dock = DockStyle.Fill; starter.ForeColor = ForeColor;
            layout.Controls.Add(starter, 0, 5);
            layout.Controls.Add(Button("Save workspace & open terminal", true, delegate { RunSafely(delegate { AppCommon.SaveWorkspace(workspace.Text, starter.Checked); status.Text = "Workspace saved. Your terminal is ready."; AppCommon.OpenTerminal(AppCommon.SavedWorkspace()); }); }), 0, 6);
            var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = new Padding(0, 4, 0, 0) };
            tools.Text = "Check build tools"; StyleButton(tools, false); tools.Width = 166; tools.Click += CheckTools; actions.Controls.Add(tools);
            var open = Button("Open folder", false, delegate { RunSafely(delegate { AppCommon.SaveWorkspace(workspace.Text, false); Process.Start(new ProcessStartInfo(AppCommon.SavedWorkspace()) { UseShellExecute = true }); }); }); open.Width = 140; actions.Controls.Add(open);
            var guide = Button("Quick start", false, delegate { RunSafely(delegate { Process.Start(new ProcessStartInfo(Path.Combine(AppCommon.Root, "docs", "QUICKSTART.html")) { UseShellExecute = true }); }); }); guide.Width = 140; actions.Controls.Add(guide);
            layout.Controls.Add(actions, 0, 7);
            status.Text = File.Exists(AppCommon.SettingsPath) ? "Workspace configured. Open a terminal to get started." : "Choose a folder to keep your projects and local state.";
            status.Dock = DockStyle.Fill; status.ForeColor = accent; status.TextAlign = ContentAlignment.MiddleLeft; layout.Controls.Add(status, 0, 8);
            report.Dock = DockStyle.Fill; report.Multiline = true; report.ReadOnly = true; report.ScrollBars = ScrollBars.Vertical; report.BackColor = card; report.ForeColor = ForeColor; report.BorderStyle = BorderStyle.FixedSingle; report.Font = new Font("Consolas", 10F);
            report.Text = "Try these in your workspace terminal:\r\n\r\n  axiom env check\r\n  axiom run hello\r\n  axiom ps --json\r\n\r\nBuild tools such as Go, Rust, Python, and Node.js are installed separately.";
            layout.Controls.Add(report, 0, 9);
            layout.Controls.Add(Label("Snapshots are file copies, not OS isolation. Run commands only from projects you trust.", 9, Color.FromArgb(165, 181, 202)), 0, 10);
            layout.Controls.Add(Label("Axiom OS 1.2.0  •  Local workspace toolkit  •  MIT licensed", 9, Color.FromArgb(130, 149, 173)), 0, 11);
        }
        private Label Label(string text, float size, Color color) { return new Label { Text = text, Dock = DockStyle.Fill, ForeColor = color, Font = new Font("Segoe UI", size, size > 20 ? FontStyle.Bold : FontStyle.Regular), TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(0) }; }
        private void StyleButton(Button button, bool primary) { button.Height = 40; button.UseMnemonic = false; button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderSize = 0; button.BackColor = primary ? accent : card; button.ForeColor = primary ? background : ForeColor; button.Font = new Font("Segoe UI", 10F, FontStyle.Bold); button.Cursor = Cursors.Hand; button.Margin = new Padding(0, 0, 10, 4); }
        private Button Button(string text, bool primary, EventHandler action) { var button = new Button { Text = text, Dock = DockStyle.Fill }; StyleButton(button, primary); button.Click += action; return button; }
        private void RunSafely(Action action) { try { action(); } catch (Exception error) { status.Text = error.Message; MessageBox.Show(this, error.Message, "Axiom OS", MessageBoxButtons.OK, MessageBoxIcon.Warning); } }
        private static string ToolReport(string selectedWorkspace) {
            var info = AppCommon.PowerShell(new [] { "-NoProfile", "-File", AppCommon.Entry, "env", "check", "--json" }, selectedWorkspace, true);
            using (var process = Process.Start(info)) {
                var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(90000)) { process.Kill(); throw new Exception("Tool check timed out."); }
                if (process.ExitCode != 0) throw new Exception(stderr.Result);
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(stdout.Result);
                var output = (Dictionary<string, object>)data["output"]; var rows = (IEnumerable)output["tools"];
                var lines = new List<string> { "PowerShell is bundled and ready.", "" };
                foreach (var row in rows) { var tool = (Dictionary<string, object>)row; lines.Add(Convert.ToString(tool["tool"]).PadRight(10) + ((bool)tool["available"] ? "Available    " + Convert.ToString(tool["version"]).Replace("\n", " ") : "Not installed / unavailable")); }
                return String.Join("\r\n", lines.ToArray());
            }
        }
        private async void CheckTools(object sender, EventArgs e) {
            try {
                AppCommon.SaveWorkspace(workspace.Text, false); tools.Enabled = false; status.Text = "Checking optional tools…";
                string text = await Task.Run(delegate { return ToolReport(AppCommon.SavedWorkspace()); });
                report.Text = text; status.Text = "Check complete. Missing SDKs are optional until you build that language.";
            } catch (Exception error) { status.Text = "Could not complete the tool check."; report.Text = error.Message; }
            finally { tools.Enabled = true; }
        }
        [STAThread]
        public static int Main(string[] args) {
            try {
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                if (args.Length == 2 && args[0] == "--configure") { AppCommon.SaveWorkspace(args[1], true); return 0; }
                if (args.Length == 2 && args[0] == "--check-tools") { File.WriteAllText(args[1], ToolReport(AppCommon.SavedWorkspace())); return 0; }
                if (args.Length == 2 && args[0] == "--diagnostics") {
                    using (var form = new Desktop()) {
                        form.workspace.Text = "C:\\Projects\\AxiomWorkspace";
                        form.StartPosition = FormStartPosition.Manual;
                        form.Location = new Point(-30000, -30000);
                        form.ShowInTaskbar = false; form.Opacity = 0;
                        form.Show(); Application.DoEvents();
                        form.workspace.SelectionLength = 0; form.ActiveControl = null;
                        form.PerformLayout();
                        using (var image = new Bitmap(form.Width, form.Height)) { form.DrawToBitmap(image, new Rectangle(0, 0, image.Width, image.Height)); image.Save(Path.ChangeExtension(args[1], ".png")); }
                        form.Hide();
                    }
                    File.WriteAllText(args[1], new JavaScriptSerializer().Serialize(new { runtime = File.Exists(AppCommon.Runtime), entry = File.Exists(AppCommon.Entry), desktop = true, version = "1.2.0" })); return 0;
                }
                if (args.Length == 1 && args[0] == "--terminal" && File.Exists(AppCommon.SettingsPath)) { AppCommon.OpenTerminal(AppCommon.SavedWorkspace()); return 0; }
                Application.Run(new Desktop()); return 0;
            } catch (Exception error) {
                if (args.Length > 0 && args[0] != "--terminal") Console.Error.WriteLine(error.Message);
                else MessageBox.Show(error.Message, "Axiom OS", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
