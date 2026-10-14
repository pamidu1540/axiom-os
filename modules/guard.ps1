function Invoke-AxiomGuard {
    param([string]$Verb,[string[]]$Params,$Ctx)
    if ($Verb -eq 'vault') {
        $null=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $Ctx.VaultPath
        if (-not $IsWindows) { throw 'The built-in vault requires Windows DPAPI.' }
        if ($Params.Count -lt 1) { throw 'Use vault set, get, list, or remove.' }
        $action=$Params[0]; $name=if ($Params.Count -gt 1) { $Params[1] } else { '' }
        if (($action -eq 'exec' -and $Params.Count -ne 3) -or ($action -ne 'exec' -and $Params.Count -gt 2)) { throw 'Use vault set NAME with the secure prompt, or vault exec NAME "command". Never pass secret values on the command line.' }
        if ($action -ne 'list') {
            if ($name -notmatch '^[A-Z][A-Z0-9_]{0,127}$') { throw 'Secret names must use uppercase letters, numbers, and underscores.' }
        }
        $data=@{ version=1; keys=@{} }
        if (Test-Path -LiteralPath $Ctx.VaultPath) {
            $data=Get-Content -LiteralPath $Ctx.VaultPath -Raw | ConvertFrom-Json -AsHashtable
            if ($data.version -ne 1 -or $data.keys -isnot [Collections.IDictionary]) { throw 'Invalid vault format; existing data was not modified.' }
        }
        switch ($action) {
            set {
                if ($Ctx.Json) { throw 'Secret entry is interactive. Run vault set NAME without --json.' }
                if ($Ctx.DryRun) { Write-AxiomResult 'vault set' @{ name=$name; dry_run=$true } $Ctx 'Vault preview'; return }
                $secret=Read-Host "Enter $name (hidden)" -AsSecureString
                try {
                    if (-not $secret.Length) { throw 'Secret value cannot be empty.' }
                    $data.keys[$name]=ConvertFrom-SecureString $secret
                    Save-AxiomData $Ctx.VaultPath $data
                    if ($IsWindows) {
                        $directory=Split-Path $Ctx.VaultPath
                        $acl=Get-Acl -LiteralPath $directory; $acl.SetAccessRuleProtection($true,$false)
                        foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
                        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
                        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
                        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM','FullControl','ContainerInherit,ObjectInherit','None','Allow'))
                        Set-Acl -LiteralPath $directory -AclObject $acl
                    }
                } finally { $secret.Dispose() }
                Write-AxiomResult 'vault set' @{ name=$name; stored=$true } $Ctx 'Secret encrypted for your Windows account'
            }
            list { Write-AxiomResult 'vault list' @{ names=@($data.keys.Keys | Sort-Object) } $Ctx 'Stored secret names' }
            get {
                if (-not $data.keys.ContainsKey($name)) { throw 'Secret not found.' }
                Write-AxiomResult 'vault get' @{ name=$name; present=$true; encrypted=$true } $Ctx 'Secret is present; plaintext display is disabled'
            }
            exec {
                if (-not $data.keys.ContainsKey($name)) { throw 'Secret not found.' }
                if ($Ctx.DryRun) { Write-AxiomResult 'vault exec' @{ name=$name; dry_run=$true } $Ctx 'Vault command preview'; return }
                $secret=ConvertTo-SecureString $data.keys[$name]
                $pointer=[IntPtr]::Zero
                try {
                    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
                    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                    $result=Invoke-AxiomCommand $Params[2] $Ctx.WorkspaceRoot -EnvironmentVariables @{ $name=$plain }
                    $stdout=$result.stdout.Replace($plain,'[REDACTED]'); $stderr=$result.stderr.Replace($plain,'[REDACTED]')
                    if ($result.exit_code -ne 0) { throw "Vault command failed ($($result.exit_code)): $stderr" }
                    Write-AxiomResult 'vault exec' @{ name=$name; stdout=$stdout; stderr=$stderr; exit_code=$result.exit_code } $Ctx 'Command finished with a private child environment'
                } finally {
                    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
                    $secret.Dispose(); $plain=$null
                }
            }
            remove {
                if (-not $data.keys.ContainsKey($name)) { throw 'Secret not found.' }
                if (-not $Ctx.DryRun) { $data.keys.Remove($name); Save-AxiomData $Ctx.VaultPath $data }
                Write-AxiomResult 'vault remove' @{ name=$name; dry_run=$Ctx.DryRun } $Ctx 'Secret entry removed'
            }
            default { throw 'Use vault set, get, list, remove, or exec.' }
        }
        return
    }
    if ($Verb -notin @('scan','check')) { throw 'Use guard scan or guard check.' }
    . (Join-Path $PSScriptRoot 'sandbox.ps1')
    $path=$Ctx.WorkspaceRoot; $index=[Array]::IndexOf($Params,'--path')
    if ($index -ge 0) {
        if ($index+1 -ge $Params.Count) { throw '--path requires a directory.' }
        $path=if ([IO.Path]::IsPathRooted($Params[$index+1])) { $Params[$index+1] } else { Join-Path $Ctx.WorkspaceRoot $Params[$index+1] }
        $path=Assert-AxiomPathWithin $Ctx.WorkspaceRoot $path -AllowRoot
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Scan directory does not exist.' }
    $patterns=@{ private_key='-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'; groq='gsk_[A-Za-z0-9]{30,}'; github='(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}'; nvidia='nvapi-[A-Za-z0-9_-]{30,}' }
    $findings=@(); $files=0
    $staged=$Params -contains '--staged'
    $stagedNames=@()
    if ($staged) {
        $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $result=Invoke-AxiomNative $git @('diff','--cached','--name-only','--diff-filter=ACMR','-z') $path
        if ($result.exit_code -ne 0) { throw 'Staged scanning requires a Git repository.' }
        $stagedNames=@($result.stdout -split "`0" | Where-Object { $_ })
    }
    if ($staged) {
        foreach ($relative in $stagedNames) {
            $result=Invoke-AxiomNative $git @('show',":$relative") $path
            if ($result.exit_code -ne 0) { throw 'Could not read staged file content.' }
            $files++; $line=0
            foreach ($text in ($result.stdout -split "`n")) {
                $line++; foreach ($rule in $patterns.Keys) { if ($text -match $patterns[$rule]) { $findings+=@{ file=$relative; line=$line; rule=$rule } } }
            }
        }
    }
    foreach ($file in $(if ($staged) { @() } else { Get-AxiomProjectFiles $path -Scan })) {
        if ($file.Length -gt 2MB -or $file.Extension -in @('.exe','.dll','.png','.jpg','.zip','.ico','.woff','.ttf')) { continue }
        $relative=[IO.Path]::GetRelativePath($path,$file.FullName).Replace('\','/')
        if ($staged -and $relative -notin $stagedNames) { continue }
        $files++; $line=0
        foreach ($text in [IO.File]::ReadLines($file.FullName)) {
            $line++
            foreach ($rule in $patterns.Keys) { if ($text -match $patterns[$rule]) { $findings+=@{ file=$relative; line=$line; rule=$rule } } }
        }
    }
    if ($Verb -eq 'check' -and (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        $git=(Get-Command git -CommandType Application | Select-Object -First 1).Source
        $tracked=Invoke-AxiomNative $git @('ls-files','.vault','.secrets','.env') $Ctx.WorkspaceRoot
        if ($tracked.exit_code -eq 0 -and $tracked.stdout.Trim()) { $findings+=@{ file='Git index'; line=0; rule='tracked_private_data' } }
    }
    if ($findings.Count) {
        if ($Ctx.Json) { Write-AxiomJson -Command "guard $Verb" -Status 'fail' -ExitCode 1 -Output @{ files_scanned=$files; findings=$findings } -Ctx $Ctx; exit 1 }
        $findings | ConvertTo-Json; throw 'Possible secrets found. Values are redacted; rotate exposed credentials.'
    }
    Write-AxiomResult "guard $Verb" @{ files_scanned=$files; findings=$findings; scope='Known token/private-key patterns; not a complete security audit.' } $Ctx 'No matching secrets found'
}
