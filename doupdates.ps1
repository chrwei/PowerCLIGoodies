#remediates all hosts in choosen clusters to choosen baselines, vmotioning off 
#guests in a balanced way, and restoring to original hosts when done
#no edits needed, vcenter will be promtped for




#this code didn't work correctly the last time I tried it, so user beware!  
#I only have 2 hosts now so I don't need this script anymore, so I won't be fixing it.  
#feel free to clone and issue a pull req if you fix it


$vmHostData = @{}
$vmGuestData = @{}

function do_clear_screen(){
    #clear
    #Write-Host "#### VMware Cluster Remediation ####"
    #Write-Host
    Write-Host
}
 
function do_snapin_check() {
    $statusloaded=$false
    $snapins=("VMware.VimAutomation.Core","http://www.vmware.com/support/developer/PowerCLI/index.html"),("VMware.VumAutomation","http://www.vmware.com/support/developer/ps-libs/vumps/")
    foreach ($snapin in $snapins) {
        Add-PSSnapin $snapin[0]
        if((Get-PSSnapin $snapin[0]) �eq $null){
            Write-Host "This script requires" $snapin[0]
            Write-Host "Which can be downloaded free from" $snapin[1]
        } else {
            $statusloaded=$true
        }
    }
    return $statusloaded
}
 
function do_login(){
    do {
        $login = $false
        $vcenter = Read-Host "vCenter server name or IP"
        $credential = $host.ui.PromptForCredential("Credentials required", "Please enter your user name and password.", "", "")
        Write-Host "Attempting to login..."
        Connect-VIServer -Server $vcenter -Credential $credential -Protocol https | Out-Null
        if (-not $?) {
            do_clear_screen
            Write-Host "Unable to login. Please try again."
        } else {
            $login = $true
        }
    } until ($login -eq $true)
}
 
function do_baseline_menu(){
    $available = @{}
    $selected = @()
    $i = 0
    do {
        $available[$i] = $baselines.SyncRoot[$i].Name
        $i++
    } until ($i -ge $baselines.Count)
    do {
        do_clear_screen
        $i = 0
        do {
            if($available[$i]) {
                Write-Host $i":" $available[$i]
            }
            $i++
        } until ($i -eq ($baselines.Count))
 
        do {
            $sel = Read-Host "Please choose the baseline you'd like to apply"
        } until ( ($sel -ge "0") -and ($sel -lt $baselines.Count))
        [int]$sel = $sel
        foreach ($baseline in $baselines) {
            if ($baseline.Name -eq $available[$sel]) {
                $selected += $baseline
            }
        }
        $available.Remove($sel)
        if ($selected.Count -ne $baselines.Count) {
            do {
                $continue = Read-Host "Would you like to choose another baseline to be applied? [y/n]"
            } until ( ($continue.ToLower() -eq "y") -or ($continue.ToLower() -eq "n") )
 
            if ($continue.ToLower() -eq "y") {
                do_clear_screen
            }
        } else {
            $continue = "n"
        }
    } until ($continue.ToLower() -eq "n")
    return $selected
}
 
function do_cluster_menu() {
    do_clear_screen
	if ($clusters.Count -lt 0) {
		Write-Host $clusters.Name " is the only cluster, selecting it"
		[string]$cluster_choices = $clusters.Name
	}
	else {
		Write-Host "Looping Clusters"
	    $i = 0

	    do {
	        Write-Host $i":" $clusters.Syncroot[$i].Name
	        $i++
	    } until ($i -eq $clusters.Count)
	 	Write-Host "Select"
	    do {
	        [int]$sel = Read-Host "Please choose the cluster you'd like to apply patches to"
	    } until ( ($sel -ge "0") -and ($sel -lt ($clusters.Count)) )
	    [string]$cluster_choices = $clusters.SyncRoot[$sel].Name
	}
    return $cluster_choices
}
 
