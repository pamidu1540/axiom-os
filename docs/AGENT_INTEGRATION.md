# Agent integration

Finite CLI commands return one JSON document when `--json` is supplied. Human-readable banners are not mixed into JSON. Process stdout/stderr is captured inside the response. Errors return a nonzero shell exit status.

The built-in MCP server is read-only and uses the 2025-06-18 protocol over stdio. It supports initialization, ping, tools/list, and tools/call. Its three tools inspect the selected workspace's environment, managed tasks, and snapshots. It does not launch builds, execute arbitrary code, expose secrets, or accept a workspace supplied by a tool call.

Example configuration for a client with stdio MCP support (replace the paths):

```json
{
  "mcpServers": {
    "axiom-os": {
      "command": "C:\\Users\\you\\AppData\\Local\\Programs\\AxiomOS\\axiom.exe",
      "args": ["mcp", "start", "--workspace", "C:\\Projects\\MyWorkspace"]
    }
  }
}
```

Client configuration formats vary. Start the server as a child process, complete initialization, then call the advertised tools. Closing stdin shuts down the server. stdout is reserved for protocol messages. No network listener is opened.

The protocol reference is https://modelcontextprotocol.io/specification/2025-06-18. This implementation has local protocol regression coverage; it does not claim certification or testing with every client.
