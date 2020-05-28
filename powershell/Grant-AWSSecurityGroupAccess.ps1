param(
    [Alias("se")]
    [string] $sessionName = "awsDefaultSession",

    [Alias("f")]
    [string] $serviceFamily = "",

    [Alias("ft")]
    [string] $serviceFamilyTagName = "service-family",

    [Alias("i")]
    [string] $serviceId  = "",

    [Alias("it")]
    [string] $serviceIdTagName = "service-id",

    [Alias("a")]
    [string[]] $applicationNames = @(),

    [Alias("pi")]
    [switch] $publicIp = $false,

    [Alias("d")]
    [switch] $debug = $false,

    [Alias("h")]
    [switch] $help = $false
)

if ($help) {
	Write-Output "`t aws_create_vpc.ps1 will configure an existing ECS cluster tagged as part of the service family to run a new instance of the service, or create a new cluster if none exist already"
	Write-Output "`t Prerequisites: Powershell"
	Write-Output "`t "
	Write-Output "`t Parameters:"
	Write-Output "`t "
	Write-Output "`t serviceFamily"
	Write-Output "`t     The name of the service family."
	Write-Output ("`t     Default: {0}" -f $serviceFamily)
    Write-Output "`t     Alias: sf"
	Write-Output "`t     Example: ./aws_grant_mssql.ps1 -serviceFamily database-hosting"
    Write-Output "`t     Example: ./aws_grant_mssql.ps1 -s database-hosting"
	
    Write-Output "`t "
	Write-Output "`t serviceFamilyTagName"
	Write-Output "`t     The name of the tag that stores the service family name"
	Write-Output ("`t     Default: {0}" -f $serviceFamilyTagName)
    Write-Output "`t     Alias: t"
	Write-Output "`t     Example: ./aws_grant_mssql.ps1 -serviceFamilyTagName service-family"
    Write-Output "`t     Example: ./aws_grant_mssql.ps1 -t service-family"

    Write-Output "`t "
	Write-Output "`t serviceId"
	Write-Output "`t     The name of the tag that stores the service family name"
	Write-Output ("`t     Default: {0}" -f $serviceId)
    Write-Output "`t     Alias: si"
	Write-Output "`t     Example: ./aws_grant_mssql.ps1 -serviceId s1234567"
    Write-Output "`t     Example: ./aws_grant_mssql.ps1 -i s1234567"

    Write-Output "`t "
	Write-Output "`t serviceIdTagName"
	Write-Output "`t     The name of the tag that stores the service id"
	Write-Output ("`t     Default: {0}" -f $serviceIdTagName)
    Write-Output "`t     Alias: ti"
	Write-Output "`t     Example: ./aws_grant_mssql.ps1 -serviceIdTagName service-id"
    Write-Output "`t     Example: ./aws_grant_mssql.ps1 -ti service-id"

    Write-Output "`t "
	Write-Output "`t debug"
	Write-Output "`t     If set, a transcript of the session will be recorded."
	Write-Output ("`t     Default: {0}" -f $debug)
    Write-Output "`t     Alias: ti"
	Write-Output "`t     Example: ./aws_grant_mssql.ps1 -serviceIdTagName service-id"
    Write-Output "`t     Example: ./aws_grant_mssql.ps1 -ti service-id"

    return
}

# Prompt for name if not specified
if ($serviceFamily -eq "") {
	$serviceFamily = Read-Host "Enter the name of the service family"
}
$serviceFamily = $serviceFamily.ToLower()

# Prompt for name if not specified
if ($serviceFamilyTagName -eq "") {
	$serviceFamilyTagName = Read-Host "Enter the name of the tag that contains the service family in your environment"
}
$serviceFamilyTagName = $serviceFamilyTagName.ToLower()

# Prompt for name if not specified
if ($serviceId -eq "") {
	$serviceId = Read-Host "Enter the value of the service id"
}
$serviceId = $serviceId.ToLower()

# Prompt for name if not specified
if ($serviceIdTagName -eq "") {
	$serviceIdTagName = Read-Host "Enter the name of the tag that contains the service id in your environment"
}
$serviceIdTagName = $serviceIdTagName.ToLower()

# Prompt for name if not specified
if ($applicationNames -eq "") {
	$applicationNames = Read-Host "Enter the name of the application"
}
$applicationNames = $applicationNames.ToLower()

# Check for public IP
$ipAddresses = @()
if ($publicIp) {
	$ipAddress = (Invoke-WebRequest -Uri "api.ipify.org").Content
    $ipAddresses += $ipAddress
} else {
    $ipAddresses = (Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred | ? { $_.IpAddress -NotLike "169.254*" -and $_.IpAddress -notlike "127*" }).IPAddress
}

# navigate to library root
cd $PSScriptRoot

# load necessary modules
.\import-required-modules.ps1

if($debug) {
    $DebugPreference = "Continue"
    $transcriptName = ("aws_grant_mssql-{0}.txt" -f [DateTimeOffset]::Now.ToUnixTimeSeconds())
    Start-Transcript -Path $transcriptName

    $serviceFamily
    $serviceFamilyTagName
    $serviceId
    $serviceIdTagName
	$applicationNames
}

