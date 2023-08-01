# Start and append post-migration log file
Start-Transcript -Append "C:\ProgramData\IntuneMigration\post-migration.log" -Verbose

$ErrorActionPreference = 'SilentlyContinue'

# Update Intune device primary user with current active user
<#PERMISSIONS NEEDED FOR APP REG:
Device.ReadWrite.All
DeviceManagementApps.ReadWrite.All
DeviceManagementConfiguration.ReadWrite.All
DeviceManagementManagedDevices.PrivilegedOperations.All
DeviceManagementManagedDevices.ReadWrite.All
DeviceManagementServiceConfig.ReadWrite.All
User.ReadWrite.All
#>

# App reg info for tenant B
$clientId = "<CLIENT ID>"
$clientSecret = "<CLIENT SECRET>"
$tenant = "TenantB.com"

# Authenticate to graph
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/x-www-form-urlencoded")

$body = "grant_type=client_credentials&scope=https://graph.microsoft.com/.default"
$body += -join("&client_id=" , $clientId, "&client_secret=", $clientSecret)

$response = Invoke-RestMethod "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Method 'POST' -Headers $headers -Body $body

#Get Token form OAuth.
$token = -join("Bearer ", $response.access_token)

#Reinstantiate headers.
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", $token)
$headers.Add("Content-Type", "application/json")
Write-Host "MS Graph Authenticated"

#==============================================================================#
# Get Device and user info
[xml]$memSettings = Get-Content "C:\ProgramData\IntuneMigration\MEM_Settings.xml"
$memConfig = $memSettings.Config

$serialNumber = $memConfig.SerialNumber

$intuneObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers

$IntuneDeviceId = $intuneObject.value.id
Write-Host "Intune Device ID is $($IntuneDeviceId)"

$userName = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI" -name "LastLoggedOnDisplayName"
Write-Host "Getting current user $($userName) Azure AD object ID..."

$userObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/users`$filter=displayName eq '$($userName)'" -Headers $headers
$userId = $userObject.value.id
Write-Host "Azure AD user object ID for $($userName) is $($userId)"

# Get user URI REF and construct JSON body for graph call
$deviceUsersUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$intuneDeviceId')/users/`$ref"
$userUri = "https://graph.microsoft.com/beta/users/" + $userId

$id = "@odata.id"
$JSON = @{ $id="$userUri" } | ConvertTo-Json -Compress

# POST primary user in graph
Invoke-RestMethod -Method Post -Uri $deviceUsersUri -Headers $headers -Body $JSON -ContentType "application/json"

Start-Sleep -Seconds 3

# Disable Task
Disable-ScheduledTask -TaskName "SetPrimaryUser"
Write-Host "Disabled SetPrimaryUser scheduled task"

Stop-Transcript
