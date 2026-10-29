<#
.SYNOPSIS
    Makes sure the OUs and security groups the onboarding scripts expect exist.

.DESCRIPTION
    Creates, if missing:
      - OU=Hotel with child OUs Reception, Housekeeping, Management, "Disabled Users"
      - Security groups GRP-Staff, GRP-Reception, GRP-Housekeeping, GRP-Management

    Safe to rerun: anything that already exists is left alone. Run once in your
    lab domain before New-HotelEmployee.ps1. Only run this in a lab.

.EXAMPLE
    .\Setup-HotelOUs.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domainDN = (Get-ADDomain).DistinguishedName
$hotelOU  = "OU=Hotel,$domainDN"

function New-OUIfMissing {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Path -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($dn, 'Create OU')) {
            New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false
            Write-Host "Created OU $Name" -ForegroundColor Green
        }
    } else { Write-Host "OU $Name already exists" -ForegroundColor DarkGray }
}

New-OUIfMissing -Name 'Hotel' -Path $domainDN
foreach ($child in 'Reception', 'Housekeeping', 'Management', 'Disabled Users') {
    New-OUIfMissing -Name $child -Path $hotelOU
}

foreach ($g in 'GRP-Staff', 'GRP-Reception', 'GRP-Housekeeping', 'GRP-Management') {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($g, 'Create group')) {
            New-ADGroup -Name $g -SamAccountName $g -GroupScope Global -GroupCategory Security -Path $hotelOU
            Write-Host "Created group $g" -ForegroundColor Green
        }
    } else { Write-Host "Group $g already exists" -ForegroundColor DarkGray }
}

Write-Host "`nReady. Next: .\New-HotelEmployee.ps1 -InputCsv .\samples\new-hires.csv" -ForegroundColor Cyan
