<#
.SYNOPSIS
	Get a RESTful API request and wrap it in a uniform PSCustomObject.
#>
function Get-APIRequest {
	param(
		#URI to reach out to.
		[Parameter(Mandatory=$true, Position=0)][String]$URI,
		[Hashtable]$Parameters = $null,
		# Do not write errors to console.
		[Switch]$Quiet
	)
	$tmp = [PSCustomObject]@{
		success = $false
		data = $null
		error = $null
	}

	try {
		if ($Parameters -ne $null) {
			$URIParamArray = [Collections.ArrayList]::new()
			Write-Debug "Generating param string"
			foreach ($k in $Parameters.Keys) {
				$null = $URIParamArray.Add("$k=$($Parameters[$k])")
			}
			$PString = "?" + [String]::Join('&', $URIParamArray.ToArray())
			Write-Debug "Param string is: $PString"
		}
		Write-Debug "Calling REST Method"
		$tmp.data = Invoke-RestMethod -ea Stop ($URI + $PString)
	} catch [Net.Http.HttpRequestException] {
		Write-Debug "REST Method complete with exception"
		$tmp.error = [PSCustomObject]@{
			Message = $_.ErrorDetails.Message
			Status = $_.Exception.Response.StatusCode
			Exception = $_.Exception
		}
		try {
			$tmp.data = $tmp.error.Message | ConvertFrom-Json -ea Stop
		} catch {}
	} catch [Net.WebException] {
		Write-Debug "REST Method complete with serious exception. Trying to reconstruct payload"
		$tmp.error = [PSCustomObject]@{
			Message = $_.Exception.Message
			Exception = $_.Exception
		}
		$reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
		$reader.BaseStream.Position = 0
		$reader.DiscardBufferedData()
		$tmp.data = $reader.ReadToEnd() | ConvertFrom-Json
	} catch {
		Write-Debug "REST Method in unknown state, probably failed."
		$tmp.error = [PSCustomObject]@{
			Message = "Error retreiving URL: $URI`n$($_.Exception.Message)"
			Exception = $_.Exception
		}
	}

	$tmp.success = $null -eq $tmp.error
	if (!$tmp.success -and !$Quiet) {
		Write-Host -Fore Red $tmp.error.message.Trim()
	}
	return $tmp
}


<#
.SYNOPSIS
	Helper function that takes a header string and any other object, then applies proper spacing between them.
#>
function Write-HostWithSpacedHeader {
	param (
		[Parameter(Mandatory=$true, Position=0)]
		[String]$Header,
		[Parameter(Mandatory=$true, Position=1)]
		$Obj,
		[int]$HeaderSize = -15
	)
	Write-Host ([String]::Format("{0,$HeaderSize} {1}",
		$Header, $Obj
	))
}


<#
.SYNOPSIS
	Writes the message with a timestamp and in cyan color.
#>
function Write-Notable {
	param (	[string]$message )
	Write-Host -Fore Cyan ("[{0:yyyy-MM-dd HH:mm}] {1}" -f @(
		[datetime]::Now.ToLocalTime(),
		$message
	))
}


<#
.SYNOPSIS
	Helper function that truncates a string.
#>
function Truncate-String {
	param (
		[Parameter(Mandatory=$true, Position=0)]
		[String]$Str,
		[Parameter(Mandatory=$true, Position=1)]
		[int]$MaxLength = 50
	)
	if ($Str.Length -lt $MaxLength) {
		return $Str
	} else {
		return $Str.Substring(0, $MaxLength)
	}
}
