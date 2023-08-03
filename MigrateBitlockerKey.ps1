# Start and append post-migration log file
Start-Transcript -Append "C:\ProgramData\IntuneMigration\post-migration.log" -Verbose

# Write BDE Key to AAD

$BLV = Get-BitLockerVolume -MountPoint "C:"
Write-Host "Retrieving BitLocker Volume $($BLV)"
BackupToAAD-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $BLV.KeyProtector[1].KeyProtectorId
Write-Host "Backing up BitLocker Key to AAD"

#now delete scheduled task
Disable-ScheduledTask -TaskName "MigrateBitlockerKey"
Write-Host "Disabled MigrateBitlockerKey scheduled task"

Stop-Transcript