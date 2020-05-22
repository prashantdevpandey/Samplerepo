$script:ModuleRoot = $PSScriptRoot
$script:ModuleVersion = (Import-PowerShellDataFile -Path "$($script:ModuleRoot)\PSCUCM.psd1").ModuleVersion

# Detect whether at some level dotsourcing was enforced
$script:doDotSource = Get-PSFConfigValue -FullName PSCUCM.Import.DoDotSource -Fallback $false
if ($PSCUCM_dotsourcemodule) { $script:doDotSource = $true }

<#
Note on Resolve-Path:
All paths are sent through Resolve-Path/Resolve-PSFPath in order to convert them to the correct path separator.
This allows ignoring path separators throughout the import sequence, which could otherwise cause trouble depending on OS.
Resolve-Path can only be used for paths that already exist, Resolve-PSFPath can accept that the last leaf my not exist.
This is important when testing for paths.
#>

# Detect whether at some level loading individual module files, rather than the compiled module was enforced
$importIndividualFiles = Get-PSFConfigValue -FullName PSCUCM.Import.IndividualFiles -Fallback $false
if ($PSCUCM_importIndividualFiles) { $importIndividualFiles = $true }
if (Test-Path (Resolve-PSFPath -Path "$($script:ModuleRoot)\..\.git" -SingleItem -NewChild)) { $importIndividualFiles = $true }
if ("<was compiled>" -eq '<was not compiled>') { $importIndividualFiles = $true }
	
function Import-ModuleFile
{
	<#
		.SYNOPSIS
			Loads files into the module on module import.
		
		.DESCRIPTION
			This helper function is used during module initialization.
			It should always be dotsourced itself, in order to proper function.
			
			This provides a central location to react to files being imported, if later desired
		
		.PARAMETER Path
			The path to the file to load
		
		.EXAMPLE
			PS C:\> . Import-ModuleFile -File $function.FullName
	
			Imports the file stored in $function according to import policy
	#>
	[CmdletBinding()]
	Param (
		[string]
		$Path
	)
	
	if ($doDotSource) { . (Resolve-Path $Path) }
	else { $ExecutionContext.InvokeCommand.InvokeScript($false, ([scriptblock]::Create([io.file]::ReadAllText((Resolve-Path $Path)))), $null, $null) }
}

#region Load individual files
if ($importIndividualFiles)
{
	# Execute Preimport actions
	. Import-ModuleFile -Path "$ModuleRoot\internal\scripts\preimport.ps1"
	
	# Import all internal functions
	foreach ($function in (Get-ChildItem "$ModuleRoot\internal\functions" -Filter "*.ps1" -Recurse -ErrorAction Ignore))
	{
		. Import-ModuleFile -Path $function.FullName
	}
	
	# Import all public functions
	foreach ($function in (Get-ChildItem "$ModuleRoot\functions" -Filter "*.ps1" -Recurse -ErrorAction Ignore))
	{
		. Import-ModuleFile -Path $function.FullName
	}
	
	# Execute Postimport actions
	. Import-ModuleFile -Path "$ModuleRoot\internal\scripts\postimport.ps1"
	
	# End it here, do not load compiled code below
	return
}
#endregion Load individual files

