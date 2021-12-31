Param(
	$FinalCurrency = "JPY",
	$DonationDirectory,
	$ExtraAltsMatrix,

	[ValidateRange(1, [Int]::MaxValue)]
	[int]$LeaderboardSize = 5,
	[ValidateRange(1, [float]::MaxValue)]
	[float]$RegularDonatorThreshold = 1,
	[int]$RegularDonatorMinumDays = 10,
	[ValidateRange(0,1)]
	[float]$EstimatedCompanyCut = -1,

	[DateTime]$StartDate = [DateTime]::MinValue,
	[DateTime]$EndDate = [DateTime]::MaxValue,

	[String]$APIKey,
	[String]$CacheFilename = "conversion_cache.json",

	[switch]$Anonymize,
	[switch]$ForceCachedData,
	[switch]$HideTopAmounts,
	[Alias("DuplicateCheckMode")]
	[switch]$KeepYTIDKeys,
	[switch]$ShowTopCurrencies,
	[switch]$ShowTopDonators,
	[switch]$TestConversion,
	[switch]$PassThru
)
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
. "$ScriptPath/common-functions.ps1"

# Globals
$AggregateDonations = @{}
$AggregateCurrencies = @{}
$donation_list = [Collections.ArrayList]::new() 
$donators = [Collections.ArrayList]::new()
$regularDonators = [Collections.ArrayList]::new()

$FirstDonoDate = [DateTime]::MaxValue
$LastDonoDate = [DateTime]::MinValue
$TotalIncomeToDate = 0
$NumberOfStreams = 0
$NumberOfMonetizedStreams = 0
$FinalCurrency = $FinalCurrency.ToUpper()

$AltsMatrix = [collections.arraylist]@(
	@(	# Simulanze
		"UCDCHb-nyY8DXox9TIobHdSQ","UCM0Jyw5uzzq2bfIrALIimGg","UCw2kiianOn1uHm1rXiDOfOw","UC2vD9YRQsG6HI1ogconz9zw",
		"UCZPhNzwpn4GXw9yHBmzZIvQ"
	),
	@(	# Wall-E
		"UC1yTFaabaq5xARIKiRc-Gxg","UCvy_H0tph_D0s8WfyMOXrOw","UCLUbKlAUlLQSELFPjSOZ4aA"
	),
	@(	# Bucket
		"UCKPR6yTobtggJLU8x1Fd9Zg","UCbAYBuoexzkLjCSDXCmOlpw"
	),
	@(	# LC_Lapen
		"UC9RB4WfKOeqXVpqu-WW9xsw","UC-w49_y6xgAKbb2H9oEj3cw"
	),
	@(	# Lord Revan (High likelyhood alts only)
		"UCpVx-y2HTqen1d6pTIfzcDA","UCwKVhK4VC2AYqFgMOq-i2gg"
	),
	@(	# Takashi隆
		"UCjbfykBMumMtRGGLqs03tlQ","UC6FNWcOx1CWtvrgGVvEXjDQ","UCxhXozeebjyi3Rf4Bw2zpLA","UCb76m56_aJCpZBbaux87TsA"
	),
	@(	# Some dude on Botan's streams
		"UC_j2MhWR7RLDsM1FOZygV6g","UCqxApYhQx3FcH5QjjfzOI5w","UC7M3MYrlix9zfoIlmCItLCQ"
	)
)
if ($null -ne $ExtraAltsMatrix) {
	if ($ExtraAltsMatrix[0][0].GetType() -eq [char]) {
		Write-Host "Buffering EAM"
		$tmp = [Collections.ArrayList]::new()
		$tmp.Add(@($ExtraAltsMatrix)) | Out-Null
		$ExtraAltsMatrix = $tmp
	}
	if ($ExtraAltsMatrix[0][0].GetType() -ne [String] -or $ExtraAltsMatrix[0].Count -lt 2)  {
		Write-Host -Fore Red "ExtraAltsMatrix must be a matrix of YTID strings. Each inner array is a list of equivalent alts."
		Write-Host -Fore Red 'If you only have one list of alts, you can specify the matrix as @($AltArray,@())'
		Exit
	}
	foreach($altArray in $ExtraAltsMatrix) {
		if ($altArray.Count -eq 0) { continue } #Skip empties
		$AltsMatrix.Add($altArray) | Out-Null
	}
}

