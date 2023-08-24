# TENANT TO TENANT DEVICE MIGRATION: MIGRATE TO NEW HARDWARE
# THIS SCRIPT SHOULD BE RUN PRIOR TO USER RECEIVING NEW DEVICE
# SCRIPT RUNS FROM TENANT A
$ErrorActionPreference = 'SilentlyContinue'

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
Write-Host "Starting migration backup..."

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


# GET DEVICE INFO
Write-Host "Capturing device info..."
$serialNumber = Get-WmiObject -Class Win32_Bios | Select-Object -ExpandProperty serialNumber
Write-Host "Serial number is $($serialNumber)"
$hostname = $env:COMPUTERNAME
Write-Host "Hostname is $($hostname)"
$OSVersion = ([System.Environment]::OSVersion.Version).Build
Write-Host "Current Windows build is $($OSVersion)"

# GET DISK INFO
Write-Host "Getting disk info for C:\..."
$diskInfo = Get-Volume -DriveLetter C
$totalDiskSize = "{0:N2} GB" -f ($diskInfo.Size/ 1Gb)
Write-Host "C:\ disk size is $($totalDiskSize)"
$freeDiskSpace = "{0:N2} GB" -f ($diskInfo.SizeRemaining/ 1Gb)
Write-Host "C:\ has $($freeDiskSpace) available as free space"
$memory = "{0:N2} GB" -f ((Get-CimInstance win32_PhysicalMemory | Measure-Object Capacity -Sum).sum /1gb)
Write-Host "PC $($hostname) has $($memory) of physical RAM installed."

# PATHS TO BE MIGRATED
$locations = @(
	"AppData\Local"
	"AppData\Roaming"
	"Documents"
	"Desktop"
	"Pictures"
	"Downloads"
)

$xmlLocations = @()

foreach($location in $locations)
{
    $xmlLocations += "<Location>$location</Location>`n"
    Write-Host "Will migrate local path $($location)"
}

# GET INSTALLED APPLICATIONS
Write-Host "Getting installed applications..."
$allApps = @()

$UninstallKey = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall"

$appReg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine',$env:COMPUTERNAME)
$appRegKey = $appReg.OpenSubKey("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall")
$subKeys = $appRegKey.GetSubKeyNames()

foreach($key in $subKeys)
{
    $thisKey = $UninstallKey+"\\"+$key
    $thisSubKey = $appReg.OpenSubKey($thisKey)

    $app = $thisSubKey.GetValue("DisplayName")

    if($app -ne $null)
    {
        $allApps += "<Application>$app</Application>`n"
        Write-Host "$($app) is installed on PC $($hostname)"
    }
}

# CHECK MAPPED DRIVES
$allDrives = @()
Write-Host "Getting active user and mapped drives..."
$activeUsername = (Get-WmiObject Win32_ComputerSystem | Select-Object username).username
$user = $activeUsername -replace '.*\\'
Write-Host "Current user is $($user)"
$objUser = New-Object System.Security.Principal.NTAccount("$activeUsername")
$strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
$activeUserSID = $strSID.Value

$HKU = Get-PSDrive | Where-Object {$_.Name -eq "HKU"}
if(-not($HKU))
{
    Write-Host "HKU not loaded.  Adding..."
    New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS
}
else
{
    Write-Host "HKU exists"
}

$drives = Get-ItemProperty -Path "HKU:\$activeUserSID\Network\*" | Select-Object pschildname,remotepath

foreach($drive in $drives)
{
    $driveLetter = $drive | Select-Object -ExpandProperty pschildname
    $drivePath = $drive | Select-Object -ExpandProperty remotepath
    $driveXML = "<Drive>`n<DriveLetter>$driveLetter</DriveLetter>`n<DrivePath>$drivePath</DrivePath>`n</Drive>`n"
    $allDrives += $driveXML
    Write-Host "Drive $($driveLetter) is mapped to remote path $($drivePath)"
}

# GET CONNECTED PRINTERS
$allPrinters = @()
Write-Host "Getting connected printers..."
$printers = Get-Printer