function do_cluster_remediation() {
    do_clear_screen
	$vmHostData = @{}
	$vmGuestData = @{}

	Write-Host "Please wait, retrieving cluster..."
    $cluster = Get-Cluster $cluster_choices
    if(!$cluster) {
        Write-Host "Unable to retrieve cluster details. Exiting."
        break;
    }
    $vmHosts = Get-VMHost -Location $cluster | where { ($_.ConnectionState -eq "Connected") -and ($_.Version -eq "4.1.0") }
    if (!$vmHosts) {
        Write-Host "No ESX(i) 4.1 hosts found in cluster. Exiting."
        break;
    } else {
        $err = $null
    # Verifying vMotion is enabled on a specific portgroup
        foreach ($vmHost in $vmHosts) {
        Write-Host "Verifying vMotion requirements on host $vmHost"
        $vmknic = Get-VMHostNetworkAdapter -VMHost $vmHost | where {$_.PortGroupName -like "vmkernel"}
        if ($vmknic.VMotionEnabled.Equals($false)) {
            Write-Host "vMotion requirement failed on host $vmHost. Exiting."
            $err = "1"
            break;
            }
        }
    }
 
    if(!$err) {
        Write-Host "vMotion requirements passed."
		
		$vmGuests = $vmHosts | Get-VM
		#get usage totals and defaults
		foreach ($vmHost in $vmHosts) {
			$vmHostData[$vmHost.Name] = @{"RamAlloc"=0;"RamPerc"=0;"RamFree"=0}
		}
		foreach ($vmGuest in $vmGuests) {
			$vmGuestData[$vmGuest.Name] = @{"originalhost"=$vmGuest.VMHost.Name}
			$vmHost = $vmHosts | Where-Object {$_.name -eq $vmGuest.VMHost.Name}
			if ($vmHost) {
				$vmHostData[$vmHost.Name]["RamAlloc"] += [int] $vmGuest.MemoryMB
				$vmHostData[$vmHost.Name]["RamPerc"] = $vmHostData[$vmHost.Name]["RamAlloc"] / $vmHost.memoryTotalMB
				$vmHostData[$vmHost.Name]["RamFree"] = $vmHost.memoryTotalMB - $vmHostData[$vmHost.Name]["RamAlloc"]
			}
		}

        foreach ($vmHost in $vmHosts) {
	        # vMotion all of the VMs from the current host to partners in the cluster
			$tasklist = @()
			$maxstat = 0
			$vmGuests = $vmHost | Get-VM 
			foreach($MoveVM in $vmGuests | Sort-Object -Descending MemoryMB ) {
				#find host with most ram free
				$MoveToHost = $vmHosts | Where-Object {$_.Name -ne $MoveVM.VMHost.Name} | Sort-Object -Descending {$vmHostData[$_.Name]["RamFree"]} | select -First 1
				
				$vmHostData[$vmHost.Name]["RamAlloc"] -= [int] $MoveVM.MemoryMB
				$vmHostData[$vmHost.Name]["RamPerc"] = $vmHostData[$vmHost.Name]["RamAlloc"] / $vmHost.memoryTotalMB
				$vmHostData[$vmHost.Name]["RamFree"] = $vmHost.memoryTotalMB - $vmHostData[$vmHost.Name]["RamAlloc"]

				$vmHostData[$MoveToHost.Name]["RamAlloc"] += [int] $MoveVM.MemoryMB
				$vmHostData[$MoveToHost.Name]["RamPerc"] = $vmHostData[$MoveToHost.Name]["RamAlloc"] / $MoveToHost.memoryTotalMB
				$vmHostData[$MoveToHost.Name]["RamFree"] = $MoveToHost.memoryTotalMB - $vmHostData[$MoveToHost.Name]["RamAlloc"]

				Write-Host "Moving $MoveVM from " $MoveVM.VMHost.Name " to " $MoveToHost.Name
				$tasklist += moveto -VM $MoveVM -NewHost $MoveToHost
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
			
	        Write-Host "Remediating $vmHost"
	        Remediate-Inventory -Baseline $baseline_choices -Entity $vmHost -Confirm:$false -ClusterDisableHighAvailability:$true
		}

	    Write-Host "Remediating complete, putting guests back"

		$tasklist = @()
		$maxstat = 0
		$vmGuests = $vmHosts | Get-VM
		foreach ($vmGuest in $vmGuests) {
			$vmHost = $vmHosts | Where-Object {$_.Name -eq $vmGuest.VMHost.Name}
			if ($vmGuestData[$vmGuest.Name]["originalhost"] -ne $vmHost.Name) {
				Write-Host "Moving $vmGuest from " $vmGuest.Host " to " $vmGuestData[$vmGuest.Name]["originalhost"]
				$tasklist += moveto -VM $vmGuest -NewHost $vmGuestData[$vmGuest.Name]["originalhost"]
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
	}
}

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

		#wait for migrate
		$task = Get-View $taskMoRef 
		
		return $task  
	}
	
}

$ErrorActionPreference = "SilentlyContinue"
do_clear_screen
$statusloaded = do_snapin_check
if ($statusloaded) {
    do_login
 
 	Write-Host "disconnecting all guest cdroms"
	Get-VM | Where-Object {$_ | Get-CDDrive | Where-Object { $_.ConnectionState.Connected -eq "true"  } } | Get-CDDrive | Set-CDDrive -Connected $false -Confirm:$false
	
    # ----- BASELINE ----- #
    do_clear_screen
    Write-Host "Please wait, retrieving baselines..."
    $baselines = Get-Baseline | where {$_.IsSystemDefined -eq $false}
    if ($baselines) {
        $baseline_choices = do_baseline_menu
    } else {
        Write-Host "An error occurred while retrieving baselines. Exiting."
    }
    # ----- BASELINE ----- #
 
    do {
        # ----- CLUSTERS ----- #
        do_clear_screen
        Write-Host "Please wait, retrieving clusters..."
        $clusters = Get-Cluster | Sort-Object -Property Name
        if ($clusters) {
            $cluster_choices = do_cluster_menu
        } else {
            Write-Host "An error occurred while retrieving clusters. Exiting."
        }
        # ----- CLUSTERS ----- #
 
        # ----- REMEDIATION ----- #
        do_clear_screen
        Write-Host "You chose the following baselines to be applied:"
        Write-Host
        foreach ($baseline in $baseline_choices) {
            $baseline.Name
        }
        Write-Host
        Write-Host "You chose the following cluster to be updated:"
        Write-Host
        $cluster_choices
        Write-Host
        do {
            $continue = Read-Host "Would you like to continue? [y/n]"
        } until ( ($continue.ToLower() -eq "y") -or ($continue.ToLower() -eq "n") )
 
        if ($continue.ToLower() -eq "n") {
            Write-Host "Exiting."
        #   break;
        } else {
            do_cluster_remediation
        }
        # ----- REMEDIATION ----- #
        $continue = Read-Host "Would you like to apply the same baselines to another cluster? [y/n]"
    } until ($continue.ToLower() -eq "n")
}