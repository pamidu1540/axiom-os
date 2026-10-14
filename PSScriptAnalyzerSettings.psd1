@{
    # Severity levels to analyze
    Severity = @('Error', 'Warning')

    # Exclude rules that do not apply to an interactive CLI / pseudo-OS kernel
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                       # Interactive CLI formatting with colored output
        'PSUseApprovedVerbs',                          # Domain-specific commands (Compile-*, Axiom-*, Sandbox-*)
        'PSUseBOMForUnicodeEncodedFile',               # UTF-8 without BOM is Git & cross-platform standard
        'PSUseShouldProcessForStateChangingFunctions', # New-AxiomContext is an internal in-memory object builder
        'PSUseSingularNouns',                          # Process-Logs is an intentional CLI sub-command
        'PSReviewUnusedParameter'                      # Subsystem dispatchers share uniform parameter contracts
    )
}
