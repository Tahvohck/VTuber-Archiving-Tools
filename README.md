Set of tools to archive vtubers. Requires FFMPEG and YOUTUBE-DL. If the webp tool DWEBP is on your PATH, can also convert webp images into PNG when extracting songs.

# channel-monitor.ps1
Powershell script for scheduling a livestream download using the holodex API. Preferred over `livestream-archive.ps1` because it'll handle all the setup for you. Documentation is baked into the file, use `get-help ./channel-monitor.ps1` to see it.
# multi-channel-monitor.ps1
Powershell daemon script for monitoring multiple channels at one time. Uses `start-job` to download in the background. REQUIRES the support file `common-functions.ps1`. Supports regex title matching (case insensitive) in order to limit the downloads to only certain videos (for example, singing streams). Just like `channel-monitor.ps1`, this uses the holodex API and so only works for channels listed on holodex.

# livestream-archive.ps1 (Deprecated)
Powershell script for scheduling a livestream download. Will wait until the window is near, then begin attempting to download the video. This prevents spamming YT's servers and getting yourself rate-limited.

Option | Mandatory | Use | Default
:----- | :-------: | --- | :-----:
URL | Y | The URL to download. |
LiveOn | Y | The timestamp that the stream starts on. |
StartsIn | Y | Alternative to LiveOn. How far in the future the stream starts. |
LeadTime | N | How many minutes before the stream to stop idling and start trying. | 5
SecondsBetweenRetries | N | How many seconds to wait before trying to download the stream again, once the idle period is up. | 15
ConfigPath | N | The path to the YT-DL configuration file you want to use. | default.cfg
# default.cfg
Config file that will be used by default for Youtube-DL. Configured for general actions and clean handling of livestreams.

# hololive-music-archive.cfg
Config file for archiving all of hololive's music. Configured for more advanced sorting and downloading, as well as a set of playlists so all 300+ videos don't need to be put in manually.

# holomusic-extract.ps1
Powershell script for converting video files into audio-only, significantly reducing stored size.