#region Load compiled code
Function ConvertTo-XMLString
{
<#
.SYNOPSIS
    Outputs a human readable simple text XML representation of a simple PS object.
.DESCRIPTION
    Outputs a human readable simple text XML representation of a simple PS object.
.PARAMETER InputObject
    The input object to inspect and dump.
.PARAMETER ObjectName
    The name of the root element in the document. Defaults to "Object"
.PARAMETER ExcludeProperty
    Optional.  Property(s) to exclude from output
.PARAMETER RootAttributes
    Optional.  Attributes to put on root element
.PARAMETER BooleanValuesAsLowercase
    Optional.  Print boolean values as lowercase instead of propercase (true vs True)
.PARAMETER DateFormat
    Optional.  DateFormat string to use for datetime properties
.PARAMETER IndentLevel
    Internal use, this is a recursive function
.PARAMETER Root
    Internal use, this is a recursive function
.EXAMPLE
    Something, somelthing

    Does something
.NOTES
    Provided by Ish__ in PowerShell Discord (https://pwsh.ca/discord): https://gist.github.com/charlieschmidt/57292a97a3a8760e4baaffba425e5010
#>
    [cmdletbinding()]
	param (
        [parameter(Mandatory=$true,valuefrompipeline=$true)]
		[object]$InputObject,
        [Parameter(Mandatory=$false)]
		[String]$ObjectName = "Object",
        [Parameter(Mandatory=$false)]
        [string[]]$ExcludeProperty,
        [Parameter(Mandatory=$false)]
        [hashtable]$RootAttributes,
        [Parameter(Mandatory=$false)]
        [switch]$BooleanValuesAsLowercase,
        [Parameter(Mandatory=$false)]
        [string]$DateFormat = "",
        [Parameter(Mandatory=$false)]
		[Int32]$IndentLevel = 1,
        [Parameter(Mandatory=$false)]
		[boolean]$Root = $true
	)
    begin
	{
        $OutputStrings = New-Object System.Collections.Generic.List[System.String]
	}
    process
    {
        $IndentString = ("`t" * $IndentLevel)

	    # Output the root element opening tag
	    if ($Root)
        {
            $RootElement = $ObjectName

            if ($RootAttributes)
            {
                foreach ($Key in $RootAttributes.Keys)
                {
                    $RootElement += " {0}=`"{1}`"" -f $Key, $RootAttributes[$Key]
                }
            }
            $OutputStrings.Add("<$RootElement>")
	    }

        # Iterate through all of the note properties in the object.
        $Properties = @()
        if ($InputObject.GetType().Name -eq "Hashtable" -or $InputObject.GetType().Name -eq "OrderedDictionary")
        {
            $Properties = $InputObject.Keys
        }
        elseif ($InputObject.GetType().Name -eq "PSCustomObject")
        {
            $Properties = Get-Member -InputObject $InputObject -MemberType NoteProperty | Select-Object -Expand Name
        }
        elseif ($InputObject.GetType().Name -eq "Boolean" -and $BooleanValuesAsLowerCase.IsPresent)
        {
            $PropertyValueString = ([string]$InputObject).ToLower()
        }
        elseif ($InputObject.GetType().Name -ieq "datetime")
        {
            $PropertyValueString = [string]($InputObject).ToString($DateFormat)
        }
        else
        {
            $PropertyValueString = $InputObject.ToString()
        }

        if ($Properties.Count -eq 0)
        {
            $OutputStrings.Add($PropertyValueString)
        }
        else
        {
            foreach ($Property in $Properties)
            {
                if ($ExcludeProperty -inotcontains $Property)
                {
                    $PropertyValue = $InputObject.($Property)

                    # Check if the property is an object and we want to dig into it
                    if ($null -eq $PropertyValue)
                    {
                        $OutputStrings.Add("$IndentString<$Property />")
                    }
                    elseif ($PropertyValue.GetType().Name -eq "PSCustomObject" -or $PropertyValue.gettype().name -eq "Hashtable" -or $PropertyValue.GetType().Name -eq "OrderedDictionary")
                    { # is object, so dig in, with wrapping xml tags
                        $OutputStrings.Add("$IndentString<$Property>")
                        $PropertyXml = ConvertTo-XMLString -InputObject $PropertyValue -Root $false -IndentLevel ($IndentLevel + 1) -DateFormat $DateFormat  -BooleanValuesAsLowercase:$BooleanValuesAsLowercase
                        $OutputStrings.Add($PropertyXml)
                        $OutputStrings.Add("$IndentString</$Property>")
                    }
                    elseif ($PropertyValue.GetType().Name.ToString().EndsWith("[]"))
                    { # is array, so get value for each element in array, then wrap total (if those were objects) or wrap individually (if they were strings/ints/etc)
                        $PropertyXml = @()
                        $SubObjectPropertyNames = @()
                        foreach ($APropertyValue in $PropertyValue)
                        {
                            $ValueIsObject = $false
                            if ($APropertyValue.gettype().name -eq "PSCustomObject" -or $APropertyValue.gettype().name -eq "Hashtable" -or $APropertyValue.GetType().Name -eq "OrderedDictionary")
                            {
                                switch ($APropertyValue.GetType().Name)
                                {
                                    "Hashtable" { $SubObjectPropertyNames += $APropertyValue.Keys }
                                    "OrderedDictionary" { $SubObjectPropertyNames += $APropertyValue.Keys }
                                    "PSObject" { $SubObjectPropertyNames += $APropertyValue.PSObject.Properties.Name }
                                    "PSCustomObject" { $SubObjectPropertyNames += $APropertyValue.PSObject.Properties.Name }
                                }
                                $ValueIsObject = $true
                            }

                            $PropertyXml += ConvertTo-XMLString -InputObject $APropertyValue -Root $false -DateFormat $DateFormat -BooleanValuesAsLowercase:$BooleanValuesAsLowercase -IndentLevel ($IndentLevel + 1)
                        }

                        $ValueIsWrapper = $false
                        if ($ValueIsObject)
                        {
                            $Ps = ($SubObjectPropertyNames | Select-Object -Unique).Count
                            if ($PS -eq 1)
                            {
                                $ValueIsWrapper = $true
                            }
                        }
                        if ($PropertyXml.Count -ne 0)
                        {
                            if ($ValueIsObject)
                            {
                                if ($ValueIsWrapper)
                                {
                                    $OutputStrings.Add("$IndentString<$Property>")
                                    $PropertyXmlString = $PropertyXml -join "`n"
                                    $OutputStrings.Add($PropertyXmlString)
                                    $OutputStrings.Add("$IndentString</$Property>")
                                }
                                else
                                {
                                    $OutputStrings.Add("$IndentString<$Property>")
                                    $PropertyXmlString = $PropertyXml -join "`n$IndentString</$Property>`n$IndentString<$Property>`n"
                                    $OutputStrings.Add($PropertyXmlString)
                                    $OutputStrings.Add("$IndentString</$Property>")
                                }
                            }
                            else
                            {
                                foreach ($PropertyXmlString in $PropertyXml)
                                {
                                    $OutputStrings.Add("$IndentString<$Property>$PropertyXmlString</$Property>")
                                }
                            }
                        }
                        else
                        {
                            $OutputStrings.Add("$IndentString<$Property />")
                        }
                    }
                    else
                    { # else plain old property
                        $PropertyXml = ConvertTo-XMLString -InputObject $PropertyValue -Root $false -DateFormat $DateFormat -BooleanValuesAsLowercase:$BooleanValuesAsLowercase -IndentLevel ($IndentLevel + 1)
                        $OutputStrings.Add("$IndentString<$Property>$PropertyXml</$Property>")
                    }
                }
            }
        }

	    # Output the root element closing tag
	    if ($Root)
        {
            $OutputStrings.Add("</$ObjectName>")
	    }
    }

    End
    {
        $OutputStrings.ToArray() -join "`n"
    }
}


function Get-PSCUCMPhoneName {
    <#
    .SYNOPSIS
    Get the Phone Name based on Directory Number
    
    .DESCRIPTION
    Get the Phone Name based solely upon the Directory Number
    
    .PARAMETER DN
    Directory Number to get a phone name of...
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMPhoneName -DN 1001

    Gets the phone name for Directory Number 1001
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $DN,
        [switch]
        $EnableException
    )
    $CucmAxlSplat = @{
        SqlQuery        = @'
            SELECT device.name
            FROM
            device, numplan, devicenumplanmap
            WHERE
            devicenumplanmap.fkdevice = device.pkid
            AND
            devicenumplanmap.fknumplan = numplan.pkid
            AND
            numplan.dnorpattern = "{0}"
'@ -f $DN
        EnableException = $EnableException
    }
    Invoke-PSCUCMSqlQuery @CucmAxlSplat
}

