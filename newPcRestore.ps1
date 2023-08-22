# TENANT TO TENANT DEVICE MIGRATION: MIGRATE TO NEW HARDWARE
# THIS SCRIPT SHOULD BE RUN ON A NEW AUTOPILOT DEVICE ONCE A USER SIGNS IN
# SCRIPT RUNS FROM TENANT B

# SET LOCAL PATH
$localPath = "C:\ProgramData\IntuneMigration\"
if(!(Test-Path $localPath))
{
    mkdir $localPath
}

#Set detection flag for Intune install
$installFlag = "$($localPath)\Installed.txt"
New-Item $installFlag -Force
Set-Content -Path $($installFlag) -Value "Package Installed"

#Start logging of script
Start-Transcript -Path "$($localPath)\migration.log" -Verbose
Write-Host "Starting user data restore..."

# CHECK NETWORK CONFIG FOR SHARING
# Check Windows Firewall ICMP settings
Write-Host "Checking connectivity and firewall rules..."
$firewallRules = Get-NetFirewallRule | Where-Object {$_.DisplayName -eq "File and Printer Sharing (Echo Request - ICMPv4-In)"}

if ($firewallRules.Count -eq 0) {
    Write-Host "ICMP (ping) requests are not allowed by Windows Firewall. Enabling ICMP..."
    New-NetFirewallRule -DisplayName "Allow ICMP" -Direction Inbound -Protocol ICMPv4 -Action Allow -Enabled True
    Write-Host "ICMP (ping) requests are now allowed and enabled by Windows Firewall."
} elseif ($firewallRules.Action -eq "Allow" -and $firewallRules.Enabled -eq "False") {
    Write-Host "ICMP (ping) requests are already allowed and but not enabled by Windows Firewall.  Enabling..."
    Set-NetFirewallRule -Name $firewallRules.Name -Enabled True
    Write-Host "ICMP (ping) requests are enabled."

} else {
    Write-Host "ICMP (ping) requests are blocked by Windows Firewall. Enabling ICMP..."
    Set-NetFirewallRule -Name $firewallRules.Name -Action Allow -Enabled True
    Write-Host "ICMP (ping) requests are now allowed and enabled by Windows Firewall."
}

# CHECK IF WINRM IS RUNNING
$winrmStatus = Get-Service -Name "WinRM" -ErrorAction SilentlyContinue
if($winrmStatus -eq $null)
{
    Write-Host "WinRM is not installed."
}elseif($winrmStatus.Status -eq "Running")
{
    Write-Host "WinRM is already running."
}else
{
    Write-Host "WinRM is not running.  Starting WinRM..."
    Start-Service -Name "WinRM"
    Write-Host "WinRM has been started."
}


# INSTALL AZ STORAGE MODULE FOR BLOB
$nuget = Get-PackageProvider -Name NuGet

if(-not($nuget))
{
    Write-Host "Package Provider NuGet not found - installing now..."
    Install-PackageProvider -Name NuGet -Confirm:$false -Force
} else 
{
    Write-Host "Package Provider NuGet already installed."
}

$azStorage = Get-InstalledModule -Name Az.Storage

if(-not($azStorage))
{
    Write-Host "Az.Storage module not found - installing now..."
    Install-Module -Name Az.Storage -Force
    Import-Module Az.Storage
} else 
{
    Write-Host "Az.Storage module already installed."
}

# GET USERNAME
$activeUsername = (Get-WMIObject Win32_ComputerSystem | Select-Object username).username
$user = $activeUsername -replace '.*\\'
Write-Host "Current active user is $($user)"

# CONNECT TO BLOB STORAGE
$storageAccountName = "<Azure Storage Account Name>"
$storageAccountKey = "<Azure Storage Account Key>"
$context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
$container = "<container name>"

Write-Host "Connecting to Azure blob storage.  Searching for blob containing $($user)"
# FIND BLOB THAT CONTAINS MATCHING USERNAME
$myBlob = (Get-AzStorageBlob -Container $container -Context $context) | Where-Object {$_.Name -like "*$($user)*"}

$blobName = $myBlob.Name
Write-Host "Found blob $($blobName)"

# CONSTRUCT BLOB REQUEST
$blobDownload = @{
    Blob = $blobName
    Container = $container
    Destination = $localPath
    Context = $context
}

# GET BLOB
Get-AzStorageBlobContent @blobDownload | Out-Null
Write-Host "Downloaded blob $($blobName)"

# GET XML FROM BLOB
Write-Host "Importing source device info from XML..."
[xml]$xmlSettings = Get-Content -Path "$($localPath)\$($blobName)"
$xmlConfig = $xmlSettings.Config

$hostname = $xmlConfig.Hostname
Write-Host "Source device hostname is $($hostname)"
$shareName = $xmlConfig.ShareName
Write-Host "Source device SMB share name is $($shareName)"
$shareUser = $xmlConfig.ShareUser
Write-Host "SMB share read account is $($shareUser)"
$password = $xmlConfig.SharePassword
$locations = $xmlConfig.Locations.Location

New-SmbMapping -LocalPath "H:" -RemotePath "\\$($hostname)\$($shareName)" -UserName "$($hostname)\$($shareUser)" -Password $password

Write-Host "Mapped network drive H: to \\$($hostname)\$($shareName)"

Write-Host "Start user data migration..."
foreach($location in $locations){
    $targetPath = "C:\Users\$($user)\$($location)"
    $sourcepath = "H:\$($location)"

    Write-Host "Moving data from $($sourcepath) to $($targetPath)"
    robocopy $sourcepath $targetPath /E /ZB /R:0 /W:0 /V /XJ /FFT
}
