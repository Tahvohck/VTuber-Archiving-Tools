<#
.SYNOPSIS
	Get a RESTful API request and wrap it in a uniform PSCustomObject.
#>
function Get-APIRequest {
	param(
		#URI to reach out to.
		[Parameter(Mandatory=$true, Position=0)][String]$URI,
		# Do not write errors to console.
		[Switch]$Quiet
	)
	$tmp = [PSCustomObject]@{
		success = $false
		data = $null
		error = $null
	}

	try {
		Write-Debug "Calling REST Method"
		$tmp.data = Invoke-RestMethod -ea Stop $uri
	} catch [Net.Http.HttpRequestException] {
		Write-Debug "REST Method complete with exception"
		$tmp.error = [PSCustomObject]@{
			Message = $_.ErrorDetails.Message
			Status = $_.Exception.Response.StatusCode
			Exception = $_.Exception
		}
	} catch [Net.WebException] {
		Write-Debug "REST Method complete with serious exception. Trying to reconstruct payload"
		$tmp.error = [PSCustomObject]@{
			Message = $_.Exception.Message
			Exception = $_.Exception
		}
		$reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
		$reader.BaseStream.Position = 0
		$reader.DiscardBufferedData()
		$reader.ReadToEnd() | ConvertFrom-Json
	} catch {
		Write-Debug "REST Method in unknown state, probably failed."
		$tmp.error = [PSCustomObject]@{
			Message = "Error retreiving URL: $URI`n$($_.Exception.Message)"
			Exception = $_.Exception
		}
	}

	$tmp.success = $tmp.error -eq $null
	if (!$tmp.success -and !$Quiet) {
		Write-Host -Fore Red $tmp.error.message
	}
	return $tmp
}