function Add-PSCUCMPhone {
    <#
    .SYNOPSIS
    Adds a phone to CUCM.
    
    .DESCRIPTION
    Adds a phone of the appropriate parameters to CUCM.
    
    .PARAMETER Name
    Name of the phone.
    
    .PARAMETER Product
    Phone Model.
    
    .PARAMETER DevicePoolName
    Device Pool to place phone in.
    
    .PARAMETER Protocol
    Protocol for the phone. Typically SCCP or SIP.
    
    .PARAMETER Description
    Description for the phone.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.

    .PARAMETER WhatIf
    What If?
    
    .PARAMETER Confirm
    Confirm...
    
    .EXAMPLE
    Add-Phone -Name SEP00000000000 -Product 'Cisco 6941' -DevicePoolName 'DEFAULT-DP' -Protocol SCCP

    Adds a phone to CUCM.

    #>
    
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Name,
        [Parameter(Mandatory = $true)]
        [Alias('Model')]
        [string]
        $Product,
        [Parameter(Mandatory=$true)]
        [string]
        $DevicePoolName,
        [Parameter(Mandatory = $true)]
        [string]
        $Protocol,
        [Parameter()]
        [string]
        $Description,
        [Parameter()]
        [switch]
        $EnableException
    )

    <#
         <phone>
            <name>SEP000000000000</name>
            <description>Optional</description>
            <product>?</product>
            <class>?</class>
            <protocol>?</protocol>
            <protocolSide>User</protocolSide>
            <devicePoolName uuid="?">?</devicePoolName>
         </phone>
    #>
        
    $class = 'Phone'
    
    $CucmAxlSplat = @{
        entity          = 'addPhone'
        parameters      = @{
            phone = @{
                name                  = $MacAddress
                product               = $Product
                class                 = $class
                protocol              = $Protocol
                protocolSide          = $protocolSide
                devicePoolName        = $devicePoolName
                commonPhoneConfigName = $commonPhoneConfigName
                locationName          = $locationName
                useTrustedRelayPoint  = $useTrustedRelayPoint
                phoneTemplateName     = $Template
                primaryPhoneName      = $primaryPhoneName
                deviceMobilityMode    = $deviceMobilityMode
                certificateOperation  = $certificateOperation
                packetCaptureMode     = $packetCaptureMode
                builtInBridgeStatus   = $builtInBridgeStatus
                description           = $Description
            }
        }
        EnableException = $EnableException
    }
    Invoke-PSCUCMAxlQuery @CucmAxlSplat
    
}


function Get-PSCUCMPhone {
    <#
    .SYNOPSIS
    Get a single phone in CUCM
    
    .DESCRIPTION
    Get a single phone in CUCM based upon the Directory Number
    
    .PARAMETER DN
    Directory Number to look up.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMPhone -DN 1001

    Returns the phone with DN 1001.
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $DN,
        [switch]
        $EnableException
    )
    $phoneNameByDNSplat = @{
        DN              = $DN
        EnableException = $EnableException
    }
    $phoneName = Get-PSCUCMPhoneName @phoneNameByDNSplat |
        Select-Xml -XPath '//name' |
        Select-Object -ExpandProperty node |
        Select-Object -ExpandProperty '#text'
    $CucmAxlSplat = @{
        'entity'     = 'getPhone'
        'parameters' = @{
            'name' = $phoneName
        }
    }
    Invoke-PSCUCMAxlQuery @CucmAxlSplat | Select-Xml -XPath '//phone' | Select-Object -ExpandProperty node
}

function Get-PSCUCMPhoneServices {
    <#
    .SYNOPSIS
    Get the Phone Services for a phone based upon a DN.
    
    .DESCRIPTION
    Get the Phone Services for a phone based upon the DN of the phone. Presumes phones with services don't share the DN... Might fail spectacularly if the DN is shared...
    
    .PARAMETER DN
    Directory Number to look up.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMPhoneServices -DN 1001

    Gets the Phone Services for phone with DN 1001.
    #>
    
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = "CUCM returns to us all of the services. We can't pick and choose which ones to return.")]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $DN,
        [switch]
        $EnableException
    )
    $PhoneByDNSplat = @{
        DN              = $DN
        EnableException = $EnableException
    }
    Get-PSCUCMPhone @PhoneByDNSplat |
        Select-Xml -XPath '//service' |
        Select-Object -ExpandProperty node
}

function Find-PSCUCMHuntList {
    <#
    .SYNOPSIS
    Find Hunt Lists in CUCM
    
    .DESCRIPTION
    Find Hunt Lists in your CUCM environment.
    
    .PARAMETER name
    Name of Hunt List
    
    .PARAMETER Description
    Description of Hunt List
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Find-PSCUCMHuntList -name %

    Returns all Hunt Lists within CUCM
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $name,
        [Parameter()]
        [string]
        $Description,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'listHuntList'
        parameters      = @{
            searchCriteria = @{

            }
            returnedTags   = @{
                description          = $null
                callManagerGroupName = $null
                routeListEnabled     = $null
                voiceMailUsage       = $null
                name                 = $null
            }
        }
        EnableException = $EnableException
    }
    if (![string]::IsNullOrEmpty($name)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.name = $name
    }
    if (![string]::IsNullOrEmpty($Description)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.description = $Description
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Select-Xml -XPath '//huntList' | Select-Object -ExpandProperty node
}

