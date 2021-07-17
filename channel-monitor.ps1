<#
.SYNOPSIS
	Check a channel for upcoming live broadcasts, then wait for the broadcast for a reasonable time before trying to download it.
	NOTE: Only works for channels registered to holodex.

.DESCRIPTION
	This is a wrapper script for youtube-dl that facilitates monitoring a vtuber channel for live broadcasts and automatically downloading them when they start, with smart wait logic to avoid hammering the youtube platform and potentially getting your download rate throttled. It can be used in fully automatic mode, or ask the user when there are several upcoming broadcasts (see -Detailed help for info). It requires youtube-dl or yt-dlp to operate, and expects a config file for them named `default.cfg' in the same directory. Alternate config files may be supplied.
	It uses the holodex API to query channels for upcoming broadcasts as well as for info on the videos themselves. It should cleanly exit on any instance of the holodex API returning an error, if it does not please open an issue on the github repository.
#>
param(
	# The channel ID to search against. https://www.youtube.com/channel/<ChannelID>
	[Parameter(Mandatory=$true, Position=0)]
	[String]$ChannelID,

	# If there is more than one video ask the user which to download. Otherwise the soonest video will be downloaded.
	[Switch]$AskWhichToDownload,
	# Include currently live videos in the search.
	[Switch]$IncludeOngoing,
	# If a channel has no currently scheduled broadcasts monitor it for videos instead of exiting immediately.
	[Switch]$MonitorChannel,
	# When monitoring, the time in minutes to wait between checks.
	[int]$MonitorWaitTime = 60,
	# When waiting for a video to start, the threshold in minutes before actively checking if the video is live.
	[int]$LeadTime = 5,
	# When actively checking if the video is live, the time in seconds to wait between checks.
	[int]$SecondsBetweenRetries = 15,

	# An alternate youtube-dl config file to use. Must be a relative path.
	[string]$ConfigPath = "default.cfg",
	# If both youtube-dl and YT-DLP are installed, force the use of youtube-dl.
	[Switch]$ForceYTDL = $False
)
$BootPath = (Get-Item $PSCommandPath).Directory.Fullname
Push-Location $BootPath

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
# Helper functions
function Get-APIRequest {
	param($URI)
	try {
		$data = irm $uri
		return $data
	} catch [Net.WebException] {
		Write-Host -Fore Red $_.Exception.Message
		$reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
		$reader.BaseStream.Position = 0
		$reader.DiscardBufferedData()
		$resp = ($reader.ReadToEnd() | ConvertFrom-Json)
		$resp
		Exit
	} catch {
		Write-Host -Fore Red "Error retreiving URL: $URI"
		Write-Host -Fore Red $_.Exception.Message
		$_
		Exit
	}
}

# Check that channel is in Holodex
$channel = Get-APIRequest "https://holodex.net/api/v2/channels/$ChannelID"

# Check channel for upcoming broadcasts.
do {
	$videos = Get-APIRequest (
		"https://holodex.net/api/v2/live?status=live,upcoming" +
		"&channel_id=$ChannelID" 
	) | ?{ $IncludeOngoing -or $_.status -eq "upcoming" }
	
	$noUpcoming = $videos.Length -eq 0
	if ($noUpcoming -and !$MonitorChannel) {
		Write-Host -Fore Red "$($channel.name) has no scheduled broadcasts."
		return
	} elseif ($noUpcoming) {
		Write-Progress "Waiting for videos (polling every $MonitorWaitTime minutes)"
		sleep ($MonitorWaitTime * 60)
	}
} while ($noUpcoming)

# Pick video if user wants to.
if ($AskWhichToDownload -and $videos.length -gt 1) {
	$optionIDX = 0
	foreach ($video in $videos) {
		$title = if ($video.title.length -gt 50) { $video.title.Substring(0,50) }
			else { $video.title }
		$args = @{
			Object = [string]::format( "[{0,3:d}] {3} {1} {2}",
				$optionIDX, $video.id, $title,
				$video.available_at.ToLocalTime().ToString("yyyyMMdd HH:mm")
			)
		}
		if ($video.status -eq "live") { $args.ForeGround = "Yellow" }

		Write-Host @args
		$optionIDX += 1
	}

	# Only allow good choices
	do {
		[int]$choice = Read-Host "Select Video"
		$validChoice = ($choice -lt $optionIDX) -and ($choice -ge 0)
		if (!$validChoice) { Write-Host "Option $choice not valid." }
	} while (!$validChoice)

	$selectedVideo = $videos[$choice]
} else {
	$selectedVideo = $videos[0]
}

# Print current video and configuration
$InfoString = "{0,-12} {1}"
Write-Host ([String]::Format($infoString, "Channel",	$selectedVideo.channel.english_name))
Write-Host ([String]::Format($infoString, "Video",		$selectedVideo.title))
Write-Host ([String]::Format($infoString, "Starts",		$selectedVideo.available_at.ToLocalTime()))
Write-Host ([String]::Format($infoString, "Config",		$ConfigFileInfo))
Write-Host ([String]::Format($infoString, "Lead Time",	"$LeadTime minutes"))

# Wait loop setup
$fstring = "dd\ \d\a\y\s\ hh\:mm\:ss"
$StartTime = $selectedVideo.available_at.ToLocalTime()
$remainingTime = $StartTime - [DateTime]::Now
$recalcTimes = @($LeadTime, ($LeadTime * 2), ($LeadTime * 4), ($LeadTime * 8), ($LeadTime * 16), ($LeadTime * 32))
$recalcIDX = $recalcTimes.Length - 1

# Skip any check times less than current time remaining.
while ($remainingTime.TotalMinutes -lt $recalcTimes[$recalcIDX]) {
	$recalcIDX -= 1
	if ($recalcIDX -eq 0) {break}
}

do {
	if ($selectedVideo.status -eq "live") { break }

	$remainingTime = $StartTime - [DateTime]::Now
	if ($remainingTime.TotalMinutes -lt $recalcTimes[$recalcIDX]) {
		Write-Host "Rechecking start time... " -NoNewLine
		$selectedVideo = Get-APIRequest "https://holodex.net/api/v2/live?id=$($selectedVideo.id)"
		$StartTime = $selectedVideo.available_at.ToLocalTime()
		$remainingTime = $StartTime - [DateTime]::Now
		if ($recalcIDX -gt 0)	{ $recalcIDX -= 1 }
		else					{ $recalcIDX = 0 }
		Write-Host $StartTime
	}
	$ready = $remainingTime.TotalMinutes -lt $LeadTime
	Write-Progress `
		-Activity "Waiting for stream to start. Verifying start time at $($recalcTimes[$recalcIDX]) minutes" `
		-Status $remainingtime.ToString($fstring)
	sleep 1
} while (!$ready)


####################
# Download loop
Do {
	& $ytdl --config-location "$ConfigFileInfo" `
		"https://youtu.be/$($selectedVideo.id)"
	$Downloaded = $?
	sleep $SecondsBetweenRetries
} while (!$Downloaded)
Pop-Location
