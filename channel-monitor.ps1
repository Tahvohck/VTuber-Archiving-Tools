param(
	[Parameter(Mandatory=$true, Position=0)]
	[String]$ChannelID,
	
	[Switch]$AskWhichToDownload,
	[Switch]$IncludeOngoing,
	[Switch]$MonitorChannel,
	[int]$MonitorWaitTime = 30,
	
	[String]$APIKEY = "AIzaSyDPsHMgQV1AEJNtfHWC8FVaDeyL0vbd60A"
)

# Check channel for upcoming broadcasts.
do {
	$data = Invoke-RestMethod (
		"https://www.googleapis.com/youtube/v3/search?eventType=upcoming&type=video" +
		"&key=$APIKEY" +
		"&channelId=$channelId" 
	)
	
	$videoIDs = $data.items.id.videoId
	if ($videoIDs -eq $null -and !$MonitorChannel) {
		Write-Host -Fore Red "Channel $ChannelID has no scheduled broadcasts."
		return
	} elseif ($videoIDs -eq $null) {
		Write-Progress "Waiting for videos (polling every $MonitorWaitTime minutes)"
		sleep ($MonitorWaitTime * 60)
	}
} while ($videoIDs -eq $null)

# Get upcoming video data
$VIDString = [String]::Join(',',$videoIDs)
$part = ""
$videoData = Invoke-RestMethod (
	"https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails,snippet" +
	"&key=$APIKEY" +
	"&id=$VIDString"
)

# Process upcoming video data
$videoDataProcessed = @(foreach ($video in $videoData.items) {
	[PSCustomObject]@{
		startTimeLocalized = [DateTime]$video.liveStreamingDetails.scheduledStartTime
		channel = $video.snippet.channelTitle
		videoID = $video.id
		title = $video.snippet.title
		startTime = $video.liveStreamingDetails.scheduledStartTime
		endTime = $video.liveStreamingDetails.actualEndTime
		chatID = $video.liveStreamingDetails.activeLiveChatId
	}
}) | sort -Property "startTimeLocalized" 

# Select videos to consider
$videoDataProcessed = $videoDataProcessed | ?{
	($_.startTimeLocalized -gt [DateTime]::Now) -or
	($_.endTime -eq $null -and $IncludeOngoing)
}

# Pick video if user wants to.
if ($AskWhichToDownload -and $videoDataProcessed.length -gt 1) {
	$optionIDX = 0
	foreach ($video in $videoDataProcessed) {
		$title = if ($video.title.length -gt 50) { $video.title.Substring(0,50) }
			else { $video.title }
		$args = @{
			Object = [string]::format( "[{0,3:d}] {1} {2} {3}",
				$optionIDX,
				$video.startTimeLocalized.ToString("yyyyMMdd HH:mm"),
				$video.videoID,
				$title
			)
		}
		if ($video.startTimeLocalized -lt [DateTime]::now) { 
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

	$selectedVideo = $videoDataProcessed[$choice]
} else {
	$selectedVideo = $videoDataProcessed[0]
}

Write-Host "Channel:" $selectedVideo.channel
Write-Host "Video:  " $selectedVideo.title
Write-Host "Starts: " $selectedVideo.startTimeLocalized