function Find-PSCUCMHuntPilot {
    <#
    .SYNOPSIS
    Find Hunt Pilots
    
    .DESCRIPTION
    Find Hunt Pilots within CUCM Environment
    
    .PARAMETER pattern
    Pattern to search for
    
    .PARAMETER Description
    Description to search for.
    
    .PARAMETER RoutePartitionName
    Route Partition to search within.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Find-PSCUCMHuntPilot -Description %

    Search for all Hunt Pilots without Route Partion
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [int]
        $pattern,
        [Parameter()]
        [string]
        $Description,
        [Parameter()]
        [string]
        $RoutePartitionName,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'listHuntPilot'
        parameters      = @{
            searchCriteria = @{

            }
            returnedTags   = @{
                pattern                        = $null
                description                    = $null
                usage                          = $null
                routePartitionName             = $null
                blockEnable                    = $null
                calledPartyTransformationMask  = $null
                callingPartyTransformationMask = $null
                useCallingPartyPhoneMask       = $null
                callingPartyPrefixDigits       = $null
                dialPlanName                   = $null
                digitDiscardInstructionName    = $null
                patternUrgency                 = $null
                prefixDigitsOut                = $null
                routeFilterName                = $null
                callingLinePresentationBit     = $null
                callingNamePresentationBit     = $null
                connectedLinePresentationBit   = $null
                connectedNamePresentationBit   = $null
                patternPrecedence              = $null
                provideOutsideDialtone         = $null
                callingPartyNumberingPlan      = $null
                callingPartyNumberType         = $null
                calledPartyNumberingPlan       = $null
                calledPartyNumberType          = $null
                huntListName                   = $null
                parkMonForwardNoRetrieve       = @{
                    usePersonalPreferences = $null
                    destination            = $null
                    callingSearchSpaceName = $null
                }
                alertingName                   = $null
                asciiAlertingName              = $null
                aarNeighborhoodName            = $null
                forwardHuntNoAnswer            = @{
                    usePersonalPreferences = $null
                    destination            = $null
                    callingSearchSpaceName = $null
                }
                forwardHuntBusy                = @{
                    usePersonalPreferences = $null
                    destination            = $null
                    callingSearchSpaceName = $null
                }
                callPickupGroupName            = $null
                maxHuntduration                = $null
                releaseClause                  = $null
                displayConnectedNumber         = $null
                queueCalls                     = @{
                    maxCallersInQueue                = $null
                    queueFullDestination             = $null
                    callingSearchSpacePilotQueueFull = $null
                    maxWaitTimeInQueue               = $null
                    maxWaitTimeDestination           = $null
                    callingSearchSpaceMaxWaitTime    = $null
                    noAgentDestination               = $null
                    callingSearchSpaceNoAgent        = $null
                    networkHoldMohAudioSourceID      = $null
                }
            }
        }
        EnableException = $EnableException
    }
    if ($pattern) {
        $invokeCucmAxlSplat.parameters.searchCriteria.pattern = $pattern
    }
    if (![string]::IsNullOrEmpty($Description)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.description = $Description
    }
    if (![string]::IsNullOrEmpty($RoutePartitionName)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.routePartitionName = $RoutePartitionNamepattern
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Selec-Xml -XPath '//huntPilot' | Select-Object -ExpandProperty Node
}

function Find-PSCUCMLineGroup {
    <#
    .SYNOPSIS
    Find Line Groups
    
    .DESCRIPTION
    Find Line Groups within CUCM Environment
    
    .PARAMETER name
    Name of Line Group to search for.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Find-PSCUCMLineGroup %

    Find all Line Groups
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $name,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'listLineGroup'
        parameters      = @{
            searchCriteria = @{

            }
            returnedTags   = @{
                distributionAlgorithm     = $null
                rnaReversionTimeOut       = $null
                huntAlgorithmNoAnswer     = $null
                huntAlgorithmBusy         = $null
                huntAlgorithmNotAvailable = $null
                embers                    = @{
                    ember = @{
                        lineSelectionOrder = $null
                        irectoryNumber     = @{
                            pattern            = $null
                            routePartitionName = $null
                        }
                    }
                }
                name                      = $null
                autoLogOffHunt            = $null
            }
        }
        EnableException = $EnableException
    }
    if (![string]::IsNullOrEmpty($name)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.name = $name
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Selec-Xml -XPath '//lineGroup' | Select-Object -ExpandProperty Node
}

