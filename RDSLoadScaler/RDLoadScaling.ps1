﻿<#
.SYNOPSIS
This is a script for automatically scaling Remote Desktop Services (RDS) in Micrsoft Azure

.Description
This script will automatically start/stop remote desktop (RD) session host VMs based on the number of user sessions and utilization boundaries in the configuration file.
You can schedule the script to run at a certain time interval on the RD Connection Broker server in your RDS deployment in Azure.
#>
<#
.SYNOPSIS
Function for writing the log
#>
Function Write-Log
{
    Param(
        [int]$level
    ,   [string]$Message
    ,   [ValidateSet("Info", "Warning", "Error")][string]$severity = 'Info'
    ,   [string]$logname = $rdslog
    ,   [string]$color = "white"
    )
    $time = get-date
    Add-Content $logname -value ("{0} - [{1}] {2}" -f $time, $severity, $Message)
    if ($interactive) {
        switch ($severity)
        {
            'Error' {$color = 'Red'}
            'Warning' {$color = 'Yellow'}
        }
        if ($level -le $VerboseLogging)
        {
            if ($color -match "Red|Yellow")
            {
                Write-Host ("{0} - [{1}] {2}" -f $time, $severity, $Message) -ForegroundColor $color -BackgroundColor Black
                if ($severity -eq 'Error') { 
                    
                    throw $Message 
                }
            }
            else 
            {
                Write-Host ("{0} - [{1}] {2}" -f $time, $severity, $Message) -ForegroundColor $color
            }
        }
    }
    else
    {
        switch ($severity)
        {
            'Info' {Write-Verbose -Message $Message}
            'Warning' {Write-Warning -Message $Message}
            'Error' {
                throw $Message
            }
        }
    }
} 

<# 
.SYNOPSIS
Function for writing the usage log
#>
Function Write-UsageLog
{
    Param(
        [string]$collectionName,
        [int]$corecount,
        [int]$vmcount,
        [int]$sessions,
        [int]$seats,
        [string]$utilization,
        [string]$logfilename=$rdsusagelog
    )
    $time=get-date
    Add-Content $logfilename -value ("{0}, {1}, {2}, {3}, {4}, {5}, {6}" -f $time, $collectionName, $corecount, $vmcount, $sessions, $seats, $utilization)
}

