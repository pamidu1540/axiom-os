using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace AxiomDesktop {
    internal static class Cli {
        public static int Main(string[] args) {
            try {
                string workspace = Environment.GetEnvironmentVariable("AXIOM_WORKSPACE");
                if (String.IsNullOrWhiteSpace(workspace)) {
                    workspace = Directory.GetCurrentDirectory();
                    if (workspace.TrimEnd(Path.DirectorySeparatorChar).Equals(AppCommon.Root, StringComparison.OrdinalIgnoreCase)) workspace = AppCommon.SavedWorkspace();
                }
                // Explicit workspace flags must also set the process working directory.
                for (int i = 0; i < args.Length; i++) if (args[i] == "--workspace" && i + 1 < args.Length) workspace = Path.GetFullPath(args[i + 1]);
                if (!Directory.Exists(workspace)) throw new DirectoryNotFoundException("Workspace does not exist. Open Axiom OS from the Start menu to finish setup.");
                var arguments = new List<string> { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", AppCommon.Entry };
                arguments.AddRange(args);
                using (Process process = Process.Start(AppCommon.PowerShell(arguments, workspace, false))) { process.WaitForExit(); return process.ExitCode; }
            } catch (Exception error) { Console.Error.WriteLine("Axiom: " + error.Message); return 1; }
        }
    }
}
