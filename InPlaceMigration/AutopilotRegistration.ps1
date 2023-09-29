# Start and append post-migration log file
Start-Transcript -Append "C:\ProgramData\IntuneMigration\post-migration.log" -Verbose
Write-Host "BEGIN LOGGING FOR AUTOPILOTREGISTRATION..."
# Install for NUGET
Install-PackageProvider -Name NuGet -Confirm:$false -Force

# Install and import required modules
$requiredModules = @(
    'Microsoft.Graph.Intune'
    'WindowsAutopilotIntune'
)

foreach($module in $requiredModules)
{
    Install-Module -Name $module -AllowClobber -Force
}

foreach($module in $requiredModules)
{
    Import-Module $module
}

# Tenant B App reg

<#PERMISSIONS NEEDED:
Device.ReadWrite.All
DeviceManagementApps.ReadWrite.All
DeviceManagementConfiguration.ReadWrite.All
DeviceManagementManagedDevices.PrivilegedOperations.All
DeviceManagementManagedDevices.ReadWrite.All
DeviceManagementServiceConfig.ReadWrite.All
#>

$clientId = "<CLIENT ID>"
$clientSecret = "<CLIENT SECRET>"
$clientSecureSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$clientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $clientSecureSecret
$tenantId = "<TENANT ID>"

# Authenticate to graph and add Autopilot device
Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $clientSecretCredential

# Get Autopilot device info
$hwid = ((Get-WmiObject -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData)

$ser = (Get-WmiObject win32_bios).SerialNumber
if([string]::IsNullOrWhiteSpace($ser)) { $ser = $env:COMPUTERNAME}

# Retrieve group tag info
[xml]$memConfig = Get-Content "C:\ProgramData\IntuneMigration\MEM_Settings.xml"

$tag = $memConfig.Config.GroupTag

Add-AutopilotImportedDevice -serialNumber $ser -hardwareIdentifier $hwid -groupTag $tag
Start-Sleep -Seconds 5

#now delete scheduled task
Disable-ScheduledTask -TaskName "AutopilotRegistration"
Write-Host "Disabled AutopilotRegistration scheduled task"

Write-Host "END LOGGING FOR AUTOPILOTREGISTRATION..."
Stop-Transcript