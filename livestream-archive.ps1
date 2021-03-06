[cmdletbinding(DefaultParameterSetName="LiveOn")]
param(
	[Parameter(Mandatory=$true, Position=0)]
	$URL,

	[Parameter(Mandatory=$true, ParameterSetName="LiveOn")]
	[DateTime]$LiveOn,

	[Parameter(Mandatory=$true, ParameterSetName="StartsIn")]
	[TimeSpan][string]$StartsIn,
	
	[int]$LeadTime = 5,
	[int]$SecondsBetweenRetries = 15,
	[string]$ConfigPath = "default.cfg",
	[Switch][bool]$ForceYTDL = $False
)
$BootPath = (Get-Item $PSCommandPath).Directory.Fullname
Push-Location $BootPath

$waitingtime = $LiveOn - [DateTime]::Now
$fstring = "dd\ \d\a\y\s\ hh\:mm\:ss"

####################
# Prechecks
$ytdl = gcm yt-dlp -ea SilentlyContinue
if ($ytdl -eq $null -or $ForceYTDL) {
	if (-not $ForceYTDL) { Write-Host -Fore Cyan "Could not find YT-DLP, falling back to YT-DL"	}
	$ytdl = gcm youtube-dl -ea SilentlyContinue
}
if ($ytdl -eq $null) {
	Write-Host -Fore Red "YT-DL could not be found! Make sure it's on the PATH"
	return
}

$ConfigFileInfo = [IO.FileInfo][IO.Path]::Combine($pwd, $ConfigPath)
if (!$ConfigFileInfo.Exists){
	Write-Host -Fore Red "Couldn't find YT-DL config file $ConfigFileInfo"
	return
}

####################
# wait loop
if ($LiveOn) {
	$Mode = "DateTime"
} else {
	$LiveOn = [Datetime]::Today
	$LiveOn = $LiveOn.AddHours([DateTime]::Now.Hour).AddMinutes([DateTime]::now.Minute)
	$LiveOn = $LiveOn.Add([TimeSpan]$StartsIn)
	$Mode = "TimeSpan"
}

Write-host "Starts on: $LiveOn ($Mode)"
Write-Host "Lead Time: $LeadTime minutes"
Write-Host "URL: $URL"
Write-Host "Config: $ConfigFileInfo"
if (($LiveOn - [datetime]::now).TotalHours -gt 24) {
	Write-Host -Fore Red "Warning: Scheduled to start more than 24h from now."
	if ($StartsIn -ne $null) {
		Write-Host -Fore Red "Try using h:m:s format if this wasn't intentional."
	}
}

Do {
	$remainingtime = $LiveOn - [datetime]::now
	Write-Progress `
		-Activity "Waiting for stream to start" `
		-Status $remainingtime.ToString($fstring)
	sleep 1
} while ($remainingtime.TotalSeconds -gt ($LeadTime * 60))

####################
# Download loop
Do {
	& $ytdl --config-location "$ConfigFileInfo" `
		"$URL"
	$Downloaded = $?
	sleep $SecondsBetweenRetries
} while (!$Downloaded)
Pop-Location
