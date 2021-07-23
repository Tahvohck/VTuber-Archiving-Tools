param(
	# The channel ID to search against. https://www.youtube.com/channel/<ChannelID>
	[Parameter(Mandatory=$true, Position=0)]
	[String[]]$ChannelIDs,

	# Include currently live videos in the search.
	[Switch]$IncludeOngoing,

	# When monitoring, the time in minutes to wait between checks.
	[int]$MonitorWaitTime = 60,
	# When waiting for a video to start, the threshold in minutes before actively checking if the video is live.
	[int]$LeadTime = 5,
	# When actively checking if the video is live, the time in seconds to wait between checks.
	[int]$SecondsBetweenRetries = 15,

	# An alternate youtube-dl config file to use. Must be a relative path.
	[string]$ConfigPath = "default.cfg",
	# If both youtube-dl and YT-DLP are installed, force the use of youtube-dl.
	[Switch]$ForceYTDL
)


####################
# Internal functions
function Monitor-Channel {
	param([String]$channel)
}

function WaitFor-Video {
	param([String]$videoID)
}

function Download-Video {
	param([String]$videoID)
}


####################
# Prechecks/Warmup
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
Push-Location $ScriptPath

$ytdl = gcm yt-dlp -ea SilentlyContinue
if ($ytdl -eq $null -or $ForceYTDL) {
	if (-not $ForceYTDL) {
		Write-Host -Fore Cyan "Could not find YT-DLP, falling back to YT-DL"
	}
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

$ValidChannels = foreach ($CID in $ChannelIDs) {
	$chanData = Get-APIRequest -Quiet "https://holodex.net/api/v2/channels/$CID"
	if (!$chanData.success) {
		if ($chanData.data.Message -ne $null) {
			Write-Host -Fore Red "$CID`: $($chanData.data.Message)"
		} else {
			Write-Host -Fore Red "$CID`: $($chanData.error.Message)"
		}
		continue
	}
	Write-Host "Found channel to monitor: $($chanData.data.name)"
	$chanData.data
}

####################
# Main loop
Write-Host "Beginning to monitor. Press Q to quit."
do {
	# Check if user requested quit
	if ([Console]::KeyAvailable) {
		$key = [Console]::ReadKey($true)
		$UserQuit = $key.key -eq "Q"
		Write-Host "Exiting..."
	}
} while (!$UserQuit)
