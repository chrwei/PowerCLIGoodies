#this will attempt to balance the ram %allocated (not used) across hosts.  Adjust $RamThreshold to your preference
#edit line 11 to point to your vcenter

$RamThreshold = 55
$vmHostData = @{}
$vmGuestData = @{}

if ((Get-PSSnapin "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) -eq $null) {
	Add-PSSnapin "VMware.VimAutomation.Core"
}
Connect-VIServer 'vcenter' | Format-Table 

function moveto {
    PARAM(
         [Parameter(Mandatory=$true,ValueFromPipeline=$true,HelpMessage="Virtual Machine Objects to Move")]
         [ValidateNotNullOrEmpty()]
            [System.String]$VM
        ,[Parameter(Mandatory=$true,HelpMessage="Destination host")]
         [ValidateNotNullOrEmpty()]
            [System.String]$NewHost
    )

	Begin {
        #Nothing Necessary to process
	} #Begin

	Process {        
		$vmView = Get-View -ViewType VirtualMachine -Filter @{"Name" = "$VM"}
	    $hsView = Get-View -ViewType HostSystem -Filter @{"Name" = "$NewHost"}

		$spec = New-Object VMware.Vim.VirtualMachineRelocateSpec
	    $spec.host =  $hsView.MoRef

		$taskMoRef = $vmView.RelocateVM_Task($spec, $null)

		#start task and return for monitoring
		$task = Get-View $taskMoRef 
		
		return $task  
	}
	
}

Write-Host "disconnecting all guest cdroms"
Get-VM | Where-Object {$_ | Get-CDDrive | Where-Object { $_.ConnectionState.Connected -eq "true"  } } | Get-CDDrive | Set-CDDrive -Connected $false -Confirm:$false | Format-Table 
Write-Host "done."

Write-Host "Setting usage totals"
$vmHosts = Get-VMHost  | Where-Object {$_.ConnectionState -eq "Connected"} | Sort-Object -Property Name

foreach ($vmHost in $vmHosts) {
	$vmHostData[$vmHost.Name] = @{"RamAlloc"=0;"RamPerc"=0;"RamFree"=0}
}

$vmGuests = $vmHosts | Get-VM

foreach ($vmGuest in $vmGuests) {
	$vmHost = $vmHosts | Where-Object {$_.name -eq $vmGuest.Host.Name}
	$vmGuestData[$vmGuest.Name] = @{"newhost"=""}
	if ($vmHost) {
		$vmHostData[$vmHost.Name]["RamAlloc"] += [int] $vmGuest.MemoryMB
		$vmHostData[$vmHost.Name]["RamPerc"] = $vmHostData[$vmHost.Name]["RamAlloc"] / $vmHost.memoryTotalMB
		$vmHostData[$vmHost.Name]["RamFree"] = $vmHost.memoryTotalMB - $vmHostData[$vmHost.Name]["RamAlloc"]
	}
}
Write-Host "done."

Write-Host "Stats before"
$vmHosts | select name, memoryTotalMB, memoryusageMB, @{N="PercentUsed";E={[int] ($_.memoryusageMB/$_.memoryTotalMB*100)}}, @{N="Assigned";E={$vmHostData[$_.Name]["RamAlloc"]}}, @{N="PercentAssigned";E={[int] ($vmHostData[$_.Name]["RamPerc"] *100)}}, @{N="RamFree";E={$vmHostData[$_.Name]["RamFree"]}} | Format-Table

Write-Host "Calculating Load Balance and Performing Moves"
$tasklist = @()
$maxstat = 0
foreach ($vmHost in $vmHosts | Sort-Object -Descending {($vmHostData[$_.Name]["RamPerc"] *100)}) {
	while ([int] ($vmHostData[$vmhost.Name]["RamPerc"] *100) -gt $RamThreshold) {
		Write-Host "host " $vmhost.Name " Allocated at " $vmHostData[$vmhost.Name]["RamPerc"]
		#find least used host that's under the threashold
		$MoveToHost = $vmHosts | Where-Object { [int] ($vmHostData[$_.Name]["RamPerc"] *100) -lt $RamThreshold} | Sort-Object {($vmHostData[$_.Name]["RamPerc"] *100)} | select -First 1
		#if none, do nothing
		if ($MoveToHost -ne "") {
			#find the smallest VM that's not already assigned a new host
			$MoveVM = ($vmGuests | Where-Object {$_.host -eq $vmHost -and $vmGuestData[$_.Name]["newhost"] -eq "" } | Sort-Object MemoryMB | select -First 1)

			$vmGuestData[$MoveVM.Name]["newhost"] = $MoveToHost.Name 
			
			$vmHostData[$vmHost.Name]["RamAlloc"] -= [int] $MoveVM.MemoryMB
			$vmHostData[$vmHost.Name]["RamPerc"] = $vmHostData[$vmHost.Name]["RamAlloc"] / $vmHost.memoryTotalMB
			$vmHostData[$vmHost.Name]["RamFree"] = $vmHost.memoryTotalMB - $vmHostData[$vmHost.Name]["RamAlloc"]

			$vmHostData[$MoveToHost.Name]["RamAlloc"] -= [int] $MoveVM.MemoryMB
			$vmHostData[$MoveToHost.Name]["RamPerc"] = $vmHostData[$MoveToHost.Name]["RamAlloc"] / $MoveToHost.memoryTotalMB
			$vmHostData[$MoveToHost.Name]["RamFree"] = $MoveToHost.memoryTotalMB - $vmHostData[$MoveToHost.Name]["RamAlloc"]

			Write-Host "Moving $MoveVM from " $MoveVM.VMHost " to " $vmGuestData[$MoveVM.Name]["newhost"]
			$tasklist += moveto -VM $MoveVM -NewHost $vmGuestData[$MoveVM.Name]["newhost"]
		}
	}
}

$totalStat = [int] $tasklist.Count
do {
	if ($totalStat -eq 0) {
		$pctComplete = 100
	} else {
		$pctComplete = [int] (([float] ($totalStat - $maxstat) / [float] $totalStat)*100)
	}

	Write-Progress -Activity "Moving Guests" -Status "running" -PercentComplete $pctComplete -Id 1
	$maxstat = 0 #reset it to get a new count of running+queued
	foreach ($task in $tasklist) {
		$task.UpdateViewData("Info.State")
		$task.UpdateViewData("Info.Progress")
		if ("running","queued" -contains $task.Info.State) {
			$maxstat++
			if ($task.Info.Progress) {
				Write-Progress -ParentId 1 -Activity $task.Info.EntityName -Status $task.Info.State -PercentComplete $task.Info.Progress -Id $task.Info.EventChainId
			} else {
				Write-Progress -ParentId 1 -Activity $task.Info.EntityName -Status $task.Info.State -PercentComplete 0 -Id $task.Info.EventChainId
			}
		} else {
			Write-Progress -ParentId 1 -Activity $task.Info.EntityName -Status $task.Info.State -Id $task.Info.EventChainId -Completed 
		}
	}
	sleep 1
} until ($maxstat -eq 0)
Write-Progress -Activity "Moving Guests" -Status "Done" -Id 1 -Completed 

Write-Host "done."

Write-Host "Stats after"
$vmHosts | select name, memoryTotalMB, memoryusageMB, @{N="PercentUsed";E={[int] ($_.memoryusageMB/$_.memoryTotalMB*100)}}, @{N="Assigned";E={$vmHostData[$_.Name]["RamAlloc"]}}, @{N="PercentAssigned";E={[int] ($vmHostData[$_.Name]["RamPerc"] *100)}}, @{N="RamFree";E={$vmHostData[$_.Name]["RamFree"]}} | Format-Table 

Write-Host "done."

