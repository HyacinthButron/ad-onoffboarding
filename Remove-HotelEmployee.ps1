<#
.SYNOPSIS
    Offboards employees in Active Directory from a CSV of leavers.

.DESCRIPTION
    For each leaver, in this order:
      1. Records their current group memberships to the report (so access is
         documented before it's removed).
      2. Disables the account.
      3. Removes every group except Domain Users, so access is revoked but the
         account can still be found and audited.
      4. Sets a description recording who offboarded them and when.
      5. Moves the account to the Disabled Users OU.

    The account is kept (disabled), not deleted, so that mailbox data, file
    ownership and audit history survive. Deleting is a separate, later decision.

    Protected accounts (Administrator, krbtgt, and anything in the admin groups)
    are never touched. Supports -WhatIf. Safe to rerun: an already-disabled,
    already-moved account is reported as such.

.PARAMETER InputCsv
    CSV of leavers. Column: SamAccountName. Optional: LastDay.

.PARAMETER DisabledOU
    The OU disabled accounts are moved to. Default: "Disabled Users" under Hotel.

.PARAMETER OutputFolder
    Where reports are saved. Default: .\reports

.EXAMPLE
    .\Remove-HotelEmployee.ps1 -InputCsv .\samples\leavers.csv -WhatIf

.EXAMPLE
    .\Remove-HotelEmployee.ps1 -InputCsv .\samples\leavers.csv
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputCsv,

    [string]$DisabledOU,
    [string]$OutputFolder = '.\reports'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
if (-not $DisabledOU) { $DisabledOU = "OU=Disabled Users,OU=Hotel,$domainDN" }
$actor = "$env:USERDOMAIN\$env:USERNAME"
$today = Get-Date -Format 'yyyy-MM-dd'
$log   = [System.Collections.Generic.List[object]]::new()

# Never offboard these, even if they're listed by mistake
$ProtectedSams   = @('Administrator', 'krbtgt', 'Guest')
$ProtectedGroups = @('Domain Admins', 'Enterprise Admins', 'Administrators', 'Schema Admins')

function Write-Log {
    param([string]$Sam, [string]$Action, [string]$Status, [string]$Detail)
    $color = switch ($Status) { 'Done' { 'Green' } 'Skipped' { 'Yellow' } 'Failed' { 'Red' } 'Info' { 'Gray' } default { 'Gray' } }
    Write-Host ("  {0,-8} {1,-16} {2}" -f $Status, $Sam, $Detail) -ForegroundColor $color
    $log.Add([pscustomobject]@{
        Time = (Get-Date -Format 'HH:mm:ss'); Sam = $Sam; Action = $Action; Status = $Status; Detail = $Detail
    })
}

Write-Host "`nOffboarding from $InputCsv" -ForegroundColor Cyan

foreach ($row in (Import-Csv -Path $InputCsv)) {
    $sam = $row.SamAccountName
    if ([string]::IsNullOrWhiteSpace($sam)) { continue }

    if ($ProtectedSams -contains $sam) {
        Write-Log -Sam $sam -Action 'Offboard' -Status 'Skipped' -Detail 'Protected account, refused'
        continue
    }

    $user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties MemberOf, Enabled -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log -Sam $sam -Action 'Offboard' -Status 'Skipped' -Detail 'No such account'
        continue
    }

    # Refuse anyone with admin rights, as a safety net
    $groupNames = @($user.MemberOf | ForEach-Object { (($_ -split ',')[0] -replace '^CN=', '') })
    if ($groupNames | Where-Object { $ProtectedGroups -contains $_ }) {
        Write-Log -Sam $sam -Action 'Offboard' -Status 'Skipped' -Detail 'Account has admin rights, offboard manually'
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($sam, "Offboard (disable, strip groups, move)")) { continue }

    # 1. Record access before removing it
    Write-Log -Sam $sam -Action 'RecordAccess' -Status 'Info' -Detail ("Groups before: " + (($groupNames) -join ', '))

    try {
        # 2. Disable
        if ($user.Enabled) {
            Disable-ADAccount -Identity $sam
            Write-Log -Sam $sam -Action 'Disable' -Status 'Done' -Detail 'Account disabled'
        } else {
            Write-Log -Sam $sam -Action 'Disable' -Status 'Skipped' -Detail 'Already disabled'
        }

        # 3. Remove from every group except the primary (Domain Users)
        foreach ($g in $groupNames) {
            if ($g -eq 'Domain Users') { continue }
            Remove-ADGroupMember -Identity $g -Members $sam -Confirm:$false
            Write-Log -Sam $sam -Action 'RemoveGroup' -Status 'Done' -Detail "Removed from $g"
        }

        # 4. Mark it
        Set-ADUser -Identity $sam -Description "Offboarded $today by $actor"

        # 5. Move to the Disabled Users OU
        if ($user.DistinguishedName -notmatch [regex]::Escape($DisabledOU)) {
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU
            Write-Log -Sam $sam -Action 'Move' -Status 'Done' -Detail "Moved to Disabled Users"
        } else {
            Write-Log -Sam $sam -Action 'Move' -Status 'Skipped' -Detail 'Already in Disabled Users'
        }
    }
    catch {
        Write-Log -Sam $sam -Action 'Offboard' -Status 'Failed' -Detail $_.Exception.Message
    }
}

# --- Reports ----------------------------------------------------------------
if ($log.Count -gt 0 -and -not $WhatIfPreference) {
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
    $stamp    = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $csvPath  = Join-Path $OutputFolder "Offboarding_$stamp.csv"
    $htmlPath = Join-Path $OutputFolder "Offboarding_$stamp.html"
    $log | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $done    = ($log | Where-Object Status -eq 'Done').Count
    $skipped = ($log | Where-Object Status -eq 'Skipped').Count
    $failed  = ($log | Where-Object Status -eq 'Failed').Count
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $rowsHtml = ($log | ForEach-Object {
        "<tr><td>$(&$enc $_.Time)</td><td>$(&$enc $_.Sam)</td><td>$(&$enc $_.Action)</td><td class='s-$($_.Status.ToLower())'>$(&$enc $_.Status)</td><td>$(&$enc $_.Detail)</td></tr>"
    }) -join "`n"
    @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Offboarding $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#1a1a1a}h1{font-size:1.5rem}
table{border-collapse:collapse;width:100%;font-size:.9rem}th,td{border-bottom:1px solid #ddd;padding:.5rem;text-align:left}
th{color:#555;font-weight:600}.s-done{color:#1a7f37;font-weight:600}.s-skipped{color:#9a6700}.s-failed{color:#cf222e;font-weight:600}.s-info{color:#555}
.sum{margin:1rem 0;color:#444}</style></head><body>
<h1>Offboarding report</h1>
<p class="sum">Generated $today $(Get-Date -Format 'HH:mm') by $(&$enc $actor) &middot; Source: $(&$enc (Split-Path $InputCsv -Leaf))</p>
<p class="sum"><b>$done</b> actions done &middot; <b>$skipped</b> skipped &middot; <b>$failed</b> failed. Accounts are disabled and kept for audit, not deleted.</p>
<table><tr><th>Time</th><th>Account</th><th>Action</th><th>Status</th><th>Detail</th></tr>
$rowsHtml
</table></body></html>
"@ | Out-File -FilePath $htmlPath -Encoding UTF8

    Write-Host "`nReports saved:" -ForegroundColor Cyan
    Write-Host "  $csvPath"
    Write-Host "  $htmlPath"
}
elseif ($WhatIfPreference) {
    Write-Host "`n-WhatIf: nothing was changed and no report was written." -ForegroundColor Yellow
}