foreach($printer in $printers)
{
    $Name = $printer | Select-Object -ExpandProperty Name
    $Driver = $printer | Select-Object -ExpandProperty DriverName
    $Port = $printer | Select-Object -ExpandProperty PortName
    $xmlPrinter = "<Printer>`n<Name>$Name</Name>`n<Driver>$Driver</Driver>`n<Port>$Port</Port>`n</Printer>`n"
    $allPrinters += $xmlPrinter
    Write-Host "Found printer $($Name) with driver $($Driver) on port $($Port)"
}

# DRIVE SHARE CREDENTIALS
$password = '@Password*123'
$shareUser = "ShareRead"
net user /add $shareUser $password /y
# TESTING WITHOUT ADDING SHARE USER TO ADMIN GROUP
#net localgroup administrators $shareUser /add /y


# CREATE FILE SHARE
$shareName = "Migrate"

$Acl = Get-Acl "C:\Users\$($user)"
$Ar = New-Object System.Security.AccessControl.FileSystemAccessRule("ShareRead", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.SetAccessRule($Ar)
Set-Acl "C:\Users\$($user)" $Acl


$Parameters = @{
    Name = $($shareName)
    Path = "C:\Users\$($user)"
    FullAccess = $($shareUser)
}

New-SmbShare @Parameters

Write-Host "Created SMB share $($shareName) at path C:\Users\$($user)"
Write-Host "Added account $($shareUser) to $($hostname)\$($shareName) full control permissions"


# CONSTRUCT XML

$xmlString = @"
<Config>
<Hostname>$hostname</Hostname>
<SerialNumber>$serialNumber</SerialNumber>
<OSVersion>$OSVersion</OSVersion>
<InstalledMemory>$memory</InstalledMemory>
<ShareName>$shareName</ShareName>
<ShareUser>$shareUser</ShareUser>
<SharePassword>$password</SharePassword>
<Disk>
<TotalStorage>$totalDiskSize</TotalStorage>
<FreeStorage>$freeDiskSpace</FreeStorage>
</Disk>
<Locations>
$xmlLocations</Locations>
<Applications>
$allApps</Applications>
<MappedDrives>
$allDrives</MappedDrives>
<Printers>
$allPrinters</Printers>
</Config>
"@

# INSTALL AZ STORAGE MODULE FOR BLOB
Write-Host "Checking for NuGet Package provider and Azure Storage module..."
$nuget = Get-PackageProvider -Name NuGet


if(-not($nuget))
{
    try {
        Write-Host "Package Provider NuGet not found - installing now..."
        Install-PackageProvider -Name NuGet -Confirm:$false -Force
        Write-Host "NuGet installed"
    }
    catch {
        $message = $_
        Write-Host "Error installing NuGet: $message"
    }
} 
else 
{
    Write-Host "Package Provider NuGet already installed."
}

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

$azStorage = Get-InstalledModule -Name Az.Storage

if(-not($azStorage))
{
    try {
        Write-Host "Az.Storage module not found - installing now..."
        Install-Module -Name Az.Storage -Force
        Write-Host "Az.Storage installed."
        Import-Module Az.Storage
        Write-Host "Az.Storage imported."        
    }
    catch {
        $message = $_
        Write-Warning "Error installing AzStorage module: $message"
    }
} 
else 
{
    Write-Host "Az.Storage module already installed."
    try {
        Import-Module Az.Storage
        Write-Host "Az.Storage imported."    
    }
    catch {
        $message = $_
        Write-Warning "Error importing AzStorage module: $message"
    }
}


# CONNECT TO BLOB STORAGE
$storageAccountName = "<Azure Storage Account Name>"
$storageAccountKey = "<Azure Storage Account Key>"
$context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
$container = "<container name>"

Write-Host "Connecting to Azure blob storage account $($storageAccountName)..."

# EXPORT XML FILE TO BLOB STORAGE

$filePath = "$($localPath)\$($hostname)-$($user).xml"
$xmlString | Out-File -FilePath $filePath
$blobName = $hostname + "-" + $user + ".xml"
Set-AzStorageBlobContent -File $filePath -Container $container -Blob $blobName -Context $context -Force
Write-Host "Uploaded XML file to blob storage"

Stop-Transcript