# Get exchange data
$DualConvertMode = $false
$api = "https://api.currencyscoop.com/v1"
$apiname = "https://currencyscoop.com"
if ("" -eq $APIKey -or $ForceCachedData) {
	if (!$ForceCachedData) {
		Write-Host -Fore Red "No API key supplied. We'll try to use a local copy of the conversion data."
		Write-Host -Fore Red "You should go get an API key from $apiname if you weren't expecting this."
	}
	$DualConvertMode = $true
} else {
	Write-Host "API key [$APIKey]"
	try {
		$ConversionsRaw = Invoke-RestMethod "$api/latest?api_key=$APIKey&base=$FinalCurrency" -ErrorVariable RESTFAIL
		# Don't incur an API hit if the final destination matches our always-hit of JPY
		if ($FinalCurrency -eq "JPY") {
			$ConversionsRawJPY = $ConversionsRaw
		} else {
			$ConversionsRawJPY = Invoke-RestMethod "$api/latest?api_key=$APIKey&base=JPY" -ErrorVariable RESTFAIL
		}
		if ($null -eq $ConversionsRaw.response.rates."$FinalCurrency") {
			Write-Host -Fore Red "Currency [$FinalCurrency] not supported by currency conversion API"
			Exit
		}
	} catch {
		$RESTFAIL = $RESTFAIL.Message | ConvertFrom-Json
		Write-Host -Fore Red $RESTFAIL.meta.message
		$DualConvertMode = $true
	}
}

$CCFile = Get-Item $CacheFilename -ea SilentlyContinue
if ($null -eq $CCFile) {
	if ($DualConvertMode) {
		Write-Host -Fore Red "Unable to find cached conversion data and API is unreachable (did you supply a key?)"
		exit
	}
	$CachedConversions = @{}
} else {
	$CachedConversions = Get-Content $CacheFilename | ConvertFrom-Json -AsHashtable
}
if ($ConversionsRaw.meta.code -eq 200) {	$CachedConversions[$FinalCurrency] = $ConversionsRaw.response.rates }
if ($ConversionsRawJPY.meta.code -eq 200) {	$CachedConversions["JPY"] = $ConversionsRawJPY.response.rates }
if ($ConversionsRaw.meta.code -eq 200 -or $ConversionsRawJPY.meta.code -eq 200) {
	# Write the cache file if either request succeeded.
	$CachedConversions | ConvertTo-Json | Out-File $CacheFilename
}

if ($null -eq $CachedConversions[$FinalCurrency]) {
	Write-Host -Fore Red "Currency conversions for [$FinalCurrency] unable to be found."
	Exit
}

# Set up and start stopwatch
$StopWatch = [Diagnostics.StopWatch]::New()
$StopWatch.Start()
# Read data files
try {
	if ($null -ne $DonationDirectory) {
		$logs = @()
		foreach ($location in $DonationDirectory) {
			push-location $location -ea Stop
			Write-Host -Fore Cyan "Reading donations from $location"
			$logs += get-childItem donations*.json
			pop-location
		}
	} else {
		Write-Host -Fore Cyan "Reading donations"
		$logs = get-childItem donations*.json
	}
} catch {
	Write-Host -Fore Red "Could not move to donation directory. Exiting."
	exit
}
foreach ($log in $logs) {
	$LogHasADono = $false
	$json = get-content $log | convertfrom-json
	foreach($message in $json) {
		$LogHasADono = $true
		$donation = @{
			donator =		$message.author.id
			donatorName =	$message.author.name
			currency =		$message.money.currency
			amount =		$message.money.amount
			timestamp = [datetimeoffset]::FromUnixTimeMilliseconds($message.timestamp/1000).LocalDateTime
			USD_Equivalent = 0
		}

		# Fix non-TLA currency types
		$donation.currency = $donation.currency -replace "₪","ILS"
		$donation.currency = $donation.currency -replace "₱","PHP"

		$ConversionFromJPY = $CachedConversions["JPY"][$donation.currency]
		$ConversionFromJPYtoUSD = $CachedConversions["JPY"]["USD"]
		$donation["USD_Equivalent"] = $donation.amount / $ConversionFromJPY * $ConversionFromJPYtoUSD
		
		if ($donation.timestamp -lt $StartDate -or $donation.timestamp -gt $EndDate) { continue }
		if ($ShowTopCurrencies) {
			if ($donation.currency -notin $AggregateCurrencies.Keys) {
				$AggregateCurrencies[$donation.currency] = [pscustomobject]@{
					count = 1
					amount = 0
				}
			} else {
				$AggregateCurrencies[$donation.currency].count += 1
			}
		}

		# Do some fixups here for known alts
		$donator = "$($donation.donator)"
		foreach ($altList in $AltsMatrix) {
			# Alt found, don't need to keep looking, set current donator ID to first alt for proper combination
			if($donator -in $altList) { $donator = $altList[0]; break }
		}
		$donation.donator = $donator


		if (!$donators.Contains($donation.donator)) {
			$null = $donators.Add($donation.donator)
			#$AggregateDonations[$donation.donator] = @{}
		}
		$null = $donation_list.Add([pscustomobject]$donation)
		if ($donation.timestamp -gt $LastDonoDate) { $LastDonoDate = $donation.timestamp }
		if ($donation.timestamp -lt $FirstDonoDate) { $FirstDonoDate = $donation.timestamp }
	}
	$NumberOfStreams += 1
	if ($LogHasADono) {
		$NumberOfMonetizedStreams += 1
	}
}

