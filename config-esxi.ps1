$confighostname = "esxhost1" #host to configure, use the name as shown in vcenter
$switchs = @{
				#lan traffic
				"vSWitch0" = @{
								"activenics" = "vmnic0", "vmnic3";
								"networks" = 	@{
													"vLAN1 - Default" = @{ "vlan" = "1"; };
													"vLAN3 - Sales" = @{ "vlan" = "3"; };
													"vLAN4 - Accounting" = @{ "vlan" = "4"; };
													"vLAN5 - Internet" = @{ "vlan" = "5"; };
												}
							};
				#iscsi traffic
				"vSWitch1" = @{
								"activenics" = "vmnic1", "vmnic2";
								"networks" = 	@{
													"SAN" = @{}; # no special settings
													"VMkernel 0" = @{"vmotion" = $true; }
												};
							};
			}
$iscsi = 	@{
				'vswitch' = "vSWitch1"; #the vswitch to put iscsi vmkernels in
				'vmkName' = 'VMkernel'; #this gets an index number added on for each vmk
				'IPnumber' = "11"; 		#this is the "Y" of the IP in the 10.254.x.Y vmkernel
				'targetIPs' = "10.254.0.1","10.254.1.1","10.254.2.1","10.254.3.1";
				'nics' = "vmnic1", "vmnic2", "vmnic1", "vmnic2"; #make in order of binding to the above IP's
			}
$nfs =		@{
				'backup' = @{ 'path' = '/media/data';  'host' = '10.254.0.154'; };
				'cd_iso' = @{ 'path' = '/images/cd_iso';  'host' = '10.254.0.155'; };
				'scratch' = @{ 'path' = '/media/scratch';  'host' = '10.254.0.1'; };
			}
$other =	@{
				'ntpserver' = 'ntphost';
				'adv' = 	@{
								"Disk.UseDeviceReset" = 0;
								"Disk.UseLunReset" = 1;
								"Disk.MaxLUN" = 50;
							};
			}
				

