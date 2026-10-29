<#
.SYNOPSIS
    Creates Active Directory accounts for new employees from a CSV file.

.DESCRIPTION
    Reads a CSV of new hires and, for each one, creates a standardised AD account:
      - a unique SamAccountName (first.last, with a number if that's taken)
      - the account in the right department OU
      - membership in the department's security group(s)
      - "must change password at next logon" set
      - a description recording who created it and when

    Every action is written to the screen and to a timestamped CSV and HTML report,
    so there's a record of exactly what was done. Nothing is created twice: if an
    account already exists it's skipped, so the script is safe to rerun.

    Supports -WhatIf, so you can see what it would do without changing anything.

    This is a lab/portfolio script. In production, the initial password would be
    delivered to each user through a secure channel (not shown on screen).

.PARAMETER InputCsv
    Path to the new-hire CSV. Columns: FirstName, LastName, Department, Title.
    Optional column: Manager (SamAccountName of their manager).

.PARAMETER OutputFolder
    Where the reports are saved. Default: .\reports

.EXAMPLE
    .\New-HotelEmployee.ps1 -InputCsv .\samples\new-hires.csv -WhatIf
    Shows what would happen, changes nothing.

.EXAMPLE
    .\New-HotelEmployee.ps1 -InputCsv .\samples\new-hires.csv
    Creates the accounts and writes a report.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputCsv,

    [string]$OutputFolder = '.\reports'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

# --- Map each department to its OU and security groups ----------------------
# Add a department here and the script handles it everywhere else.
$DepartmentMap = @{
    'Reception'   = @{ OU = 'Reception';   Groups = @('GRP-Reception', 'GRP-Staff') }
    'Housekeeping' = @{ OU = 'Housekeeping'; Groups = @('GRP-Housekeeping', 'GRP-Staff') }
    'Management'  = @{ OU = 'Management';   Groups = @('GRP-Management', 'GRP-Staff') }
}
$StaffParentOU = 'Hotel'   # OU that holds the department OUs

# --- One shared initial password for the lab, typed once, hidden ------------
# Production note: generate a unique password per user and deliver it securely.
$initialPassword = Read-Host -AsSecureString 'Initial password for the new accounts (they must change it at first logon)'

$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$actor    = "$env:USERDOMAIN\$env:USERNAME"
$today    = Get-Date -Format 'yyyy-MM-dd'
$log      = [System.Collections.Generic.List[object]]::new()

function Write-Log {
    param([string]$Sam, [string]$Action, [string]$Status, [string]$Detail)
    $color = switch ($Status) { 'Created' { 'Green' } 'Skipped' { 'Yellow' } 'Failed' { 'Red' } default { 'Gray' } }
    Write-Host ("  {0,-8} {1,-16} {2}" -f $Status, $Sam, $Detail) -ForegroundColor $color
    $log.Add([pscustomobject]@{
        Time = (Get-Date -Format 'HH:mm:ss'); Sam = $Sam; Action = $Action; Status = $Status; Detail = $Detail
    })
}

function Get-UniqueIdentity {
    # Returns a username AND a display name that are both free. Active Directory
    # won't allow two objects with the same Name (CN) in one OU, so when two
    # people share a name we bump both together: astrid.lund / "Astrid Lund",
    # then astrid.lund2 / "Astrid Lund 2".
    param([string]$First, [string]$Last, [string]$OU)
    $base = ("{0}.{1}" -f $First, $Last).ToLower() -replace '[^a-z0-9.]', ''
    $display = "$First $Last"
    $sam = $base
    $name = $display
    $i = 1
    while ((Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) -or
           (Get-ADObject -Filter "Name -eq '$name'" -SearchBase $OU -ErrorAction SilentlyContinue)) {
        $i++
        $sam  = "$base$i"
        $name = "$display $i"
    }
    [pscustomobject]@{ Sam = $sam; Name = $name; Display = $display }
}

Write-Host "`nOnboarding from $InputCsv" -ForegroundColor Cyan

$rows = Import-Csv -Path $InputCsv
foreach ($row in $rows) {
    $dept = $row.Department
    if (-not $DepartmentMap.ContainsKey($dept)) {
        Write-Log -Sam '-' -Action 'Create' -Status 'Failed' -Detail "Unknown department '$dept' for $($row.FirstName) $($row.LastName)"
        continue
    }

    $map     = $DepartmentMap[$dept]
    $targetOU = "OU=$($map.OU),OU=$StaffParentOU,$domainDN"
    $id      = Get-UniqueIdentity -First $row.FirstName -Last $row.LastName -OU $targetOU
    $sam     = $id.Sam
    $upn     = "$sam@$($domain.DNSRoot)"
    $display = $id.Display

    if (-not $PSCmdlet.ShouldProcess($display, "Create account $sam in $dept")) { continue }

    try {
        New-ADUser -Name $id.Name -GivenName $row.FirstName -Surname $row.LastName `
            -SamAccountName $sam -UserPrincipalName $upn -DisplayName $display `
            -Title $row.Title -Department $dept -Company 'Grand Hotel' `
            -Path $targetOU -AccountPassword $initialPassword -Enabled $true `
            -ChangePasswordAtLogon $true `
            -Description "Onboarded $today by $actor"
        if ($row.PSObject.Properties.Name -contains 'Manager' -and $row.Manager) {
            Set-ADUser -Identity $sam -Manager $row.Manager -ErrorAction SilentlyContinue
        }
        Write-Log -Sam $sam -Action 'Create' -Status 'Created' -Detail "$display, $($row.Title), OU=$dept"

        foreach ($g in $map.Groups) {
            Add-ADGroupMember -Identity $g -Members $sam
            Write-Log -Sam $sam -Action 'AddGroup' -Status 'Created' -Detail "Added to $g"
        }
    }
    catch {
        if ($_.Exception.Message -match 'already exists') {
            Write-Log -Sam $sam -Action 'Create' -Status 'Skipped' -Detail 'Account already exists'
        }
        else {
            Write-Log -Sam $sam -Action 'Create' -Status 'Failed' -Detail $_.Exception.Message
        }
    }
}

# --- Reports ----------------------------------------------------------------
if ($log.Count -gt 0 -and -not $WhatIfPreference) {
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
    $stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $csvPath = Join-Path $OutputFolder "Onboarding_$stamp.csv"
    $htmlPath = Join-Path $OutputFolder "Onboarding_$stamp.html"
    $log | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $created = ($log | Where-Object Action -eq 'Create' | Where-Object Status -eq 'Created').Count
    $skipped = ($log | Where-Object Status -eq 'Skipped').Count
    $failed  = ($log | Where-Object Status -eq 'Failed').Count
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $rowsHtml = ($log | ForEach-Object {
        "<tr><td>$(&$enc $_.Time)</td><td>$(&$enc $_.Sam)</td><td>$(&$enc $_.Action)</td><td class='s-$($_.Status.ToLower())'>$(&$enc $_.Status)</td><td>$(&$enc $_.Detail)</td></tr>"
    }) -join "`n"
    @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Onboarding $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#1a1a1a}h1{font-size:1.5rem}
table{border-collapse:collapse;width:100%;font-size:.9rem}th,td{border-bottom:1px solid #ddd;padding:.5rem;text-align:left}
th{color:#555;font-weight:600}.s-created{color:#1a7f37;font-weight:600}.s-skipped{color:#9a6700}.s-failed{color:#cf222e;font-weight:600}
.sum{margin:1rem 0;color:#444}</style></head><body>
<h1>Onboarding report</h1>
<p class="sum">Generated $today $(Get-Date -Format 'HH:mm') by $(&$enc $actor) &middot; Source: $(&$enc (Split-Path $InputCsv -Leaf))</p>
<p class="sum"><b>$created</b> accounts created &middot; <b>$skipped</b> skipped &middot; <b>$failed</b> failed</p>
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