function Find-PSCUCMTranslationPattern {
    <#
    .SYNOPSIS
    Find Translation Patterns within CUCM
    
    .DESCRIPTION
    Find Translation Patterns within CUCM
    
    .PARAMETER Pattern
    Pattern to possibly search for
    
    .PARAMETER Description
    Description to possibly search for
    
    .PARAMETER RoutePartitionName
    Route Partition to possibly search for
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Find-PSCUCMTranslationPattern -Pattern 1234

    Returns the information for Translation Pattern 1234.
    
    #>
    [CmdletBinding()]
    param (
        [string]
        $Pattern,
        [string]
        $Description,
        [string]
        $RoutePartitionName,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'listTransPattern'
        parameters      = @{
            searchCriteria = @{ }
            returnedTags   = @{
                pattern                        = ''
                description                    = ''
                usage                          = ''
                routePartitionName             = ''
                blockEnable                    = ''
                calledPartyTransformationMask  = ''
                callingPartyTransformationMask = ''
                useCallingPartyPhoneMask       = ''
                callingPartyPrefixDigits       = ''
                dialPlanName                   = ''
                digitDiscardInstructionName    = ''
                patternUrgency                 = ''
                prefixDigitsOut                = ''
                routeFilterName                = ''
                callingLinePresentationBit     = ''
                callingNamePresentationBit     = ''
                connectedLinePresentationBit   = ''
                connectedNamePresentationBit   = ''
                patternPrecedence              = ''
                provideOutsideDialtone         = ''
                callingPartyNumberingPlan      = ''
                callingPartyNumberType         = ''
                calledPartyNumberingPlan       = ''
                calledPartyNumberType          = ''
                callingSearchSpaceName         = ''
                resourcePriorityNamespaceName  = ''
                routeNextHopByCgpn             = ''
                routeClass                     = ''
                callInterceptProfileName       = ''
                releaseClause                  = ''
                useOriginatorCss               = ''
                dontWaitForIDTOnSubsequentHops = ''
                isEmergencyServiceNumber       = ''
            }
        }
        EnableException = $EnableException
    }
    if (![string]::IsNullOrEmpty($Pattern)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.pattern = $Pattern
    }
    if (![string]::IsNullOrEmpty($Description)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.description = $Description
    }
    if (![string]::IsNullOrEmpty($RoutePartitionName)) {
        $invokeCucmAxlSplat.parameters.searchCriteria.routePartitionName = $RoutePartitionName
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Select-Xml -XPath '//transPattern' | Select-Object -ExpandProperty node
}

function Get-PSCUCMHuntList {
    <#
    .SYNOPSIS
    Get Hunt List
    
    .DESCRIPTION
    Get Hunt List
    
    .PARAMETER uuid
    UUID of hunt list
    
    .PARAMETER name
    Name of the hunt list
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMHuntList 'My Hunt List'

    Get Hunt List named 'My Hunt List'
    #>
    [CmdletBinding(DefaultParameterSetName = "name")]
    param (
        [Parameter(ParameterSetName = 'uuid', Mandatory, Position = 0)]
        [string]
        $uuid,
        [Parameter(ParameterSetName = 'name', Mandatory, Position = 0)]
        [string]
        $name,
        [switch]
        [Parameter()]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'getHuntList'
        parameters      = @{
        }
        EnableException = $EnableException
    }
    if($PSCmdlet.ParameterSetName -eq 'name') {
        $invokeCucmAxlSplat.parameters.name = $name
    }
    if($PSCmdlet.ParameterSetName -eq 'uuid') {
        $invokeCucmAxlSplat.parameters.uuid = $uuid
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Selec-Xml -XPath '//huntList' | Select-Object -ExpandProperty Node
}

function Get-PSCUCMHuntPilot {
    <#
    .SYNOPSIS
    Get Hunt Pilot
    
    .DESCRIPTION
    Get Hunt Pilot
    
    .PARAMETER uuid
    UUID of Hunt Pilot
    
    .PARAMETER pattern
    Pattern of Hunt Pilot
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMHuntPilot 1234

    Get Hunt Pilot for pattern 1234
    #>
    [CmdletBinding(DefaultParameterSetName = "pattern")]
    param (
        [Parameter(ParameterSetName = 'uuid', Mandatory, Position = 0)]
        [string]
        $uuid,
        [Parameter(ParameterSetName = 'pattern', Mandatory, Position = 0)]
        [int]
        $pattern,
        [switch]
        [Parameter()]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'getHuntPilot'
        parameters      = @{
        }
        EnableException = $EnableException
    }
    if($PSCmdlet.ParameterSetName -eq 'pattern') {
        $invokeCucmAxlSplat.parameters.pattern = $pattern
    }
    if($PSCmdlet.ParameterSetName -eq 'uuid') {
        $invokeCucmAxlSplat.parameters.uuid = $uuid
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Selec-Xml -XPath '//huntPilot' | Select-Object -ExpandProperty Node
}

function Get-PSCUCMLineGroup {
    <#
    .SYNOPSIS
    Get Line Group
    
    .DESCRIPTION
    Get Line Group
    
    .PARAMETER uuid
    UUID of Line Group
    
    .PARAMETER name
    Name of Line Group
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMLineGroup -name 'Line Group 3'

    Get 'Line Group 3' information.
    #>
    [CmdletBinding(DefaultParameterSetName = "name")]
    param (
        [Parameter(ParameterSetName = 'uuid', Mandatory, Position = 0)]
        [string]
        $uuid,
        [Parameter(ParameterSetName = 'name', Mandatory, Position = 0)]
        [string]
        $name,
        [switch]
        [Parameter()]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'getLineGroup'
        parameters      = @{
        }
        EnableException = $EnableException
    }
    if($PSCmdlet.ParameterSetName -eq 'name') {
        $invokeCucmAxlSplat.parameters.name = $name
    }
    if($PSCmdlet.ParameterSetName -eq 'uuid') {
        $invokeCucmAxlSplat.parameters.uuid = $uuid
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Selec-Xml -XPath '//lineGroup' | Select-Object -ExpandProperty Node
}

function Get-PSCUCMTranslationPattern {
    <#
    .SYNOPSIS
    Get the Translation Pattern
    
    .DESCRIPTION
    Get the Translation Pattern
    
    .PARAMETER TranslationPattern
    Translation Pattern to look up.
    
    .PARAMETER RoutePartitionName
    Route Partition that houses the Translation Pattern.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Get-PSCUCMTranslationPattern -TranslationPattern 1234 -RoutePartitonName default-rp

    Gets the Translation Pattern for 1234.
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $TranslationPattern,
        [Parameter(Mandatory = $true)]
        [string]
        $RoutePartitionName,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'getTransPattern'
        parameters      = @{
            pattern            = $TranslationPattern
            routePartitionName = $RoutePartitionName
        }
        EnableException = $EnableException
    }
    Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat | Selec-Xml -XPath '//transPattern' | Select-Object -ExpandProperty Node
}

function Set-PSCUCMTranslationPattern {
        <#
    .SYNOPSIS
    Set the Translation Pattern
    
    .DESCRIPTION
    Set the Translation Pattern
    
    .PARAMETER TranslationPattern
    Translation Pattern to set.
    
    .PARAMETER RoutePartitionName
    Route Partition that houses the Translation Pattern.

    .PARAMETER CalledPartyTransformationMask
    The transformation mask to apply to the translation pattern.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.

    .PARAMETER WhatIf
    What If?
    
    .PARAMETER Confirm
    Confirm...
    
    .EXAMPLE
    Get-PSCUCMTranslationPattern -TranslationPattern 1234 -RoutePartitonName default-rp

    Gets the Translation Pattern for 1234.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $TranslationPattern,
        [string]
        $RoutePartitionName = $null,
        [string]
        $CalledPartyTransformationMask = $null,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity          = 'updateTransPattern'
        parameters      = @{
            pattern = $TranslationPattern
        }
        EnableException = $EnableException
    }
    if ($RoutePartitionName) {
        $invokeCucmAxlSplat.parameters.routePartitionName = $RoutePartitionName
    }
    if ($calledPartyTransformationMask) {
        $invokeCucmAxlSplat.parameters.calledPartyTransformationMask = $calledPartyTransformationMask
    }
    if ($PSCmdlet.ShouldProcess($server, "Set Translation Pattern $TranslationPattern")) {
        Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat
    }
}

function Find-PSCUCMLine {
    <#
    .SYNOPSIS
    Find lines within CUCM
    
    .DESCRIPTION
    Find lines within CUCM that match the criteria
    
    .PARAMETER Pattern
    Pattern to search
    
    .PARAMETER Description
    Description to search
    
    .PARAMETER Usage
    Usage to search (Your guess is as good as mine...)
    
    .PARAMETER RoutePartitionName
    RoutePartitionName to search
    
    .PARAMETER skip
    Number of lines to skip.
    
    .PARAMETER first
    Number of lines to return.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .EXAMPLE
    Find-PSCUCMLine -Line %

    Finds all lines within CUCM
    
    .NOTES
    Uses SQL Wildcards. So %
    #>
    
    [CmdletBinding()]
    param (
        [string]
        $Pattern,
        [string]
        $Description,
        [string]
        $Usage,
        [string]
        $RoutePartitionName,
        [int]
        $skip,
        [int]
        $first,
        [switch]
        $EnableException
    )
    $CucmAxlSplat = @{
        Entity          = 'listLine'
        Parameters      = @{
            searchCriteria = @{}
            returnedTags   = @{
                pattern                              = ''
                description                          = ''
                usage                                = ''
                routePartitionName                   = ''
                aarNeighborhoodName                  = ''
                aarDestinationMask                   = ''
                aarKeepCallHistory                   = ''
                aarVoiceMailEnabled                  = ''
                callPickupGroupName                  = ''
                autoAnswer                           = ''
                networkHoldMohAudioSourceId          = ''
                userHoldMohAudioSourceId             = ''
                alertingName                         = ''
                asciiAlertingName                    = ''
                presenceGroupName                    = ''
                shareLineAppearanceCssName           = ''
                voiceMailProfileName                 = ''
                patternPrecedence                    = ''
                releaseClause                        = ''
                hrDuration                           = ''
                hrInterval                           = ''
                cfaCssPolicy                         = ''
                defaultActivatedDeviceName           = ''
                parkMonForwardNoRetrieveDn           = ''
                parkMonForwardNoRetrieveIntDn        = ''
                parkMonForwardNoRetrieveVmEnabled    = ''
                parkMonForwardNoRetrieveIntVmEnabled = ''
                parkMonForwardNoRetrieveCssName      = ''
                parkMonForwardNoRetrieveIntCssName   = ''
                parkMonReversionTimer                = ''
                partyEntranceTone                    = ''
                allowCtiControlFlag                  = ''
                rejectAnonymousCall                  = ''
                confidentialAccess                   = @{
                    confidentialAccessMode  = ''
                    confidentialAccessLevel = ''
                }
                externalCallControlProfile           = ''
                enterpriseAltNum                     = @{
                    numMask                = ''
                    isUrgent               = ''
                    addLocalRoutePartition = ''
                    routePartition         = ''
                    advertiseGloballyIls   = ''
                }
                e164AltNum                           = @{
                    numMask                = ''
                    isUrgent               = ''
                    addLocalRoutePartition = ''
                    routePartition         = ''
                    advertiseGloballyIls   = ''
                }
                pstnFailover                         = ''
                associatedDevices                    = @{
                    device = ''
                }
            }
        }
        EnableException = $EnableException
    }
    if(![string]::IsNullOrEmpty($Pattern)) {
        $CucmAxlSplat.Parameters.searchCriteria.Add('pattern', $pattern)
    }
    if(![string]::IsNullOrEmpty($description)) {
        $CucmAxlSplat.Parameters.searchCriteria.Add('description', $description)
    }
    if(![string]::IsNullOrEmpty($usage)) {
        $CucmAxlSplat.Parameters.searchCriteria.Add('usage', $usage)
    }
    if(![string]::IsNullOrEmpty($routePartitionName)) {
        $CucmAxlSplat.Parameters.searchCriteria.Add('routePartitionName', $routePartitionName)
    }
    if($skip) {
        $CucmAxlSplat.Parameters.Add('skip', $skip)
    }
    if($first) {
        $CucmAxlSplat.Parameters.Add('first', $first)
    }
    Invoke-PSCUCMAxlQuery @CucmAxlSplat | Select-Xml -XPath '//line' | Select-Object -ExpandProperty node
}

function Invoke-PSCUCMLdapSync {
    <#
    .SYNOPSIS
    Invoke sync of LDAP Directory
    
    .DESCRIPTION
    Invoke sync of LDAP Directory
    
    .PARAMETER LdapDirectory
    LDAP Directory to sync
    
    .PARAMETER cancelActive
    Cancel active sync
    
    .PARAMETER AXLVersion
    AXL Version for Server.
    
    .PARAMETER server
    Server to query
    
    .PARAMETER Credential
    Credential to use for API access
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.

    .PARAMETER WhatIf
    What If?
    
    .PARAMETER Confirm
    Confirm...
    
    .EXAMPLE
    An example

    System Up Time: 	0d, 0h, 13m
    #>
    
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $LdapDirectory,
        [switch]
        $CancelActive,
        [switch]
        $EnableException
    )
    $invokeCucmAxlSplat = @{
        entity     = 'doLdapSync'
        parameters = @{
            name = $LdapDirectory
            sync = $true
        }
        EnableException = $EnableException
    }
    if ($cancelActive.IsPresent) {
        $invokeCucmAxlSplat.parameters.sync = $false
    }
    if ($PSCmdlet.ShouldProcess($server, "Set Translation Pattern $TranslationPattern")) {
        Invoke-PSCUCMAxlQuery @invokeCucmAxlSplat
    }
}

function Connect-PSCucm {
    <#
    .SYNOPSIS
    "Connect" to CUCM Server
    
    .DESCRIPTION
    "Connect" to a CUCM Server using the supplied values.
    
    .PARAMETER AXLVersion
    AXL Version for the Server to connect to. Typically same version as CUCM itself.
    
    .PARAMETER server
    Server to connect to.
    
    .PARAMETER Credential
    Credential Object for the Application User that has the appropriate AXL permissions.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .PARAMETER SkipCertificateCheck
    Skip the check of the certificate. Needed in test environments, and environments without "valid" signed certificates.
    
    .PARAMETER PersistSettings
    Persist the settings beyond the current session.
    
    .EXAMPLE
    Connect-PSCucm -AXLVersion 11.5 -server cucm.example.com -Credential $AXLCredential

    It connects to CUCM Server cucm.example.com
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $AXLVersion,
        [Parameter(Mandatory = $true)]
        [string]
        $server,
        [Parameter(Mandatory = $true)]
        [pscredential]
        $Credential,
        [switch]
        $EnableException,
        [switch]
        $SkipCertificateCheck,
        [switch]
        $PersistSettings
    )
    Set-PSFConfig -Module PSCUCM -Name Connected -Value $true
    Set-PSFConfig -Module PSCUCM -Name AXLVersion -Value $AXLVersion
    Set-PSFConfig -Module PSCUCM -Name Server -Value $Server
    Set-PSFConfig -Module PSCUCM -Name Credential -Value $Credential
    Set-PSFConfig -Module PSCUCM -Name SkipCertificateCheck -Value $SkipCertificateCheck
    $Global:PSDefaultParameterValues['*-PSCucm*:EnableException'] = $EnableException
    if ($PersistSettings) {
        Register-PSFConfig -FullName pscucm.axlversion
        Register-PSFConfig -FullName pscucm.server
        Register-PSFConfig -FullName pscucm.credential
        Register-PSFConfig -FullName pscucm.skipcertificatecheck
        Register-PSFConfig -FullName pscucm.connected
    }
}