function do_snapin_check() {
    $statusloaded=$false
    $snapins=("VMware.VimAutomation.Core","http://www.vmware.com/support/developer/PowerCLI/index.html"),("VMware.VumAutomation","http://www.vmware.com/support/developer/ps-libs/vumps/")
    foreach ($snapin in $snapins) {
        if((Get-PSSnapin $snapin[0]) –eq $null){
	        Add-PSSnapin $snapin[0]
		}
        if((Get-PSSnapin $snapin[0]) –eq $null){
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
#       $vcenter = Read-Host "vCenter server name or IP"
#        $credential = $host.ui.PromptForCredential("Credentials required", "Please enter your user name and password.", "", "")
        Write-Host "Attempting to login..."
        Connect-VIServer -Server vcenter | Out-Null #$vcenter -Credential $credential -Protocol https | Out-Null
        if (-not $?) {
            do_clear_screen
            Write-Host "Unable to login. Please try again."
        } else {
            $login = $true
        }
    } until ($login -eq $true)
	Write-Host "Logged in"
}

function Set-AdvancedConfigurationValue
{
    param ([string]$Setting, [int]$Value)
     
    if ((Get-VMHostAdvancedConfiguration -VMHost $vmHost -Name $Setting).Item($Setting) -ne $Value) {
        Write-Host ".Setting advanced configuration $Setting to $Value"
        $vmHost | Set-VMHostAdvancedConfiguration -Name $Setting -Value $Value | Out-Null 
    }
}

# iSCSI port groups are named starting at 1, not 0.
function get-iSCSINameFromIndex
{
    param ([int]$Index)
    $iscsi['vmkName'] + ' ' + $Index
}

$statusloaded = do_snapin_check
if ($statusloaded) {
    do_login
	
	$vmHost = Get-vmhost $confighostname
	
	foreach($switch in ($switchs.keys | Sort-Object)) {
		Write-Host "Configuring $switch"
		$vswitch = Get-VirtualSwitch -VMHost $vmHost -Name $switch -ErrorAction SilentlyContinue
		if ($vswitch -eq $null) {
			Write-Host ".Creating $switch"
			$vswitch = New-VirtualSwitch -VMHost $vmHost -Name $switch -NumPorts 128
		}
		
		$nicteam = Get-NicTeamingPolicy -VirtualSwitch $vswitch 
		$orignics = $vswitch.Nic
		if($orignics -eq $null) {
			$orignics = @()
		}
		$newnics = $orignics
		foreach($nic in ($switchs[$switch]['activenics'] | Sort-Object)) {
			if ($nicteam.ActiveNic -notcontains $nic) {
				$newnics = $newnics + $nic
			}
		}
		if (@(Compare-Object $newnics $orignics -SyncWindow 0).Length -ne 0) {
			Write-Host ".Adding nics to $switch"
			$vswitch = Set-VirtualSwitch -VirtualSwitch $vswitch -Nic $newnics -Confirm:$false
		}
		$nicteam | Set-NicTeamingPolicy -LoadBalancingPolicy LoadBalanceSrcMac | Out-Null
		
		Write-Host ".Configuring Guest Networks"
		foreach($netname in ($switchs[$switch]['networks'].keys | Sort-Object)) {
			$net = Get-VirtualPortGroup -VMHost $vmHost -VirtualSwitch $vswitch -Name $netname -ErrorAction SilentlyContinue 
			if($net -eq $null) {
				Write-Host "..Creating $netname"
				$net = $vswitch | New-VirtualPortGroup -Name $netname 
			}
			if($switchs[$switch]['networks'][$netname]['vlan']) {
				$net | Set-VirtualPortGroup -VLanId $switchs[$switch]['networks'][$netname]['vlan'] | Out-Null 
			}
		}
	}
	Write-Host "Configuring Management Interface"
	Get-NicTeamingPolicy -VirtualPortGroup (Get-VirtualPortGroup -VMHost $vmHost -Name "Management Network") | Set-NicTeamingPolicy -InheritFailback $true -InheritFailoverOrder $true -InheritLoadBalancingPolicy $true -InheritNetworkFailoverDetectionPolicy $true -InheritNotifySwitches $true | Out-Null 
	
	Write-Host "Configuring VMKernels for ISCSI"
	$vswitch = Get-VirtualSwitch -VMHost $vmHost -Name $iscsi['vswitch']
	$existingIPs = ($vmHost | Get-VMHostNetworkAdapter | Where-object { $_.IP -ne "" } | %{ $_.IP })
	if ($existingIPs.GetType().FullName -eq "System.String") {
	    $existingIPs = New-Object System.Collections.ArrayList(, @($existingIPs))
	} else {
	    $existingIPs = New-Object System.Collections.ArrayList(, $existingIPs)
	}
	# Check desired IP addresses
	foreach($num in "0","1","2","3") {
	    $ip = "10.254." + $num + "." + $iscsi['IPnumber']
	    if (!$existingIPs.Contains($ip)) {
	        $iscsiName = get-iSCSINameFromIndex($num) 
	        Write-Host ".Creating new VMKernel port $iscsiName with address: $ip"
	        $vmnic = $vmHost | New-VMHostNetworkAdapter -PortGroup $iscsiName -IP $ip -SubnetMask 255.255.255.0 -ManagementTrafficEnabled $true -VirtualSwitch $vswitch 
	    } else {
	        $vmnic = $vmHost | Get-VMHostNetworkAdapter | Where-object { $_.IP -eq $ip }
			$iscsiName = $vmnic.PortGroupName 
	        Write-Host ".Configuring existing port group $iscsiName with address: $ip"
	        if ($vmnic.ManagementTrafficEnabled -eq $false) {
	            $vmHost | Set-VMHostNetworkAdapter -VirtualNic $vmnic -ManagementTrafficEnabled $true
	        }
#	        if ($vmnic.Mtu -ne $mtu) {
#	            $vmHost | Set-VMHostNetworkAdaptor -VirtualNic -Mtu $mtu
#	        }
	    }
		if($switchs[$iscsi['vswitch']]['networks'].ContainsKey($iscsiName) -and $switchs[$iscsi['vswitch']]['networks'][$iscsiName].ContainsKey('vmotion')) {
			Set-VMHostNetworkAdapter -VirtualNic $vmnic -VMotionEnabled:$switchs[$iscsi['vswitch']]['networks'][$netname]['vmotion'] -Confirm:$false  | Out-Null 
		}

	    $activeNic = $iscsi['nics'][$num]
	    Write-Host ".Configuring NIC teaming policy for port group $iscsiName"
	    $portGroupTeamingPolicy = $vmHost | Get-VirtualPortGroup -VirtualSwitch $vswitch -Name $iscsiName | Get-NicTeamingPolicy
	    if (($portGroupTeamingPolicy.ActiveNic.Length -ne 1) -or ($portGroupTeamingPolicy.ActiveNic[0] -ne $activeNic)) {
	        Write-Host "..Binding port group $iscsiName to NIC $activeNic"
	        $unusedNics = @()
			for ($j = 0; $j -lt $iscsi['nics'].Length; $j++) {
				if ($j -ne $num -and $activeNic -ne $iscsi['nics'][$j] -and $unusedNics -notcontains $iscsi['nics'][$j]) {
					$unusedNics += $iscsi['nics'][$j]
				} 
			}
	        Set-NicTeamingPolicy -VirtualPortGroup $portGroupTeamingPolicy -MakeNicUnused $unusedNics -MakeNicActive $activeNic | Out-Null 
	    }
	}
	
	foreach($oth in $other.keys) {
		switch($oth) {
			'ntpserver' {
					Write-Host "Configuring NTP"
					$ntph = Get-VMHostNtpServer -VMHost $vmHost -ErrorAction SilentlyContinue 
					if ($ntph -ne $null) {
						Remove-VmHostNtpServer -VMHost $vmHost -NtpServer $ntph -Confirm:$false | Out-Null
					}
					Add-VmHostNtpServer -VMHost $vmHost -NtpServer $other[$oth] | Out-Null 
					Get-VmHostService -VMHost $vmHost | Where-Object {$_.key -eq "ntpd"} | Restart-VMHostService -Confirm:$false | Out-Null
				}
			'adv' {
				foreach($adv in $other[$oth].keys) {
					Set-AdvancedConfigurationValue $adv $other[$oth][$adv]
				}
			}
		}
		
	}
	
	
	Write-Host "Configuring ISCSI"
	Get-VMHostStorage -VMHost $vmHost | Set-VMHostStorage -SoftwareIScsiEnabled $true |Out-Null 
	
	$hba = $vmHost | Get-VMHostHba -Type iScsi | Where {$_.Model -eq "iSCSI Software Adapter"}
    foreach($target in $iscsi['targetIPs']){
        if((Get-IScsiHbaTarget -IScsiHba $hba -Type Send | Where {$_.Address -cmatch $target}) -eq $null){
            Write-Host ".Adding $target"
            New-IScsiHbaTarget -IScsiHba $hba -Address $target | Out-Null
        }
    }
#esxcli is borked?
#	$iscsiHbaNumber = $iscsiHba | %{$_.Device}
#	$esxCli = Get-EsxCli -Server $confighostname
#	$iscsi['targetIPs'] | Foreach-object {
#	    $ip = $_
#	    $iscsiVmkNumber = $vmHost | Get-VMHostNetworkAdapter | Where-object { $_.IP -match $ip } | %{ $_.Name }
#	    Write-Host -ForegroundColor green "Binding VMKernel Port $iscsiVmkNumber to $iscsiHbaNumber"
#	    $esxCli.swiscsi.nic.add($iscsiHbaNumber, $iscsiVmkNumber)
#	}

	Write-Host "Configuring NFS"
	foreach($nfsname in ($nfs.keys | Sort-Object)) {
		$nfsds = Get-Datastore -VMHost $vmHost -Name $nfsname -ErrorAction SilentlyContinue 
		if($nfsds -eq $null) {
			Write-Host ".Adding " $nfs[$nfsname].host ":" $nfs[$nfsname].path " as $nfsname"
			$nfsds = New-Datastore -Nfs -VMHost $vmHost  -Name $nfsname -Path $nfs[$nfsname].path -NfsHost $nfs[$nfsname].host
		}
	}

	Write-Host "Rescan for VMFS"
	Get-VMHostStorage -VMHost $vmHost -RescanAllHba -RescanVmfs | Out-Null 
	

	Write-Host "All config Completed!"
}