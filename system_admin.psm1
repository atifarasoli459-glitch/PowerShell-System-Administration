function Write-Log {
    param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Task
)

    if (-not (Test-Path "C:\myLogs")) {
        New-Item -Path "C:\myLogs" -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $DateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$DateTime - $Task" | Out-File -FilePath "C:\myLogs\system_admin.log" -Append -ErrorAction Stop
}﻿

function Test-RemoteLogging {
    Write-Log -Task "Remote logging test successful"
    Write-Output "Remote logging test successful"
}


function Install-NewDomain {
    param(
        [string]$DomainName = "ARmicksandmacks.local",
        [Parameter(Mandatory=$true)]
        [securestring]$DSRMPassword
    )

    Write-Log -Task "Starting domain promotion for $DomainName"

    Install-ADDSForest `
        -DomainName $DomainName `
        -InstallDNS `
        -SafeModeAdministratorPassword $DSRMPassword `
        -Force
}
function Add-OrganizationalUnits {
    param(
        [string]$CsvPath = "C:\Users\Administrator\Documents\ADUsers.csv"
    )

    Import-Module ActiveDirectory -ErrorAction Stop
    $DomainDN = (Get-ADDomain).DistinguishedName
    $Users = Import-Csv -Path $CsvPath -ErrorAction Stop

    foreach ($OU in ($Users.OU | Sort-Object -Unique)) {

        if ([string]::IsNullOrWhiteSpace($OU)) {
            throw "CSV contains an empty OU name."
        }

        $ExistingOU = Get-ADOrganizationalUnit `
            -Filter "Name -eq '$OU'" `
            -SearchBase $DomainDN `
            -SearchScope OneLevel

        if (-not $ExistingOU) {

            New-ADOrganizationalUnit `
                -Name $OU `
                -Path $DomainDN `
                -ErrorAction Stop

            Write-Log -Task "Created OU: $OU"
            Write-Output "Created OU: $OU"
        }
        else {
            Write-Output "OU already exists: $OU"
        }
    }
}


function Add-UsersFromCsv {
    param(
        [string]$CsvPath = "C:\Users\Administrator\Documents\ADUsers.csv",

        [Parameter(Mandatory=$true)]
        [securestring]$InitialPassword
    )

    Import-Module ActiveDirectory -ErrorAction Stop
    $DomainDN = (Get-ADDomain).DistinguishedName
    $Users = Import-Csv -Path $CsvPath -ErrorAction Stop

    foreach ($User in $Users) {

        $OUPath = "OU=$($User.OU),$DomainDN"

        $ExistingUser = Get-ADUser `
            -Filter "SamAccountName -eq '$($User.Username)'"

        if (-not $ExistingUser) {

            New-ADUser `
                -Name "$($User.FirstName) $($User.LastName)" `
                -GivenName $User.FirstName `
                -Surname $User.LastName `
                -SamAccountName $User.Username `
                -Path $OUPath `
                -AccountPassword $InitialPassword `
                -Enabled $true `
                -ChangePasswordAtLogon $true `
                -ErrorAction Stop

            Write-Log -Task "Created user: $($User.Username)"
            Write-Output "Created user: $($User.Username)"
        }
        else {
            Write-Output "User already exists: $($User.Username)"
        }
    }
}

function Join-ComputerToDomain {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ComputerName,

        [string]$DomainName = "ARmicksandmacks.local"
    )

    Write-Log -Task "Checking connectivity to $ComputerName"

    if (-not (Test-NetConnection -ComputerName $ComputerName -Port 5985 -InformationLevel Quiet)) {
        Write-Log -Task "Connection failed: $ComputerName"
        throw "Target computer is not contactable."
    }

    $LocalCred = Get-Credential -Message "Enter target computer administrator credentials"
    $DomainCred = Get-Credential -Message "Enter domain administrator credentials"

    try {
        $Computer = Invoke-Command -ComputerName $ComputerName `
    -Credential $LocalCred `
    -ScriptBlock {
        Get-CimInstance Win32_ComputerSystem
    } -ErrorAction Stop

        if ($Computer.PartOfDomain -and $Computer.Domain -eq $DomainName) {
            Write-Log -Task "$ComputerName is already joined to $DomainName"
            Write-Output "$ComputerName is already joined to $DomainName"
            return
        }

       Invoke-Command -ComputerName $ComputerName `
    -Credential $LocalCred `
    -ScriptBlock {
        param($Domain, $Credential)

        Add-Computer -DomainName $Domain `
            -Credential $Credential `
            -Force -Restart -ErrorAction Stop

    } -ArgumentList $DomainName, $DomainCred `
    -ErrorAction Stop 

        Write-Log -Task "Domain join successful: $ComputerName"
        Write-Output "Domain join successful: $ComputerName"
    }
    catch {
        Write-Log -Task "Domain join failed: $_"
        throw
    }
}

function Configure-DHCP {

    Write-Log -Task "Starting DHCP configuration"

    try {
        if (-not (Get-WindowsFeature DHCP).Installed) {
            Install-WindowsFeature DHCP -IncludeManagementTools -ErrorAction Stop
        }

        Import-Module DhcpServer -ErrorAction Stop

        Write-Output "Checking existing DHCP scopes"
        $Scopes = Get-DhcpServerv4Scope -ErrorAction Stop

        if ($Scopes) {
            $Scopes | Format-Table ScopeId, Name, State
        }
        else {
            Write-Output "No existing DHCP scopes found"
        }

        if ($Scopes.ScopeId -notcontains "10.1.1.0") {
            Add-DhcpServerv4Scope `
                -Name "ARmicksandmacks DHCP" `
                -StartRange 10.1.1.100 `
                -EndRange 10.1.1.200 `
                -SubnetMask 255.255.255.0 `
                -State InActive `
                -ErrorAction Stop

            Write-Log -Task "Created DHCP scope 10.1.1.0/24"
        }
        else {
            Write-Output "DHCP scope already exists"
        }

        $Authorized = Get-DhcpServerInDC -ErrorAction Stop

if ($Authorized.IPAddress -notcontains "192.168.20.3") {
    Add-DhcpServerInDC `
        -DnsName "server2.ARmicksandmacks.local" `
        -IPAddress 192.168.20.3 `
        -ErrorAction Stop
}