function Disconnect-PSCucm {
    <#
    .SYNOPSIS
    "Disconnect" from CUCM Server
    
    .DESCRIPTION
    "Disconnect" from CUCM Server
    
    .EXAMPLE
    Disconnect-PSCucm

    Disconnects from CUCM Server.
    
    .NOTES
    General notes
    #>
    
    [CmdletBinding()]
    param (
    )
    Reset-PSFConfig -Module pscucm
    $Global:PSDefaultParameterValues.remove('*-PSCucm*:EnableException')
}

function Get-PSCUCMStatus {
    <#
    .SYNOPSIS
    Get the status of the current CUCM Connection
    
    .DESCRIPTION
    Get the status of the current CUCM Connection. Does *not* return the credential.
    
    .EXAMPLE
    Get-PSCUCMStatus

    

    Name                           Value
    ----                           -----
    Server
    SkipCertificateCheck
    AXLVersion
    Connected                      False
    #>
    [CmdletBinding()]
    param ()
    [PSCustomObject]@{
        Connected = Get-PSFConfigValue PSCUCM.Connected
        AXLVersion = Get-PSFConfigValue PSCUCM.AXLVersion
        Server = Get-PSFConfigValue PSCUCM.Server
        SkipCertificateCheck = Get-PSFConfigValue PSCUCM.SkipCertificateCheck
    }
}


