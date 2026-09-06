#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Axiom OS — mcp.ps1
    Antigravity MCP bridge. JSON-RPC agent interface for all Axiom OS subsystems.
#>

function Invoke-AxiomMcp {
    param([string]$Verb, [string[]]$Params, $Ctx)

    switch ($Verb.ToLower()) {
        "start"  { Mcp-Start }
        "stop"   { Mcp-Stop }
        "status" { Mcp-Status $Ctx }
        "schema" { Mcp-Schema }
        default  { Axiom-Error "Unknown mcp verb: $Verb. Use: start|stop|status|schema" }
    }
}

function Mcp-Start {
    Axiom-Banner "MCP Bridge — Agent Mode"
    Write-Host '{"axiom_mcp":"ready","version":"1.1.0","transport":"stdout","tools":["compile","sandbox","task","ps","env","vault","guard","run","watch"]}'
    Axiom-Info "Axiom OS MCP bridge active. All subsequent commands output structured JSON."
    Axiom-Info "Agents: use --json flag on any command to get machine-readable output."
}

function Mcp-Stop {
    Write-Host '{"axiom_mcp":"stopped"}'
}

function Mcp-Status {
    param($Ctx)
    $session = Get-AxiomSession $Ctx
    $status = @{
        axiom_version    = "1.1.0"
        mcp_active       = $true
        workspace_root   = $Ctx.WorkspaceRoot
        session_id       = $session.session_id
        active_sandboxes = $session.active_sandboxes
        running_tasks    = $session.running_tasks
    }
    if ($Ctx.Json) {
        Write-AxiomJson -Command "mcp status" -Output $status -Ctx $Ctx
    } else {
        $status.GetEnumerator() | ForEach-Object { Axiom-Info "$($_.Key): $($_.Value)" }
    }
}

function Mcp-Schema {
    $schema = @{
        tools = @(
            @{ name="axiom_compile"; description="Cross-compile a project to target OS/arch"; params=@("path","os","arch","--all-targets","--bundle","--dry-run","--json") },
            @{ name="axiom_sandbox"; description="Create/manage ephemeral isolated workspaces"; params=@("verb","path/id","--name","--ttl") },
            @{ name="axiom_task";    description="Start/stop/inspect named background processes"; params=@("verb","command","--name","--cwd","--restart-on-crash") },
            @{ name="axiom_ps";      description="List all running background tasks"; params=@("--json") },
            @{ name="axiom_env";     description="Query and activate toolchain environments"; params=@("verb","--json") },
            @{ name="axiom_vault";   description="Read/write encrypted secrets via DPAPI vault"; params=@("action","key","value") },
            @{ name="axiom_guard";   description="Run secret leak scans and security policy checks"; params=@("verb","--staged","--path") },
            @{ name="axiom_run";     description="Execute named tasks from Taskfile.yml"; params=@("taskname","--list","--dry-run") },
            @{ name="axiom_watch";   description="Watch filesystem and trigger commands on change"; params=@("glob","--run","--debounce") }
        )
    }
    Write-Output ($schema | ConvertTo-Json -Depth 5)
}

