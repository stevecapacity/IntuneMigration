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

$serialNumber = Get-WmiObject -Class Win32_Bios | Select-Object -ExpandProperty serialNumber

$hostname = $env:COMPUTERNAME
$activeUsername = (Get-WmiObject Win32_ComputerSystem | Select-Object | username).username
$objUser = New-Object System.Security.Principal.NTAccount("$activeUsername")
$strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
$userSID = $strSID.Value
Write-Host "Getting Intune ID for $($hostname) in $($tenant)..."

try 
{
    $intuneObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers
    Write-Host "$($hostname) Intune object found."
    $intuneID = $intuneObject.value.id
    Write-Host "Intune ID is $($intuneID)"
}
catch 
{
    Write-Host "Could not retrieve Intune object for $($hostname)"
    Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
    Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
}

$userName = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$($userSID)\IdentityCache\$($userSID)" -Name "UserName"
Write-Host "Getting current user $($userName) Azure AD object ID..."

try 
{
    $userObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/users/$($userName)" -Headers $headers
    $userId = $userObject.value.id
    Write-Host "Azure AD user object ID for $($userName) is $($userId)"
}
catch 
{
    Write-Host "Could not retrieve Azure object for $($username)"
    Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
    Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
}


# Get user URI REF and construct JSON body for graph call
$deviceUsersUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$intuneID')/users/`$ref"
$userUri = "https://graph.microsoft.com/beta/users/" + $userId

$id = "@odata.id"
$JSON = @{ $id="$userUri" } | ConvertTo-Json -Compress

# POST primary user in graph
Write-Host "Setting $($username) as primary user on $($hostname)..."
try 
{
    Invoke-RestMethod -Method Post -Uri $deviceUsersUri -Headers $headers -Body $JSON -ContentType "application/json"
    Start-Sleep -Seconds 2 
    Write-Host "$($username) has been set as the primary user for $($hostname)"  
}
catch 
{
    Write-Host "Could not set $($user) as primary user for $($hostname)"
    Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
    Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
}
Start-Sleep -Seconds 3

# Disable Task
Disable-ScheduledTask -TaskName "SetPrimaryUser"
Write-Host "Disabled SetPrimaryUser scheduled task"

Stop-Transcript