$NumberOfDonations = $donation_list.Count
if ($NumberOfDonations -eq 0) {
	Write-Host -Fore Red "Couldn't find any donations between $StartDate and $EndDate"
	Exit
}


# Aggregate data
Write-Host -Fore Cyan ("Aggregating Donations ({0:n0} total, {1:n0} streams)" -f $NumberOfDonations,$NumberOfStreams)
foreach($donation in $donation_list) {
	$donator = "$($donation.donator)"

	if($null -eq $AggregateDonations[$donator]) {
		$AggregateDonations[$donator] = @{}
		$AggregateDonations[$donator]['money'] = @{}
		$AggregateDonations[$donator]['nameList'] = @{}
		$AggregateDonations[$donator].earliest = [DateTime]::MaxValue
		$AggregateDonations[$donator].last = [DateTime]::MinValue

		if (!$donators.Contains($donator)){ $null = $donators.add($donator) }
	}

	$AggregateDonations[$donator].money[$donation.currency] += $donation.amount
	$AggregateDonations[$donator].donations += 1
	$AggregateDonations[$donator].nameList[$donation.donatorName] += 1
	if ($donation.timestamp -lt $AggregateDonations[$donator].earliest) {
		$AggregateDonations[$donator].earliest = $donation.timestamp
	}
	if ($donation.timestamp -gt $AggregateDonations[$donator].last) {
		$AggregateDonations[$donator].last = $donation.timestamp
	}
}

Write-Host -Fore Cyan "Eliminating duplicate data that crept in"
$ADK = $AggregateDonations.Keys
$donators = $donators | sort -unique | ?{ $_ -in $ADK }
Write-Host -Fore Cyan "Doing conversions to $FinalCurrency"
foreach($donator in $donators) {
	$donator_stats = $AggregateDonations[$donator]
	foreach($currency in @($donator_stats.money.Keys)) {
		if ($currency -eq $FinalCurrency) {
			$yen = $donator_stats.money[$currency]
		} else {
			if ($DualConvertMode) {
				# Dual conversion mode first converts it to JPY (which we always have), then to the destination currency
				$conversionRateFromJPY = $CachedConversions.JPY."$currency"
				$conversionRateFromJPYToFinal = $CachedConversions.JPY."$FinalCurrency"
				if ($null -eq $conversionRateFromJPY) {
					Write-Host -Fore Red "There's an issue with [$currency]. Treating this as 0 value"
					$conversionRate = 0
				} else {
					$conversionRate = 1 / $conversionRateFromJPY * $conversionRateFromJPYToFinal
				}
			} else {
				$conversionRate = 1 / $CachedConversions."$FinalCurrency"."$currency"
			}
			$yen = $donator_stats.money[$currency] * $conversionRate
			if ($TestConversion -and ($donator -eq "UCfnjcCpARuzFYQtYeX9kr5Q")) {
				Write-Host ("Convert {0,10:n} {1} -> {2,10:n2} $FinalCurrency`t[{3,8:F3}] {4}" -f
					$donator_stats.money[$currency],
					$currency,
					$yen,
					$conversionRate,
					$donator )
			}
		}
		$donator_stats["TOTAL"] += [Math]::Round($yen, 3)
		$TotalIncomeToDate += $yen
		if ($ShowTopCurrencies) {
			$AggregateCurrencies[$currency].amount += $yen
		}
	}
}