<#
.SYNOPSIS
Function for creating variable from XML
#>
Function Set-ScriptVariable ($Name,$Value) 
{
    Invoke-Expression ("`$Script:" + $Name + " = `"" + $Value + "`"")
}
<#
Variables
#>
#Current Path
$CurrentPath=Split-Path $script:MyInvocation.MyCommand.Path

#XMl Configuration File Path
$XMLPath = "$CurrentPath\Config.xml"

#Log path
$rdslog="$CurrentPath\RDSScale.log"

#usage log path
$rdsusagelog="$CurrentPath\RDSUsage.log"

###### Verify XML file ######
If (Test-Path $XMLPath) 
{
    write-verbose "Found $XMLPath"
    write-verbose "Validating file..."
    try 
    {
        $Variable = [XML] (Get-Content $XMLPath)
    } 
    catch 
    {
        $Validate = $false
        Write-Error "$XMLPath is invalid. Check XML syntax - Unable to proceed"
        Write-Log 3 "$XMLPath is invalid. Check XML syntax - Unable to proceed" "Error"
        exit 1
    }
} 
Else 
{
    $Validate = $false
    write-error "Missing $XMLPath - Unable to proceed"
    Write-Log 3 "Missing $XMLPath - Unable to proceed" "Error"
    exit 1
}

##### Load XML Configuration values as variables #########
Write-Verbose "loading values from Config.xml"
$Variable=[XML] (Get-Content "$XMLPath")
$Variable.RDSScale.Azure | ForEach-Object {$_.Variable} | Where-Object {$_.Name -ne $null} | ForEach-Object {Set-ScriptVariable -Name $_.Name -Value $_.Value}
$Variable.RDSScale.RDSScaleSettings | ForEach-Object {$_.Variable} | Where-Object {$_.Name -ne $null} | ForEach-Object {Set-ScriptVariable -Name $_.Name -Value $_.Value}
$CapacityTop = "{0:P}" -f([double]$MaxCapacity)
$CapacityFloor = "{0:P}" -f([double]$MinCapacity)
if($OnAzure -eq 1){$AzureHosted = $true}else{$AzureHosted = $false}

#Load RDS ps Module
Import-Module RemoteDesktop

if([string]::IsNullOrEmpty($ConnectionBrokerFQDN)){
    Try 
    { 
        $ConnectionBrokerFQDN = (Get-RDConnectionBrokerHighAvailability -ErrorAction Stop).ActiveManagementServer
    }
    Catch
    {
        Write-Host "RD Active Management Server unreachable. Setting to the local host."
        Set-RDActiveManagementServer –ManagementServer "$env:computername.$env:userdnsdomain"
        $ConnectionBrokerFQDN = (Get-RDConnectionBrokerHighAvailability).ActiveManagementServer
    }

    If (!$ConnectionBrokerFQDN) 
    { # If null then this must not be a HA RDCB configuration, so assume RDCB is the local host.
        $ConnectionBrokerFQDN = "$env:computername.$env:userdnsdomain"
    }

    Write-Host "RD Active Management server:" $ConnectionBrokerFQDN

    If ("$env:computername.$env:userdnsdomain" -ne $ConnectionBrokerFQDN) 
    {
        Write-Host "RD Active Management Server is not the local host. Exiting."
        Write-Log 1 "RD Active Management Server is not the local host. Exiting." "Info"

        exit 0
    }
}

if($AzureHosted)
{
    #Load Azure ps module
    Import-Module -Name AzureRM

    #To use certificate based authentication for service principal, please uncomment the following line
    #Add-AzureRmAccount -ServicePrincipal -CertificateThumbprint $AADAppCertThumbprint -ApplicationId $AADApplicationId -TenantId $AADTenantId

    #The the following three lines is to use password/secret based authentication for service principal, to use certificate based authentication, please comment those lines, and uncomment the above line
    #$secpasswd = ConvertTo-SecureString $AADServicePrincipalSecret -AsPlainText -Force
    #$appcreds = New-Object System.Management.Automation.PSCredential ($AADApplicationId, $secpasswd)

    #Add-AzureRmAccount -ServicePrincipal -Credential $appcreds -TenantId $AADTenantId

    #To use Azure VM Managed Service Identity please uncommend the following line. Please ensure you have setup the proper permissions before enabling this functionality.
    try
    {
        Add-AzureRmAccount -identity
    }
    catch
    {
        Write-Host "Azure VM MSI token error, please check your azure vm setup."
    }

    #select the current Azure Subscription specified in the config if not using Azure VM MSI auth option.
    Select-AzureRmSubscription -SubscriptionName $CurrentAzureSubscriptionName
}

Function Drain-RDSHServer{
    Param(
        [string]$collectionName,
        [string]$connectionBroker,
        [string]$serverName
    )
    Write-Log 1 "Counting the current sessions on the host..." "Info"
    $existingSession=0
    $ts = [timespan]::fromseconds($LimitSecondsToForceLogOffUser)
    $alertTime = "$($ts.minutes) Minutes"
    Set-RDSessionHost -ConnectionBroker $connectionBroker -SessionHost $serverName -NewConnectionAllowed NotUntilReboot
    $Users = Get-RDUserSession -ConnectionBroker $connectionBroker -CollectionName @($collectionName)|Where-Object {$_.ServerName -eq $serverName}
    foreach($user in $Users){
        if($user.SessionState -eq "STATE_DISCONNECTED")
        {
            #logoff Disconnected Sessions
            try
            {
                Invoke-RDUserLogoff -HostServer $user.HostServer -UnifiedSessionID $user.UnifiedSessionId -Force -ErrorAction Stop
                Write-Host "Logoff Disconnected User"
            }
            catch
            {
                write-log 1 "Failed to log off user with error: $($_.exception.message)" "Error"
                Exit 1
            }
            continue
        }
        if($LimitSecondsToForceLogOffUser -ne 0){
            #send notification
            try
            {
                Send-RDUserMessage -HostServer $user.HostServer -UnifiedSessionID $user.UnifiedSessionId -MessageTitle $LogOffMessageTitle -MessageBody "($LogOffMessageBody) You will logged off in $($alertTime)." -ErrorAction Stop
                Write-Host "Message User"
            }
            catch
            {
                Write-log 1 "Failed to send message to user with error: $($_.exception.message)" "Error"
                Exit 1
            }
        }
        $existingSession=$existingSession+1
    }
    #wait for n seconds to log off user
    Start-Sleep -Seconds $LimitSecondsToForceLogOffUser
    if($LimitSecondsToForceLogOffUser -ne 0)
    {
        #force users to log off
        Write-Log 1 "Force users to log off..." "Info"
        try
        {
           $Users = Get-RDUserSession -ConnectionBroker $connectionBroker -CollectionName @($collectionName)|Where-Object {$_.ServerName -eq $serverName} 
        }
        catch
        {
            write-log 1 "Failed to retrieve list of user sessions in collection: $($collectionName) with error: $($_.exception.message)" "Error"
            exit 1
        }
        foreach($user in $Users)
        {
            #log off user
            try
            {
                Invoke-RDUserLogoff -HostServer $user.HostServer -UnifiedSessionID $user.UnifiedSessionId -Force -ErrorAction Stop
                $existingSession=$existingSession-1
                Write-Host "Logoff User"
            }
            catch
            {
                write-log 1 "Failed to log off user with error: $($_.exception.message)" "Error"
                exit 1
            }

        }
    }
    #check the session count before shutting down the VM
    if($existingSession -eq 0 -and $AzureHosted)
    {
        #Get Azure Virtual Machine
        try
        {
            $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName | Where-Object {$_.Tags.Values -like "*RDSH*" -and $serverName.ToLower().Contains($_.Name.ToLower()+".") -eq $true} -ErrorAction Stop
        }
        catch
        {
            Write-Log 1 "Failed to retrieve VM information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
            Exit 1
        }
        
        #shutdown the Azure VM
        try
        {
            Write-Log 1 "Stopping Azure VM: $($vm.Name) and waiting for it to shutdown..." "Info"
            Stop-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm.Name -Force -ErrorAction Stop
        }
        catch
        {
            Write-Log 1 "Failed to stop Azure VM: $($vm.Name) with error: $($_.exception.message)" "Error"
        }
    }
}

Function ScaleOut-RDSHServer{
    Param(
        [string]$collectionName,
        [string]$connectionBroker,
        [string]$serverName
    )
    Write-Log 1 "Scaling out session host farm" "Info"
    If($AzureHosted)
    {
        $IsVmRunning = $false
        #Get Azure Virtual Machine
        try
        {
            $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Status| Where-Object {$_.Tags.Values -like "*RDSH*" -and $serverName.ToLower().Contains($_.Name.ToLower()+".") -eq $true} -ErrorAction Stop
        }
        catch
        {
            Write-Log 1 "ScaleOut-VM Action: Failed to retrieve VM information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
            Exit 1
        }
        if($vm.PowerState.Contains("running"))
        {
            $IsVmRunning = $true
        }
        if($IsVmRunning)
        {
            Set-RDSessionHost -ConnectionBroker $connectionBroker -SessionHost $serverName -NewConnectionAllowed Yes
        }
        else
        {
            #start the azure VM
            try
            {
                Write-Log 1 "Starting Azure VM: $($vm.Name) and waiting for it to start up ..." "Info"
                Start-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm.Name -ErrorAction Stop
            }
            catch
            {
                Write-Log 1 "Failed to start Azure VM: $($vm.Name) with error: $($_.exception.message)" "Error"
                Exit 1
            }
            #wait for the VM to start
            $IsVMStarted=$false
            while(!$IsVMStarted)
            {
                $VMDetails = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm.Name -Status -ErrorAction Stop
                if($VMDetails.PowerState.Contains("running"))
                {
                    $IsVMStarted = $true
                }
                #wait for 15 seconds
                Start-Sleep -Seconds 15
            }
            #wait for server to be fully started before allowing users on the system.
            Start-Sleep -Seconds 120
            Set-RDSessionHost -ConnectionBroker $connectionBroker -SessionHost $serverName -NewConnectionAllowed Yes
        }
    }
    else
    {
        Set-RDSessionHost -ConnectionBroker $connectionBroker -SessionHost $serverName -NewConnectionAllowed Yes
    }
}

Function Test-RDPoolSize{
    Param(
        [object[]] $pool,
        [ValidateSet("Up","Down")][string]$scale,
        [object[]] $member
    )
    $testPool = @()
    $testPool = $pool
    if($scale -eq "Up")
    {
        $rec = $testPool |Where-Object {$_.RDSH -eq $member.RDSH}
        $rec.Available = "Yes"
        $newCapacity = ($testPool|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property MaxCapacity -Sum).Sum
        $estimatedUserLoad = (($testPool|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property TotalUsers -Sum).Sum)
        $estimatedUtilization = "{0:P}" -f($estimatedUserLoad/$newCapacity)
        if($estimatedUtilization -gt $CapacityFloor)
        {
            Write-Host "Scale up fits with capacity limits"
            return $true
        }
        else
        {
            Write-Host "Scale up exceeds capacity minimums"
            return $false
        }

    }
    else
    {
        $rec = $testPool |Where-Object {$_.RDSH -eq $member.RDSH}
        $rec.Available = "No"
        $newCapacity = ($testPool|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property MaxCapacity -Sum).Sum
        $usersToMigrate = $member.TotalUsers - $member.DisconnectedUsers
        $estimatedUserLoad = (($testPool|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property TotalUsers -Sum).Sum)+$usersToMigrate
        $estimatedUtilization = "{0:P}" -f($estimatedUserLoad/$newCapacity)
        if($estimatedUtilization -lt $CapacityTop)
        {
            Write-Host "Scale down fits within capacity limits"
            return $true
        }
        else 
        {
            Write-Host "Scale down exceeds capacity limits"
            return $false
        }
    }
}

$CurrentDateTime=Get-Date
Write-Log 3 "Starting RDS Scale Optimization: Current Date Time is: $CurrentDateTime" "Info"

#get the available collections in the RDS
try
{
    $Collections=Get-RDSessionCollection -ConnectionBroker $ConnectionBrokerFQDN -ErrorAction Stop
}
catch
{
    Write-Log 1 "Failed to retrieve RDS collections: $($_.exception.message)" "Error"
    Exit 1
}

foreach($collection in $Collections)
{
    Write-Host ("Processing collection {0}" -f $collection.CollectionName)
    Write-Log 1 "Processing collection: $($collection.CollectionName)" "Info"
    #Get the Session Hosts in the collection
    try
    {
        $RDSessionHost=Get-RDSessionHost -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName
    }
    catch
    {
        Write-Log 1 "Failed to retrieve RDS session hosts in collection $($collection.CollectionName) : $($_.exception.message)" "Error"
        Exit 1
    }
    #Get the User Sessions in the collection
    try
    {
        $CollectionUserSessions=Get-RDUserSession -ConnectionBroker $ConnectionBrokerFQDN -CollectionName $collection.CollectionName -ErrorAction Stop
    }
    catch
    {
        Write-Log 1 "Failed to retrieve user sessions in collection:$($collection.CollectionName) with error: $($_.exception.message)" "Error"
        Exit 1
    }
    #Get the Session Hosts LB config in the collection
    try
    {
        $RDSessionHostConfig = Get-RDSessionCollectionConfiguration -CollectionName $collection.CollectionName -ConnectionBroker $ConnectionBrokerFQDN -LoadBalancing -ErrorAction Stop
    }
    catch
    {
        Write-Log 1 "Failed to retrieve RDS session hosts load balancing configuration in collection:$($collection.CollectionName) with error: $($_.exception.message)" "Error"
        Exit 1
    }
    #check the number of running session hosts
    $numberOfRunningHost=0
    #total of running cores
    $totalRunningCores=0
    $RDPoolStatus = @()
    foreach ($sessionHost in $RDSessionHost)
    {
        write-log 1 "Checking session host: $($sessionHost.SessionHost)" "Info"
        if($AzureHosted)
        {
            #AzureHosted
            #Get Azure Virtual Machines
            try
            {
                $VMs = Get-AzureRmVM -ResourceGroupName $ResourceGroupName | Where-Object {$_.Tags.Values -like "*RDSH*"} -ErrorAction Stop
            }
            catch
            {
                Write-Log 1 "Failed to retrieve VMs information for resource group: $ResourceGroupName from Azure with error: $($_.exception.message)" "Error"
                Exit 1
            }
            foreach($vm in $VMs)
            {
                if($sessionHost.SessionHost.ToLower().Contains($vm.Name.ToLower()+"."))
                {
                    #check the azure vm is running or not
                    $IsVmRunning = $false
                    $VMDetail = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm.Name -Status
                    foreach ($VMStatus in $VMDetail.Statuses)
                    {
                        if($VMStatus.Code.CompareTo("PowerState/running") -eq 0)
                        {
                            $IsVmRunning = $true
                            break
                        }
                    }
                    if($IsVmRunning -eq $true)
                    {
                        $coresAvailable=Get-AzureRmVMSize -ResourceGroupName $ResourceGroupName -VMName $vm.Name | where Name -eq $vm.HardwareProfile.VmSize
                        $numberOfRunningHost=$numberOfRunningHost+1
                        $totalRunningCores=$totalRunningCores+$coresAvailable.NumberOfCores
                    }
                    break # break out of the inner foreach loop once a match is found and checked
                }
            }
        }
        else
        {
            if($sessionHost.NewConnectionAllowed -eq "Yes")
            {
                $numberOfRunningHost=$numberOfRunningHost+1
            }
        }
        $RDFarmStatus = New-Object System.Object

        $MaxCapcity = ($RDSessionHostConfig|Where-Object {$_.SessionHost -eq $sessionHost.SessionHost}|Select-Object SessionLimit).SessionLimit
        $Priority = ($RDSessionHostConfig|Where-Object {$_.SessionHost -eq $sessionHost.SessionHost}|Select-Object RelativeWeight).RelativeWeight
        $SessionCount = ($CollectionUserSessions|Where-Object {$_.HostServer -eq $sessionHost.SessionHost}).Count
        $DCSessionCount = ($CollectionUserSessions|Where-Object {$_.HostServer -eq $sessionHost.SessionHost -and $_.SessionState -eq "STATE_DISCONNECTED"}).Count
        $Utilization = "{0:P}" -f($SessionCount/$MaxCapcity)

        $RDFarmStatus | Add-Member -NotePropertyName RDSH -NotePropertyValue $sessionHost.SessionHost
        $RDFarmStatus | Add-Member -NotePropertyName Available -NotePropertyValue $sessionHost.NewConnectionAllowed
        $RDFarmStatus | Add-Member -NotePropertyName Priority -NotePropertyValue $Priority
        $RDFarmStatus | Add-Member -NotePropertyName TotalUsers -NotePropertyValue $SessionCount
        $RDFarmStatus | Add-Member -NotePropertyName DisconnectedUsers -NotePropertyValue $DCSessionCount
        $RDFarmStatus | Add-Member -NotePropertyName MaxCapacity -NotePropertyValue $MaxCapcity
        $RDFarmStatus | Add-Member -NotePropertyName Utilization -NotePropertyValue $Utilization

        $RDPoolStatus += $RDFarmStatus
    }

    write-host "Current number of running hosts: " $numberOfRunningHost
    write-log 1 "Current number of running hosts: $numberOfRunningHost" "Info"
    $SessionCount = ($CollectionUserSessions|Measure-Object).Count
    $PoolCapacity = ($RDPoolStatus|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property MaxCapacity -Sum).Sum
    $PoolUtilization = "{0:P}" -f($($($RDPoolStatus|Measure-Object -Property TotalUsers -Sum).Sum)/$($($RDPoolStatus|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property MaxCapacity -Sum).Sum))
    if($numberOfRunningHost -lt $MinimumNumberOfRDSH)
    {
        #Shouldnt need this
        Write-Log 1 "Pool is below minimum requirements. Adding capacity immediately" "Warning"
        $SelectedServer =($RDPoolStatus |Where-Object {$_.Available -ne "Yes"}|sort -Property Priority -Descending|select -First 1)
        if($SelectedServer -ne $null)
        {
            Write-Log 1 "Scaling up pool host $($SelectedServer.RDSH)" "Info"
            ScaleOut-RDSHServer -collectionName $collection.CollectionName -connectionBroker $ConnectionBrokerFQDN -serverName $SelectedServer.RDSH
            $SelectedServer.Available = "Yes"
        }
        else
        {
            Write-Log 1 "ALERT: Insufficient standby capacity available! Please provision more session hosts." "Error"
        }
        
    }
    else
    {
        #check if the available capacity meets the number of sessions or not
        write-log 1 "Current total number of user sessions: $SessionCount" "Info"
        write-log 1 "Pool Capacity: $PoolCapacity Pool Users: $($($RDPoolStatus|Measure-Object -Property TotalUsers -Sum).Sum) Pool Utilization: $PoolUtilization" "Info"

        If($PoolUtilization -lt $CapacityFloor -and $($RDPoolStatus|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property RDSH).Count -gt $MinimumNumberOfRDSH)
        {
            #Write-Host "Pool is overprovisioned, Reducing capacity"
            Write-log 1 "Pool is overprovisioned, Reducing capacity.." "Info"
            $SelectedServer =($RDPoolStatus |Where-Object {$_.Available -eq "Yes"}|Sort-Object -Property Priority|select -First 1)
            $ScaleTest = Test-RDPoolSize -pool $RDPoolStatus -scale Down -member $SelectedServer
            if($ScaleTest)
            {
                #Write-Host "Scaling down pool host $($SelectedServer.RDSH)"
                Write-Log 1 "Scaling down pool host $($SelectedServer.RDSH)" "Info"
                Drain-RDSHServer -collectionName $collection.CollectionName -connectionBroker $ConnectionBrokerFQDN -serverName $SelectedServer.RDSH
                $SelectedServer.Available = "No"
            }
        }

        If($PoolUtilization -ge $CapacityTop)
        {
            Write-Host "Pool is unprovisioned, Increasing capacity"
            Write-log 1 "Pool is unprovisioned, Increasing capacity.." "Info"
            $SelectedServer =($RDPoolStatus |Where-Object {$_.Available -ne "Yes"}|sort -Property Priority -Descending|select -First 1)
            if($SelectedServer -ne $null)
            {
                $ScaleTest = Test-RDPoolSize -pool $RDPoolStatus -scale Up -member $SelectedServer
                if($ScaleTest)
                {
                    #Write-Host "Scaling up pool host $($SelectedServer.RDSH)"
                    Write-Log 1 "Scaling up pool host $($SelectedServer.RDSH)" "Info"
                    ScaleOut-RDSHServer -collectionName $collection.CollectionName -connectionBroker $ConnectionBrokerFQDN -serverName $SelectedServer.RDSH
                    $SelectedServer.Available = "Yes"
                }
            }
            else
            {
                Write-Log 1 "ALERT: Insufficient standby capacity available! Please provision more session hosts." "Error"
            }
        }

    }
    $PoolCapacity = ($RDPoolStatus|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property MaxCapacity -Sum).Sum
    $PoolUtilization = "{0:P}" -f($($($RDPoolStatus|Measure-Object -Property TotalUsers -Sum).Sum)/$($($RDPoolStatus|Where-Object {$_.Available -eq "Yes"}|Measure-Object -Property MaxCapacity -Sum).Sum))
    #write to the usage log
    Write-UsageLog $collection.CollectionName $totalRunningCores $numberOfRunningHost $SessionCount $PoolCapacity $PoolUtilization
}

Write-Log 3 "End RDS Scale Optimization." "Info"