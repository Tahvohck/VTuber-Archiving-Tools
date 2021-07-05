[cmdletbinding(DefaultParameterSetName="LiveOn")]
param(
	[Parameter(Mandatory=$true, Position=0)]
	$URL,

	[Parameter(Mandatory=$true, ParameterSetName="LiveOn")]
	[DateTime]$LiveOn,

	[Parameter(Mandatory=$true, ParameterSetName="StartsIn")]
	[Timespan]$StartsIn,
	
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
	Write-host "Starts on: $LiveOn (DateTime)"
} else {
	$LiveOn = [Datetime]::Today
	$LiveOn = $LiveOn.AddHours([DateTime]::Now.Hour).AddMinutes([DateTime]::now.Minute)
	$LiveOn = $LiveOn.Add([TimeSpan]$StartsIn)
	Write-host "Starts on: $LiveOn (Timespan)"
}
Write-Host "Lead Time: $LeadTime minutes"
Write-Host "URL: $URL"
Write-Host "Config: $ConfigFileInfo"

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
