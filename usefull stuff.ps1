#run first to connect, then c/p the commented lines you want to the console
if ((Get-PSSnapin "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) -eq $null) {
	Add-PSSnapin "VMware.VimAutomation.Core"
}
Connect-VIServer 'vcenter'

#disconnect all cdroms
#Get-VM | Where-Object {$_ | Get-CDDrive | Where-Object { $_.ConnectionState.Connected -eq "true"  } } | Get-CDDrive | Set-CDDrive -Connected $false -Confirm:$false

#connect all nics
#Get-VM | Where-Object {$_ | Get-NetworkAdapter | Where-Object { $_.ConnectionState.Connected -eq "false"  } } | Get-NetworkAdapter | Set-NetworkAdapter  -Connected $false -Confirm:$false

#get a vm's vmx path
#Get-VM "xkerio 1" | Select Name, @{N="VMX";E={$_.Extensiondata.Summary.Config.VmPathName}}

