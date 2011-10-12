#suspends running vm and moves to different datastore.
#bulk of this file is the Move-VMThin function, which can be modfied to do preallocated too
#edit the $spec.transform line to "sparse" to use thin disks, and "flat" for normal
#end of files has example lines to edit to choose the vm's you want to move and where
#edit line 13 to point to your vcenter

#setup vi api
if ((Get-PSSnapin "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) -eq $null) {
	Add-PSSnapin "VMware.VimAutomation.Core"
}

#connect to vcenter
Connect-VIServer -server vcenter

function Move-VMThin {
    PARAM(
         [Parameter(Mandatory=$true,ValueFromPipeline=$true,HelpMessage="Virtual Machine Objects to Migrate")]
         [ValidateNotNullOrEmpty()]
            [System.String]$VM
        ,[Parameter(Mandatory=$true,HelpMessage="Destination Datastore")]
         [ValidateNotNullOrEmpty()]
            [System.String]$Datastore
    )
    
	Begin {
        #Nothing Necessary to process
	} #Begin
    
    Process {        
        #Prepare Migration info, uses .NET API to specify a transformation to thin disk
        $vmView = Get-View -ViewType VirtualMachine -Filter @{"Name" = "$VM"}
        $dsView = Get-View -ViewType Datastore -Filter @{"Name" = "$Datastore"}
        
        #Abort Migration if free space on destination datastore is less than 50GB
        if (($dsView.info.freespace / 1GB) -lt 50) {throw "Move-ThinVM ERROR: Destination Datastore $Datastore has less than 50GB of free space. This script requires at least 50GB of free space for safety. Please free up space or use the VMWare Client to perform this Migration"}
		
		#suspends first and wait
		Suspend-VMGuest -VM $VM 
		while ("poweredOn" -contains $vmView.Runtime.PowerState) {
			sleep 1
			$vmView.UpdateViewData("Runtime.PowerState")
			$vmView.Runtime.PowerState
		}
		
        #Prepare VM Relocation Specificatoin
        $spec = New-Object VMware.Vim.VirtualMachineRelocateSpec
        $spec.datastore =  $dsView.MoRef
        $spec.transform = "sparse" #"flat"
        
        #Perform Migration
		$taskMoRef = $vmView.RelocateVM_Task($spec, $null)

		#wait for migrate
		$task = Get-View $taskMoRef 
		while ("running","queued" -contains $task.Info.State) {
			sleep 5
			$task.UpdateViewData("Info.State")
		}
		
		#start again
		Start-VM -VM $VM 
	} #Process
}

Move-VMThin -VM "vpn" -Datastore "iscsi2"
Move-VMThin -VM "web" -Datastore "iscsi2"
Move-VMThin -VM "mailman" -Datastore "iscsi2"