function Invoke-PSCUCMAxlQuery {
    <#
    .SYNOPSIS
    Invoke an AXL Query
    
    .DESCRIPTION
    Invoke an AXL Query against the connected server.
    
    .PARAMETER Entity
    AXL Entity to invoke.
    
    .PARAMETER Parameters
    Parameters for the AXL Entity.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .PARAMETER OutputXml
    Output XML for the query instead of invoking it.

    .PARAMETER WhatIf
    What If?
    
    .PARAMETER Confirm
    Confirm...
    
    .EXAMPLE
    Invoke-PSCUCMAxlQuery -Entity getUser -Parameters @{ name = 'administrator' } -OutputXML

    Outputs the XML that would be sent to CUCM server.
    
    .NOTES
    OutputXML does *not* need a connected CUCM server to run.
    #>
    
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Low")]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Entity,
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Parameters,
        [switch]
        $EnableException,
        [switch]
        $OutputXml
    )
    $AXLVersion = Get-PSFConfigValue -FullName pscucm.axlversion
    Write-PSFMessage -Level Debug -Message "AXL Version: $AXLVersion"
    if (-not $OutputXml) {
        Write-PSFMessage -Level Verbose -Message "Attempting to query $Entity" -Target $Parameters
        $EnableException = $EnableException -or $(Get-PSFConfigValue -FullName pscucm.enableexception)
        if (-not (Get-PSFConfigValue -FullName pscucm.connected)) {
            Stop-PSFFunction -Message "Unable to process AXL request. Not connected." -EnableException $EnableException
            return
        }
        $Server = Get-PSFConfigValue -FullName pscucm.server
        Write-PSFMessage -Level Debug -Message "Querying $Server"
        $Credential = Get-PSFConfigValue -FullName pscucm.credential
        Write-PSFMessage -Level Debug -Message "Using username: $($Credential.Username)"
    }
    $object = @{
        'soapenv:Header' = ''
        'soapenv:Body' = @{
            "ns:$entity" = $Parameters
        }
    }
    $body = ConvertTo-XMLString -InputObject $object -ObjectName "soapenv:Envelope" -RootAttributes @{"xmlns:soapenv"="http://schemas.xmlsoap.org/soap/envelope/"; "xmlns:ns"="http://www.cisco.com/AXL/API/$AXLVersion"}
    Write-PSFMessage -Level Debug -Message "Generated XML for Entity: $Entity" -Target $body
    if (-not $OutputXml) {
        if ($PSCmdlet.ShouldProcess($Server, "Execute AXL query $Entity")) {
            $CUCMURL = "https://$Server/axl/"
            $headers = @{
                'Content-Type' = 'text/xml; charset=utf-8'
            }
            $IRMParams = @{
                Headers    = $headers
                Body       = $body
                Uri        = $CUCMURL
                Method     = 'Post'
                Credential = $Credential
            }
            if (Get-PSFConfigValue -FullName pscucm.skipcertificatecheck) {
                if ($PSVersionTable.PSVersion.Major -ge 6) {
                    $IRMParams.SkipCertificateCheck = $true
                }
                else {
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
                }
            }
            try {
                Invoke-WebRequest @IRMParams |
                    Select-XML -XPath '//return' |
                    Select-Object -ExpandProperty Node
            }
            catch {
                $ErrorMessage = $_.ErrorDetails.message
                $PSFMessage = "Failed to execute AXL entity $Entity."
                if (($null -ne $ErrorMessage) -and ($_.Exception.Response.StatusCode -eq 'InternalServerError')) {
                    if ($PSVersionTable.PSVersion.Major -ge 6) {
                        $null = $ErrorMessage -match "(\d+)(.*)$Entity"
                        $axlcode = $Matches[1]
                        $axlMessage = $Matches[2]
                    }
                    else {
                        $axlcode = ($ErrorMessage | select-xml -XPath '//axlcode' | Select-Object -ExpandProperty Node).'#text'
                        $axlMessage = ($ErrorMessage | select-xml -XPath '//axlmessage' | Select-Object -ExpandProperty Node).'#text'
                    }
                    $PSFMessage += " AXL Error: $axlMessage ($axlcode)"
                }
                Stop-PSFFunction -Message $PSFMessage -ErrorRecord $_ -EnableException $EnableException -Target $body
                return
            }
        }
    }
    else {
        $body
    }
}


