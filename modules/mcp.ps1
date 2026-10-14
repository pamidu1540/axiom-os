function Get-AxiomMcpTools {
    @(
        @{ name='axiom_environment'; description='Read workspace path, runtime version, and platform.'; inputSchema=@{type='object';properties=@{};additionalProperties=$false}; annotations=@{readOnlyHint=$true;openWorldHint=$false} }
        @{ name='axiom_tasks'; description='List processes registered by Axiom in this workspace.'; inputSchema=@{type='object';properties=@{};additionalProperties=$false}; annotations=@{readOnlyHint=$true;openWorldHint=$false} }
        @{ name='axiom_snapshots'; description='List project snapshots in this workspace.'; inputSchema=@{type='object';properties=@{};additionalProperties=$false}; annotations=@{readOnlyHint=$true;openWorldHint=$false} }
    )
}

function Invoke-AxiomMcp {
    param([string]$Verb,[string[]]$Params,$Ctx)
    switch ($Verb) {
        schema { @{tools=@(Get-AxiomMcpTools)} | ConvertTo-Json -Depth 12; return }
        status { Write-AxiomResult 'mcp status' @{ transport='stdio'; protocol='2025-06-18'; tools=3; mode='read-only'; lifecycle='Client launches a server process; close stdin to stop it.' } $Ctx 'MCP configuration'; return }
        start { }
        default { throw 'Use mcp start, schema, or status. Close server stdin to stop a stdio session.' }
    }
    if ($Ctx.DryRun) { Write-AxiomResult 'mcp start' @{dry_run=$true;transport='stdio'} $Ctx 'MCP preview'; return }
    $initialized=$false; $negotiated=$false
    $Ctx.Json=$true
    :McpLoop while ($null -ne ($line=[Console]::ReadLine())) {
        $request=$null; $id=$null; $response=$null
        try {
            if ($line.Length -gt 1MB) { throw 'Request too large.' }
            try { $request=$line | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
            catch { $response=@{jsonrpc='2.0';id=$null;error=@{code=-32700;message='Parse error'}}; continue }
            if ($request -isnot [Collections.IDictionary] -or $request.jsonrpc -ne '2.0' -or $request.method -isnot [string]) {
                $response=@{jsonrpc='2.0';id=$null;error=@{code=-32600;message='Invalid Request'}}; continue
            }
            if (-not $request.ContainsKey('id')) {
                if ($request.method -eq 'notifications/initialized' -and $negotiated) { $initialized=$true }
                continue
            }
            $id=$request.id; $result=$null
            if ($request.method -notin @('initialize','ping') -and -not $initialized) { $response=@{jsonrpc='2.0';id=$id;error=@{code=-32002;message='Initialize the server first.'}}; continue }
            switch ($request.method) {
                initialize {
                    if ($negotiated) { throw 'Server is already initialized.' }
                    $negotiated=$true
                    $result=@{ protocolVersion='2025-06-18'; capabilities=@{tools=@{listChanged=$false}}; serverInfo=@{name='axiom-os';version=$AxiomVersion}; instructions='Read-only workspace inspection. This server does not execute arbitrary commands or expose vault values.' }
                }
                ping { $result=@{} }
                'tools/list' { $result=@{tools=@(Get-AxiomMcpTools)} }
                'tools/call' {
                    $tool=$request.params.name; $arguments=$request.params.arguments
                    if ($arguments -and $arguments.Count) { throw 'These read-only tools accept no arguments.' }
                    $text=switch ($tool) {
                        axiom_environment { . (Join-Path $PSScriptRoot 'env.ps1'); Invoke-AxiomEnv 'info' @() $Ctx }
                        axiom_tasks { . (Join-Path $PSScriptRoot 'process.ps1'); Invoke-AxiomProcess 'list' @() $Ctx }
                        axiom_snapshots { . (Join-Path $PSScriptRoot 'sandbox.ps1'); Invoke-AxiomSandbox 'list' @() $Ctx }
                        default { throw 'Unknown tool.' }
                    }
                    $result=@{content=@(@{type='text';text=($text -join "`n")});isError=$false}
                }
                default { $response=@{jsonrpc='2.0';id=$id;error=@{code=-32601;message='Method not found'}}; continue McpLoop }
            }
            $response=@{jsonrpc='2.0';id=$id;result=$result}
        } catch {
            $response=@{jsonrpc='2.0';id=$id;error=@{code=-32602;message=$_.Exception.Message}}
        } finally {
            if ($response) { [Console]::WriteLine(($response | ConvertTo-Json -Depth 20 -Compress)); [Console]::Out.Flush() }
        }
    }
}
