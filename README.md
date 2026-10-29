# AD Onboarding & Offboarding Automation

Two PowerShell scripts that do the most common first-line IT task in any
Windows/Active Directory shop: **create accounts for new employees, and shut
them down cleanly when people leave** — the same way every time, from a CSV,
with a report of exactly what was done.

**Read the full lab report: [LAB-REPORT.md](LAB-REPORT.md)**

## Why this matters

New hires and leavers are handled by IT support every week. Done by hand it's
slow and easy to get wrong: a typo in a username, the wrong group, or — the
real risk — a leaver whose account is never disabled and whose access lingers
for months. These two scripts make both jobs repeatable and leave an audit
trail.

## What they do

**`New-HotelEmployee.ps1`** — reads a CSV of new hires and for each one:

- builds a unique `first.last` username (adds a number if it's taken)
- creates the account in the right **department OU**
- adds it to the department's **security groups**
- sets **"must change password at next logon"**
- stamps a description with **who created it and when**
- writes a **CSV and HTML report**

**`Remove-HotelEmployee.ps1`** — reads a CSV of leavers and for each one:

- **records their group memberships to the report first**, so access is documented before it's removed
- **disables** the account (keeps it, doesn't delete it, so mail and audit history survive)
- **removes every group** except Domain Users
- stamps a description with who offboarded them and when
- **moves** the account to the Disabled Users OU
- **refuses** to touch admin and built-in accounts

Both support **`-WhatIf`** (show what would happen, change nothing) and skip
anything already done, so they're safe to rerun.

## Example report

![Onboarding report](screenshots/06-onboard-report.png)

Full walkthrough with screenshots, including a bug found and fixed against live
Active Directory: **[LAB-REPORT.md](LAB-REPORT.md)**.

## Quick start

In PowerShell as a domain admin, on a DC or a machine with RSAT:

```powershell
cd C:\Tools\ADOnboarding
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Get-ChildItem -Recurse | Unblock-File

# one-time: make sure the OUs and groups exist (lab only)
.\Setup-HotelOUs.ps1

# preview, then run
.\New-HotelEmployee.ps1 -InputCsv .\samples\new-hires.csv -WhatIf
.\New-HotelEmployee.ps1 -InputCsv .\samples\new-hires.csv

# offboarding (asks for confirmation; add -Confirm:$false to run unattended)
.\Remove-HotelEmployee.ps1 -InputCsv .\samples\leavers.csv -WhatIf
.\Remove-HotelEmployee.ps1 -InputCsv .\samples\leavers.csv
```

### Input files

`new-hires.csv`:
```csv
FirstName,LastName,Department,Title,Manager
Astrid,Lund,Reception,Front Desk Agent,
Johan,Ek,Housekeeping,Room Attendant,
```

`leavers.csv`:
```csv
SamAccountName,LastDay
johan.ek,2026-10-31
```

Departments map to OUs and groups in the `$DepartmentMap` at the top of
`New-HotelEmployee.ps1`. Add a department there and everything else follows.

## Files

| File | Purpose |
|---|---|
| `New-HotelEmployee.ps1` | Onboarding |
| `Remove-HotelEmployee.ps1` | Offboarding |
| `Setup-HotelOUs.ps1` | Creates the OUs and groups the scripts expect (lab) |
| `samples/` | Example new-hire and leaver CSVs |
| `LAB-REPORT.md` | Step-by-step lab write-up with screenshots |

## Design choices

- **Disable, don't delete.** A deleted account loses mailbox data, file
  ownership and audit history. Disabling revokes access immediately and keeps
  the evidence. Deleting later is a separate, deliberate decision.
- **Record access before removing it.** The offboarding report lists each
  leaver's groups before stripping them, so there's a record of what they
  could reach.
- **Refuse admin accounts.** The offboarding script never touches
  Administrator, krbtgt, or anyone in Domain Admins / Enterprise Admins, even
  if they're in the CSV by mistake.
- **`-WhatIf` everywhere**, so you always preview before changing a directory.

## Limitations

- Lab/portfolio project, tested against mocked AD cmdlets and in a lab domain.
- The initial password is one shared value typed at the prompt. In production
  you'd generate a unique password per user and deliver it over a secure
  channel.
- Doesn't create mailboxes, home folders or licences — those are the natural
  next step (Exchange / Entra ID).
- Requires the `ActiveDirectory` PowerShell module (RSAT).

## Skills shown

PowerShell (functions, `-WhatIf`/`ShouldProcess`, error handling) ·
Active Directory (users, OUs, security groups) · identity lifecycle
(joiner/leaver) · CSV-driven automation · audit logging and reporting ·
safe-by-default scripting