Write-Host -Fore Cyan "Gathering metrics"
foreach($donator in $donators) {
	$donator_stats = $AggregateDonations[$donator]
	$donator_stats["average"] = "{0:n2}" -f ($donator_stats["TOTAL"] / $donator_stats["donations"])
	$days = [Math]::Max(1, ($donator_stats["last"].Date -  $donator_stats["earliest"].Date).TotalDays)
	$donator_stats["PerDayAmount"] = [Math]::Round($donator_stats["TOTAL"] / $days, 3)
	$donator_stats["PerWeekCount"] = [Math]::Round($donator_stats["donations"] / [Math]::Ceiling($days/7), 3)
	$donator_stats["isRegularDonator"] = (
		$donator_stats["PerWeekCount"] -gt $RegularDonatorThreshold -and
		$days -gt $RegularDonatorMinumDays
	)
	$donator_stats["Name"] = $donator_stats.nameList.GetEnumerator() |
		Sort -Descending {$_.Value} |
		Select -First 1 -ExpandProperty Key
	if ($donator_stats["isRegularDonator"]) {
		# Don't need to do a presence check since we already filtered donators to uniques
		$regularDonators.Add($donator) | Out-Null
	}
	if ($KeepYTIDKeys) {
		$AggregateDonations[$donator] = [pscustomobject]$donator_stats
	} else {
		# Store the updated stats file and remove the YT ID key entry
		$AggregateDonations[$donator_stats.Name] = [pscustomobject]$donator_stats
		$AggregateDonations.Remove($donator)
	}
}

# Stop Stopwatch
$StopWatch.Stop()
# Build statistics array
$DonoDaysRange = [Math]::Ceiling(($LastDonoDate - $FirstDonoDate).TotalDays)
$Stats = [pscustomobject]@{
	Directory = if ($DonationDirectory) {gi $DonationDirectory} else {$pwd.Path}
	TimeToProcess =	$StopWatch.Elapsed
	FinalCurrency =	$FinalCurrency
	IncomeTotal =	[Math]::Round($TotalIncomeToDate, 2)
	IncomeAverage =	[Math]::Round($TotalIncomeToDate / $NumberOfDonations, 2)
	IncomePerStream =
					[Math]::Round($TotalIncomeToDate / $NumberOfStreams, 2)
	IncomePerMonetizedStream =
					[Math]::Round($TotalIncomeToDate / $NumberOfMonetizedStreams, 2)
	IncomePerDay =	[Math]::Round($TotalIncomeToDate / $DonoDaysRange, 2)
	IncomeEstimatedHourly = $null
	DateFirstDono =	$FirstDonoDate.Date
	DateLastDono =	$LastDonoDate.Date
	DateRange =		$DonoDaysRange
	DonatorAvgNumDonations =
					$NumberOfDonations / $donators.Length
	DonatorTotal =	$donators.Count
	DonatorRegulars =
					$regularDonators.Count
	NumStreams =	$NumberOfStreams
	NumMonetizedStreams =
					$NumberOfMonetizedStreams
	NumDonations =	$NumberOfDonations
}
if ($EstimatedCompanyCut -ne -1) {
	$daily = ($TotalIncomeToDate / $DonoDaysRange)
	$lessYT = $daily * (1 - 0.3)
	$lessCompany = $lessYT * (1 - $EstimatedCompanyCut)
	$hourly = $lessCompany * 7 / 40
	$Stats.IncomeEstimatedHourly = [Math]::Round($hourly, 2)
	$InfoLineHourly = "{1,10:n2} {0}`tEstimated hourly pay (less YT and company cuts)"
}

