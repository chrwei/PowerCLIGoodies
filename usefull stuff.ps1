#run first to connect, then c/p the commented lines you want to the console
if ((Get-PSSnapin "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) -eq $null) {
	Add-PSSnapin "VMware.VimAutomation.Core"
}
Connect-VIServer 'vcenter'

#disconnect all cdroms
#Get-VM | Where-Object {$_ | Get-CDDrive | Where-Object { $_.ConnectionState.Connected -eq "true"  } } | Get-CDDrive | Set-CDDrive -Connected $false -Confirm:$false
#unmap all cdroms
#Get-VM | Where-Object {$_ | Get-CDDrive | Where-Object { $_.IsoPath -ne $null  } } | Get-CDDrive | Set-CDDrive -NoMedia -Connected $false -StartConnected $false -Confirm:$false

#connect all nics
#Get-VM | Where-Object {$_ | Get-NetworkAdapter | Where-Object { $_.ConnectionState.Connected -eq "false"  } } | Get-NetworkAdapter | Set-NetworkAdapter  -Connected $false -Confirm:$false

#get a vm's vmx path
#Get-VM "xkerio 1" | Select Name, @{N="VMX";E={$_.Extensiondata.Summary.Config.VmPathName}}

#set a vmx option on all guests
#$Spec = new-object VMware.Vim.VirtualMachineConfigSpec
#$Spec.extraconfig += New-Object VMware.Vim.optionvalue
#$Spec.extraconfig[0].Key= "keyboard.typematicMinDelay"
#$Spec.extraconfig[0].Value= "2000000"
#Get-VM  | % {
#    $_.Extensiondata.ReconfigVM($Spec)
#}
#select the option
#Get-VM | select Name, @{N="MinDelay";E={($_.Extensiondata.Config.ExtraConfig | where {$_.Key -eq "keyboard.typematicMinDelay"}).Value}}
