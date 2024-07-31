# CnfForTheWin
CnfForTheWin repository contains PowerShell files allowing to create a conflicting object when a new machine account is legitimately created in Active Directory (AD). When this attempt works, and if the SecureChannel is fixed manually by an administrator, then an attacker can edit the RBCD attribute and get administrative access to this new machine.
It is associated to the blogpost: [Using conflicting objects in Active Directory to gain privileges](https://medium.com/tenable-techblog/using-conflicting-objects-in-active-directory-to-gain-privileges-243ef6a27928).

## Modules and script
### Invoke-CnfMachineCreation.ps1
Main script which requires:
- [Active Directory PowerShell module](https://learn.microsoft.com/en-us/powershell/module/activedirectory/): used to retrieve data.
- [✅] [Powermad PowerShell module](https://github.com/Kevin-Robertson/Powermad): required here to abuse the `ms-DS-MachineAccountQuota` and create a fake machine account.
- [✅] `Invoke-CnfMachineCreation.psm1`: contains several functions inspired by [UncoverDCShadow](https://github.com/tenable/UncoverDCShadow) to listen to LDAP events, in order to react very quickly after the creation of the computer object. Thanks to this speed, the same machine account can be created on another DC, which leads to the conflict.

## How to use
The privileges of a standard account are "high" enough to subscribe to LDAP notifications.

Examples:
- `./Invoke-CnfMachineCreation.ps1 -Username 'user1' -Password 'SuperPa$$w0rd'`
  - Subscribe to the PDC emulator domain controller for LDAP notifications with the provided credentials.
  - When a new computer account is added, it will try to add its fake duplicate account on another domain controller.
  - The script will be active for 2 minutes (default value).
- `./Invoke-CnfMachineCreation.ps1 -Username 'user1' -Password 'SuperPa$$w0rd' -SourceDomainController 192.168.1.1`
  - Subscribe to the 192.168.1.1 domain controller using the provided credentials.
  - When a new computer account is added, it will try to add its fake duplicate account on another domain controller.
  - The script will be active for 2 minutes (default value).
- `./Invoke-CnfMachineCreation.ps1 -Username 'user1' -Password 'SuperPa$$w0rd' -SourceDomainController 192.168.1.1 -TargetDomainController 192.168.1.2 -DurationMinutes 30`
  - Subscribe to the 192.168.1.1 domain controller using the provided credentials.
  - When a new computer account is added, it will try to add its fake duplicate account on the 192.168.1.2 domain controller.
  - The script will be active for 30 minutes.

## Flow
1. Subscribe to a domain controller for LDAP notifications.
1. Detect when a new machine account is created in the domain.
1. Try to create very quickly the same machine account by targeting a different domain controller.
1. Check if the *distinguishedName* of the fake machine account looks like an authentic one (i.e.; the `\0ACNF:<objectGuid attribute value>` suffix was not added).
1. Wait for the new machine reboot (asked by the system when joining the domain) for 15 minutes, and then check if the *sAMAccountName* looks like an authentic one (i.e.; has not been replaced by `$DUPLICATE-<object's RID in hexadecimal>`).

If all these steps were successful, the new machine will have authentication issues (broken secure channel).
If an administrator fixes it, then the machine will be vulnerable to the Resource-Based Constrained Delegation (RBCD) attack.

## Author
Antoine Cauchois for [Tenable Research](https://www.tenable.com/research).

# Disclaimer and license
This work is provided as-is. Tenable forbids using it outside of security research.

Licensed under the [GNU GPLv3](/LICENSE).

Reuse code from the following repositories (thanks for their previous research and work!):
 - [Powermad](https://github.com/Kevin-Robertson/Powermad), [BSD 3-Clause License](https://github.com/Kevin-Robertson/Powermad/blob/master/LICENSE).
 - [UncoverDCShadow](https://github.com/tenable/UncoverDCShadow), [AGPLv3 license](https://github.com/tenable/UncoverDCShadow/blob/master/LICENSE.md).