#walks all configured NFS stores on all hosts and forcable reconnects any inaccesable ones
#edit line 10 to point to your vcenter

#setup vi api
if ((Get-PSSnapin "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) -eq $null) {
	Add-PSSnapin "VMware.VimAutomation.Core"
}

#connect to vcenter
Connect-VIServer vcenter

$results = @()
$vmhosts = Get-VMHost 
foreach ($vmhost in $vmhosts) {
    Write-Host "Checking $vmhost"
	$datastores = Get-Datastore -VMHost $vmhost | Where-Object {$_.Type -eq 'NFS'}
    foreach ($datastore in $datastores) {
        if(!$datastore.Accessible){
			$nfshost = $datastore.ExtensionData.Info.NAS.RemoteHost
			$nfspath = $datastore.ExtensionData.Info.NAS.RemotePath
			$nfsname = $datastore.Name
			Write-Host "$nfsname on $vmhost is not accessable, removing and re-adding as $nfshost : $nfspath."
			Remove-Datastore -VMHost $vmhost -Datastore $nfsname -Confirm:$false
			New-Datastore -Nfs -VMHost $vmhost -Name $nfsname -Path $nfspath -NfsHost $nfshost
		}
    }
}

#example one-offs
#Get-VMHost | New-Datastore -Nfs -Name 'backup' -Path '/media/data' -NfsHost 10.254.0.154
#New-Datastore -Nfs -VMHost 'esx2.wilson.local' -Name 'backup' -Path '/media/data' -NfsHost 10.254.0.154
#New-Datastore -Nfs -VMHost 'esx4.wilson.local' -Name 'backup' -Path '/media/data' -NfsHost 10.254.0.154
#New-Datastore -Nfs -VMHost 'esx3' -Name 'backup' -Path '/media/data' -NfsHost 10.254.0.154

#Remove-Datastore -VMHost 'esx2.wilson.local' -Datastore 'dedup' -Confirm:$false
#Remove-Datastore -VMHost 'esx4.wilson.local' -Datastore 'dedup' -Confirm:$false
#Remove-Datastore -VMHost 'esx3' -Datastore 'dedup' -Confirm:$false
