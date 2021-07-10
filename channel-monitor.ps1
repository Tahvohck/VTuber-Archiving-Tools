param(
	[Parameter(Mandatory=$true, Position=0)]
	[String]$ChannelID,

	[Switch]$AskWhichToDownload,
	[Switch]$IncludeOngoing,
	[Switch]$MonitorChannel,
	[int]$MonitorWaitTime = 60,
	[int]$LeadTime = 5,
	[int]$SecondsBetweenRetries = 15,

	[string]$ConfigPath = "default.cfg",
	[Switch][bool]$ForceYTDL = $False
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
# Prechecks
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
			Object = [string]::format( "[{0,3:d}] {1} {2} {3}",
				$optionIDX,
				([DateTime]$video.available_at).ToString("yyyyMMdd HH:mm"),
				$video.id,
				$title
			)
		}
		if ($video.status -eq "live") { 
			$args.ForeGround = "Yellow" 
		}

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

$InfoString = "{0,-12} {1}"
Write-Host ([String]::Format($infoString, "Channel",	$selectedVideo.channel.name))
Write-Host ([String]::Format($infoString, "Video",		$selectedVideo.title))
Write-Host ([String]::Format($infoString, "Starts",		([DateTime]$selectedVideo.available_at)))
Write-Host ([String]::Format($infoString, "Lead Time",	"$LeadTime minutes"))
