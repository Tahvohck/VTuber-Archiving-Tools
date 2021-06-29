Set of tools to archive vtubers. Requires FFMPEG and YOUTUBE-DL

# livestream-archive.ps1

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