Set-DhcpServerv4Binding -InterfaceAlias "Ethernet0" `
    -BindingState $false -ErrorAction Stop

Set-DhcpServerv4Binding -InterfaceAlias "Ethernet1" `
    -BindingState $true -ErrorAction Stop

Set-DhcpServerv4Scope -ScopeId 10.1.1.0 `
    -State Active -ErrorAction Stop

Get-DhcpServerv4Scope

Write-Log -Task "DHCP scope configuration completed"
    }
    catch {
        Write-Log -Task "DHCP configuration failed: $_"
        throw
    }
}

function Get-TopTenErrors {
    param(
        [string]$IPAddress = "127.0.0.1"
    )

    Write-Log -Task "Retrieving system errors from $IPAddress"

    try {
        $Query = {
            Get-WinEvent -FilterHashtable @{
                LogName = 'System'
                Level = 2
            } -MaxEvents 10 -ErrorAction Stop |
            Select-Object TimeCreated, Id,
                LevelDisplayName, ProviderName, Message
        }

        if ($IPAddress -in @("127.0.0.1", "localhost", "192.168.20.3")) {
            $Errors = & $Query
        }
        else {
            Import-Module ActiveDirectory -ErrorAction Stop

            $ComputerName = Get-ADComputer -Filter * -Properties IPv4Address |
                Where-Object { $_.IPv4Address -eq $IPAddress } |
                Select-Object -First 1 -ExpandProperty DNSHostName

            if (-not $ComputerName) {
                throw "No domain computer found for IP $IPAddress"
            }

            $Errors = Invoke-Command `
                -ComputerName $ComputerName `
                -ScriptBlock $Query `
                -ErrorAction Stop
        }

        New-Item -Path "C:\myLogs" `
            -ItemType Directory -Force | Out-Null

        $Errors | Format-List |
            Out-File "C:\myLogs\toptenerrors.txt"

        $Errors | Format-Table TimeCreated, Id,
            LevelDisplayName, ProviderName -AutoSize

        Write-Output "Errors saved to C:\myLogs\toptenerrors.txt"

        Write-Log -Task "System error retrieval completed"
    }
    catch {
        Write-Log -Task "System error retrieval failed: $_"
        throw
    }
}

function Schedule-DiskCleanup {
    param(
        [string]$IPAddress = "localhost"
    )

    Write-Log -Task "Scheduling disk cleanup on $IPAddress"

    try {
        $CleanupTask = {
            $Action = New-ScheduledTaskAction `
                -Execute "cleanmgr.exe" `
                -Argument "/VERYLOWDISK"

            $Trigger = New-ScheduledTaskTrigger `
                -Daily -At 6am

            Register-ScheduledTask `
                -TaskName "DailyDiskCleanup" `
                -Action $Action `
                -Trigger $Trigger `
                -User "SYSTEM" `
                -RunLevel Highest `
                -Force -ErrorAction Stop | Out-Null

            Get-ScheduledTask -TaskName "DailyDiskCleanup"
        }

        if ($IPAddress -in @("localhost", "127.0.0.1", "192.168.20.3")) {
            & $CleanupTask
        }
        else {
            Import-Module ActiveDirectory -ErrorAction Stop

            $ComputerName = Get-ADComputer -Filter * -Properties IPv4Address |
                Where-Object { $_.IPv4Address -eq $IPAddress } |
                Select-Object -First 1 -ExpandProperty DNSHostName

            if (-not $ComputerName) {
                throw "No domain computer found for IP $IPAddress"
            }

            Invoke-Command `
                -ComputerName $ComputerName `
                -ScriptBlock $CleanupTask `
                -ErrorAction Stop
        }

        Write-Log -Task "Disk cleanup scheduled successfully on $IPAddress"
        Write-Output "Disk cleanup scheduled daily at 6 AM on $IPAddress"
    }
    catch {
        Write-Log -Task "Disk cleanup scheduling failed: $_"
        throw
    }
}

Export-ModuleMember -Function Write-Log, Test-RemoteLogging, Install-NewDomain, Add-OrganizationalUnits, Add-UsersFromCsv, Join-ComputerToDomain, Configure-DHCP, Get-TopTenErrors, Schedule-DiskCleanup
