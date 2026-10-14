using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace AxiomDesktop {
    internal static class AppCommon {
        public static readonly string Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        public static readonly string Runtime = Path.Combine(Root, "runtime", "pwsh.exe");
        public static readonly string Entry = Path.Combine(Root, "axiom.ps1");
        public static string DataRoot { get { return Environment.GetEnvironmentVariable("AXIOM_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AxiomOS"); } }
        public static string SettingsPath { get { return Path.Combine(DataRoot, "settings.json"); } }
        public static string DefaultWorkspace { get { string documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments); if (String.IsNullOrEmpty(documents)) documents = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Documents"); return Path.Combine(documents, "AxiomWorkspace"); } }
        public static string SavedWorkspace() {
            if (!File.Exists(SettingsPath)) return DefaultWorkspace;
            try {
                var settings = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(SettingsPath));
                object value;
                return settings != null && settings.TryGetValue("workspace", out value) ? Convert.ToString(value) : DefaultWorkspace;
            } catch (ArgumentException) { return DefaultWorkspace; }
        }
        public static string ValidateWorkspace(string workspace) {
            if (String.IsNullOrWhiteSpace(workspace)) throw new ArgumentException("Choose a workspace folder.");
            string path = Path.GetFullPath(workspace.Trim());
            if (path.Equals(Root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Choose a folder outside the installed application so updates and uninstall preserve your projects.");
            if (File.Exists(path)) throw new ArgumentException("Choose a folder, not a file.");
            return path;
        }
        public static void SaveWorkspace(string workspace, bool starter) {
            workspace = ValidateWorkspace(workspace);
            Directory.CreateDirectory(workspace);
            Directory.CreateDirectory(DataRoot);
            string temporary = Path.Combine(DataRoot, Guid.NewGuid().ToString("N") + ".tmp");
            try {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(new { version = 1, workspace = workspace }), new UTF8Encoding(false));
                if (File.Exists(SettingsPath)) File.Replace(temporary, SettingsPath, null); else File.Move(temporary, SettingsPath);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
            if (starter) {
                string tasks = Path.Combine(workspace, "axiom.tasks.json");
                if (!File.Exists(tasks)) {
                    var sample = new { tasks = new Dictionary<string, object> {
                        { "hello", new { command = "Write-Output 'Hello from Axiom OS'", description = "Try the task runner" } },
                        { "doctor", new { command = "axiom env check", description = "Check optional build tools" } }
                    }};
                    using (var file = new FileStream(tasks, FileMode.CreateNew, FileAccess.Write)) {
                        byte[] bytes = new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(sample)); file.Write(bytes, 0, bytes.Length);
                    }
                }
            }
        }
        // Quote each Windows argv element, including embedded quotes and trailing backslashes.
        public static string Quote(string value) {
            var output = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { output.Append('\\', slashes * 2 + 1); output.Append(c); }
                else { output.Append('\\', slashes); output.Append(c); }
                slashes = 0;
            }
            output.Append('\\', slashes * 2); output.Append('"'); return output.ToString();
        }
        public static string Arguments(IEnumerable<string> values) {
            var parts = new List<string>(); foreach (string value in values) parts.Add(Quote(value)); return String.Join(" ", parts.ToArray());
        }
        public static ProcessStartInfo PowerShell(IEnumerable<string> arguments, string workspace, bool redirect) {
            if (!File.Exists(Runtime) || !File.Exists(Entry)) throw new FileNotFoundException("The bundled runtime is missing. Reinstall Axiom OS or extract the full portable archive.");
            var info = new ProcessStartInfo(Runtime, Arguments(arguments));
            info.UseShellExecute = false; info.WorkingDirectory = workspace;
            info.CreateNoWindow = redirect; info.RedirectStandardOutput = redirect; info.RedirectStandardError = redirect;
            info.EnvironmentVariables["AXIOM_WORKSPACE"] = workspace;
            info.EnvironmentVariables["PATH"] = Root + Path.PathSeparator + info.EnvironmentVariables["PATH"];
            return info;
        }
        public static void OpenTerminal(string workspace) {
            string code = "Set-Location -LiteralPath '" + workspace.Replace("'", "''") + "'; & '" + Path.Combine(Root, "axiom.exe").Replace("'", "''") + "' --help";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(code));
            var info = PowerShell(new [] { "-NoProfile", "-NoExit", "-EncodedCommand", encoded }, workspace, false);
            Process.Start(info);
        }
    }
}