# Retrieve specified AWS STS session
$globalSession = $null
$expression = ("`$globalSession = `$global:{0}" -f $sessionName)
Invoke-Expression -Command $expression

# If the session is null, return false
if($globalSession -eq $null) {
    Write-Output ("`t Failed to retrieve specified AWS session.")
    if($debug) {
        Stop-Transcript
    }

    return $false
}

# Creating session hashtable for parameter splatting
$session = @{
    'AccessKey'    = $globalSession.AccessKeyId;
    'SecretKey'    = $globalSession.SecretAccessKey;
    'SessionToken' = $globalSession.SessionToken;
}

Write-Debug "`t Building environment tags..."
$hash = @{Key="Name"; Value=$serviceFamily}
$nameTag = [PSCustomObject]$hash
Write-Debug $nameTag

$hash = @{Key=$serviceFamilyTagName; Value=$serviceFamily}
$serviceTag = [PSCustomObject]$hash
Write-Debug $serviceTag

$hash = @{Key=$serviceIdTagName; Value=$serviceId}
$serviceIdTag = [PSCustomObject]$hash
Write-Debug $serviceIdTag

$hash = @{Key="management-mode"; Value="automatic"}
$managementTag = [PSCustomObject]$hash
Write-Debug $managementTag

$hash = @{Key="management-task"; Value="delete"}
$managementTask = [PSCustomObject]$hash
Write-Debug $managementTask

$hash = @{Key="management-task-data"; Value=("{0}" -f [DateTimeOffset]::Now.AddHours(12).ToUnixTimeSeconds())}
$managementData = [PSCustomObject]$hash
Write-Debug $managementData

foreach($applicationName in $applicationNames) {
	Write-Debug "`t Building tag filters and retrieving tags..."
	$filters = @()
	$filter = New-Object -TypeName Amazon.EC2.Model.Filter
	$filter.Name = "resource-type"
	$filter.Values.Add("security-group")
	$filters += $filter

	$filter = New-Object -TypeName Amazon.EC2.Model.Filter
	$filter.Name = "tag:application"
	$filter.Values.Add($applicationName)
	$filters += $filter
	$securityGroupTags = Get-EC2Tag -Filter $filters @session

	$filter = New-Object -TypeName Amazon.EC2.Model.Filter
	$filter.Name = ("tag:{0}" -f $serviceFamilyTagName)
	$filter.Values.Add($serviceFamily)
	$serviceFamilyTags = Get-EC2Tag -Filter $filter @session

	$filter = New-Object -TypeName Amazon.EC2.Model.Filter
	$filter.Name = ("tag:{0}" -f $serviceIdTagName)
	$filter.Values.Add($serviceId)
	$serviceIdTags = Get-EC2Tag -Filter $filter @session

	if($securityGroupTags -eq $null -or $serviceFamilyTags -eq $null -or $serviceIdTags -eq $null) {
		Write-Debug "`t No security group matches all necessary criteria."
		if($debug){Stop-Transcript}
		return
	}

	Write-Debug "`t Creating management-task instructions..."
	$managementTaskHash = @{"management-task"="delete"; data=("{0}" -f [DateTimeOffset]::Now.AddHours(12).ToUnixTimeSeconds())}
	$managementTask = [PSCustomObject]$managementTaskHash
	$managementTask = ($managementTask | ConvertTo-Json -Depth 5 -Compress)

	Write-Debug "`t Verifying resource ID's match across all filters..."
	foreach($sgt in $securityGroupTags) {
		$sg = $null
		if($serviceFamilyTags.ResourceId.Contains($sgt.ResourceId) -and $serviceIdTags.ResourceId.Contains($sgt.ResourceId)) {
			$sg = (Get-EC2SecurityGroup -GroupId $securityGroupTags.ResourceId @session)
		}

		if($sg -eq $null) {
			Write-Debug "`t Mismatch of sg ID's across tag searches"
		} else {
			Import-Csv WSU_ServicePorts.csv | ForEach-Object {
				if($_.ApplicationName -eq $applicationName) {
					foreach($ip in $ipAddresses) {
						$ipRange = New-Object -TypeName Amazon.EC2.Model.IpRange
						$ipRange.CidrIp = ("{0}/32" -f $ip)
						$ipRange.Description = ("json={0}" -f [System.Web.HttpUtility]::HtmlEncode($managementTask))
						Write-Debug $ipRange

						Write-Debug "`t Building security group ingress rule..."
						$ipPermission = New-Object -TypeName Amazon.EC2.Model.IpPermission
						$ipPermission.FromPort = $_.ApplicationPort
						$ipPermission.IpProtocol = $_.ApplicationProtocol
						$ipPermission.Ipv4Ranges = $ipRange
						$ipPermission.ToPort = $_.ApplicationPort
						Write-Debug $ipPermission

						Write-Debug "`t Applying ingress rules..."
						try{
							Grant-EC2SecurityGroupIngress -GroupId $sg.GroupId -IpPermission $ipPermission @session
						} catch {
							Write-Debug "`t Rule already exists."
						}
					}
				}
			}
		}
	}
}


if($debug) {
    Stop-Transcript
    $DebugPreference = "SilentlyContinue"
}