# Display final info
$InfoOutputArray = @(
	"{0,10:mm\:ss} M:S`tTime taken to process data" -f	$Stats.TimeToProcess
	"{0,10:yyyy-MM-dd}`tFirst Dono" -f			$Stats.DateFirstDono
	"{0,10:yyyy-MM-dd}`tLast Dono" -f			$Stats.DateLastDono
	"{0,10:n0} `tTotal days" -f					$Stats.DateRange
	"{1,10:n0} {0}`tTotal to date" -f			$Stats.FinalCurrency,$Stats.IncomeTotal
	"{1,10:n2} {0}`tAverage donation" -f		$Stats.FinalCurrency,$Stats.IncomeAverage
	"{1,10:n2} {0}`tPer stream" -f 				$Stats.FinalCurrency,$Stats.IncomePerStream
	"{1,10:n2} {0}`tPer stream (monetized)" -f	$Stats.FinalCurrency,$Stats.IncomePerMonetizedStream
	"{1,10:n2} {0}`tPer day since 1st dono" -f	$Stats.FinalCurrency,$Stats.IncomePerDay
	if ($InfoLineHourly) { $InfoLineHourly -f	$Stats.FinalCurrency,$stats.IncomeEstimatedHourly}
	"{0,10:n2}`tAverage donations per donator" -f
												$Stats.DonatorAvgNumDonations
	"{0,10:n0}`tUnique Donators" -f				$Stats.DonatorTotal
	"{0,10:n0}`tUnique Regular Donators" -f		$Stats.DonatorRegulars
	"Regular Donators have more than {0} donos per week over at least {1} days." -f
												$RegularDonatorThreshold,$RegularDonatorMinumDays
)
foreach($line in $InfoOutputArray) {
	if ($line) { Write-Host $line }
}

if ($ShowTopCurrencies) {
	$ShowHowMany = $LeaderboardSize
	Write-Host -Fore Cyan "Top Currencies (By count):"
	$AggregateCurrencies.GetEnumerator() | Sort {$_.Value.count} -Descending | Select -First $ShowHowMany | %{
		$PercentOfDonos = $_.Value.count / $NumberOfDonations * 100
		Write-Host ("{0,10:n3} %`t{1}" -f $PercentOfDonos,$_.Key)
	}
	Write-Host -Fore Cyan "Top Currencies (By amount):"
	$AggregateCurrencies.GetEnumerator() | Sort {$_.Value.amount} -Descending | Select -First $ShowHowMany | %{
		$PercentOfDonos = $_.Value.amount / $TotalIncomeToDate * 100
		Write-Host ("{0,10:n3} %`t{1}" -f $PercentOfDonos,$_.Key)
	}
}

if ($ShowTopDonators) {
	$ShowHowMany = $LeaderboardSize
	if ($Anonymize) {
		$DonatorFormat = "Hidden"
	} else {
		$DonatorFormat = "{2}"
	}
	if ($HideTopAmounts) {
		$AllTimeAmountFormat = " " * 6 + "???? {1}"
		$AverageAmountFormat = " " * 6 + "???? {1}"
	} else {
		$AllTimeAmountFormat = "{0,10:n0} {1}"
		$AverageAmountFormat = "{0,10:n2} {1}"
	}
	Write-Host -Fore Cyan "Top Donators (All-Time):"
	$AggregateDonations.GetEnumerator() | Sort {$_.Value.TOTAL} -Descending | Select -First $ShowHowMany | %{
		Write-Host ("$AllTimeAmountFormat`t$DonatorFormat" -f $_.Value.TOTAL,$FinalCurrency,$_.Value.Name)
	}
	Write-Host -Fore Cyan "Top Donators (Average per donation, regular donators only):"
	$AggregateDonations.GetEnumerator() | Sort {[float]$_.Value.average} -Descending | Where-Object {
		$_.Value.isRegularDonator
	} | Select -First $ShowHowMany | %{
		Write-Host ("$AverageAmountFormat`t$DonatorFormat" -f $_.Value.average,$FinalCurrency,$_.Value.Name)
	}
	Write-Host -Fore Cyan "Top Donators (Personal average 'per day', regular donators only):"
	$AggregateDonations.GetEnumerator() | Sort {$_.Value.PerDayAmount} -Descending | Where-Object {
		$_.Value.isRegularDonator
	} | Select -First $ShowHowMany | %{
		Write-Host ("$AverageAmountFormat`t$DonatorFormat" -f $_.Value.PerDayAmount,$FinalCurrency,$_.Value.Name)
	}
}
if ($PassThru) {
	$tmp = [collections.arraylist]::new()
	$tmp.add($AggregateDonations) | Out-Null
	$tmp.add($donation_list) | Out-Null
	$tmp.add($Stats) | Out-Null
	$tmp
}