function Invoke-PSCUCMSqlQuery {
    <#
    .SYNOPSIS
    Invoke a SQL Query against CUCM Server.
    
    .DESCRIPTION
    Invoke a SQL Query against CUCM Server.
    
    .PARAMETER SqlQuery
    SQL Query to invoke.
    
    .PARAMETER EnableException
    Replaces user friendly yellow warnings with bloody red exceptions of doom!
    Use this if you want the function to throw terminating errors you want to catch.
    
    .PARAMETER OutputXml
    Output just XML
    
    .EXAMPLE
    Invoke-PSCUCMSqlQuery -SqlQuery "Select * from phones"

    Will execute the query against the CUCM server. This is probably a bad query... Do *not* try this at home.
    #>
    
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $SqlQuery,
        [switch]
        $EnableException,
        [switch]
        $OutputXml
    )
    $CucmAxlSplat = @{
        entity          = 'executeSQLQuery'
        parameters      = @{
            sql = $SqlQuery
        }
        EnableException = $EnableException
        OutputXml       = $OutputXml
    }
    Invoke-PSCUCMAxlQuery @CucmAxlSplat
}

<#
This is an example configuration file

By default, it is enough to have a single one of them,
however if you have enough configuration settings to justify having multiple copies of it,
feel totally free to split them into multiple files.
#>

<#
# Example Configuration
Set-PSFConfig -Module 'PSCUCM' -Name 'Example.Setting' -Value 10 -Initialize -Validation 'integer' -Handler { } -Description "Example configuration setting. Your module can then use the setting using 'Get-PSFConfigValue'"
#>

Set-PSFConfig -Module 'PSCUCM' -Name 'Import.DoDotSource' -Value $false -Initialize -Validation 'bool' -Description "Whether the module files should be dotsourced on import. By default, the files of this module are read as string value and invoked, which is faster but worse on debugging."
Set-PSFConfig -Module 'PSCUCM' -Name 'Import.IndividualFiles' -Value $false -Initialize -Validation 'bool' -Description "Whether the module files should be imported individually. During the module build, all module code is compiled into few files, which are imported instead by default. Loading the compiled versions is faster, using the individual files is easier for debugging and testing out adjustments."
Set-PSFConfig -Module 'PSCUCM' -Name 'Connected' -Value $false -Description 'Flag that we''ve "connected" to the server' -Initialize
Set-PSFConfig -Module 'PSCUCM' -Name 'AXLVersion' -Value $null -Description "AXL Version used by the server (typically the same version as CUCM" -Initialize
Set-PSFConfig -Module 'PSCUCM' -Name 'Server' -Value $null -Description "Server for PSCUCM to connect to." -Initialize
Set-PSFConfig -Module 'PSCUCM' -Name 'Credential' -Value $null -Description "Credential for PSCUCM to use to connect to the server." -Initialize
Set-PSFConfig -Module 'PSCUCM' -Name 'SkipCertificateCheck' -Value $null -Description "Should PSCUCM Skip the certificate check (If you use a self signed you want to set this)" -Initialize

<#
# Example:
Register-PSFTeppScriptblock -Name "PSCUCM.alcohol" -ScriptBlock { 'Beer','Mead','Whiskey','Wine','Vodka','Rum (3y)', 'Rum (5y)', 'Rum (7y)' }
#>

<#
# Example:
Register-PSFTeppArgumentCompleter -Command Get-Alcohol -Parameter Type -Name PSCUCM.alcohol
#>

New-PSFLicense -Product 'PSCUCM' -Manufacturer 'corbob' -ProductVersion $script:ModuleVersion -ProductType Module -Name MIT -Version "1.0.0.0" -Date (Get-Date "2018-12-30") -Text @"
Copyright (c) 2018 corbob

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"@
#endregion Load compiled code