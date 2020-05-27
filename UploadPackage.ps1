        $AgentDirectory="C:\Agent\71\"
        $APPLICATION_NAME="ETC_Fin_Ariba_Performer"
        $BuildNumber="1570374"
        $DeployEnv="Dev"
        
        $JSONData = Get-Content "$AgentDirectory\$BuildNumber\variables.json" | out-string | ConvertFrom-Json
        $OrchestratorURL=$JSONData.$DeployEnv.OrchestratorURL
        $TENANTNAME=$JSONData.$DeployEnv.TENANTNAME
        $Environment=$JSONData.$DeployEnv.Environment
        $OU=$JSONData.$DeployEnv.OU
        $VMNAME=$JSONData.$DeployEnv.VMNAME

        get-childitem -path $AgentDirectory #-recurse
        $File = get-childitem -Path "$AgentDirectory\$BuildNumber\*.nupkg"
        $Filepath=$File.FullName
         <#$Headers=@{
                    "X-UIPATH-OrganizationUnitId"="$OUId"
                    "X-UIPATH-TenantName"="$TENANTNAME"
                }

        $getProjectUri = "$OrchestratorURL/odata/Tenants?$filter=IsActive eq true"


        $APIData = Invoke-RestMethod -Method Get -Uri $getProjectUri -UseDefaultCredentials#>


        if($Filepath)
        {
            write-host "-----------------------------------------------------------------------------------------------------"
            write-host "################ Package - $Filepath  #########################"
            write-host "-----------------------------------------------------------------------------------------------------"  
            
            function UiPath-APICall{
            param(
                [parameter(mandatory=$true)]
                [string]$api,
                [parameter(mandatory=$false)]
                [string]$OUId,
                [parameter(mandatory=$false)]
                [string]$Method="Get",
                [parameter(mandatory=$false)]
                $header=@{
                    "X-UIPATH-OrganizationUnitId"="$OUId"
                    "X-UIPATH-TenantName"="$TENANTNAME"
                }

            )
                $InvokeResult = Invoke-RestMethod $api -Method $Method -Headers $header -UseDefaultCredentials
                return $InvokeResult.value
            }
            <#$ten = "$OrchestratorURL/odata/Tenants?$filter=IsActive eq true"
             $InvokeResult1 = Invoke-RestMethod $ten  -Headers $header -UseDefaultCredentials
          write-host $InvokeResult1.value#>

            $OUApi="$OrchestratorURL/odata/OrganizationUnits?`$filter=DisplayName%20eq%20%27$OU%27"
            #$OUApi="$OrchestratorURL/odata/OrganizationUnits"

           # $ten = "$OrchestratorURL/odata/Tenants?`$filter= IsActive eq 'True'&api-key='797728a1-7f49-4d5b-9e50-f91e531f76d7'"
           
            $OU=UiPath-APICall $OUApi -header $header
            #$OU11=UiPath-APICall $ten -header $header

            $OUId = $OU.id
           # $OUId1 = $ten.id

            # Build the URI for our request
            $UploadPackageApi = "$ORCHESTRATORURL/odata/Processes/UiPath.Server.Configuration.OData.UploadPackage()";
            $Headers = @{
                    "X-UIPATH-OrganizationUnitId"="$OUId"
                     "X-UIPATH-TenantName"="$TENANTNAME"
            }
                        
            # The boundary is essential - Trust me, very essential
            $boundary = [Guid]::NewGuid().ToString()
            $bodyStart = @"
--$boundary
Content-Disposition: form-data; name="files"; filename="$(Split-Path -Leaf -Path $FilePath)"
Content-Type: application/octet-stream


"@

# Generate the end of the request body to finish it.
        $bodyEnd = @"

--$boundary--
"@

            # Now we create a temp file (Another crappy/bad thing)
            $requestInFile = (Join-Path -Path ${env:TEMP} -ChildPath ([IO.Path]::GetRandomFileName()))

            try
            {
                # Create a new object for the brand new temporary file
                $fileStream = (New-Object -TypeName 'System.IO.FileStream' -ArgumentList ($requestInFile, [IO.FileMode]'Create', [IO.FileAccess]'Write'))
                try
                {
                    # The Body start
                    $bytes = [Text.Encoding]::UTF8.GetBytes($bodyStart)
                    $fileStream.Write($bytes, 0, $bytes.Length)

                    # The original File
                    $bytes = [IO.File]::ReadAllBytes($FilePath)
                    $fileStream.Write($bytes, 0, $bytes.Length)

                    # Append the end of the body part
                    $bytes = [Text.Encoding]::UTF8.GetBytes($bodyEnd)
                    $fileStream.Write($bytes, 0, $bytes.Length)
                }
                finally
                {
                    # End the Stream to close the file
                    $fileStream.Close()

                    # Cleanup
                    $fileStream = $null

                    # PowerShell garbage collector
                    [GC]::Collect()
                }

                # Make it multipart, this is the magic part...
                $contentType = 'multipart/form-data; boundary={0}' -f $boundary

                try
                {
                    "####### Starting the deployment of the package $APPLICATION_NAME to the Orchestrator $OrchestratorURL #######"
                    Write-Host "-----------------------------------------------------------------------------------------------------"   
                    Write-Host "-----------------------------------------------------------------------------------------------------"
                    Write-Host "################ Package Deployment is in progress  #########################"
                    $null = (invoke-RestMethod -Uri $UploadPackageApi -Method Post -InFile $requestInFile -ContentType $contentType -Headers $Headers -UseDefaultCredentials -ErrorAction Stop -WarningAction SilentlyContinue)
                    Write-Host "-----------------------------------------------------------------------------------------------------"
                    Write-Host "######################### Deployment Completed #########################"
                    Write-Host "-----------------------------------------------------------------------------------------------------"   
                    $ProcessApi="$OrchestratorURL/odata/Releases?`$filter= ProcessKey eq '$APPLICATION_NAME'"
                    do{
                        $Processes = UiPath-APICall $ProcessApi $OUId
                    }while (!$Processes);
                    if($Processes)
                    {
                        Write-Host "Extracted following Processes:"
                        foreach($process in $Processes)
                        {
                            $process.Name
                        }
                    }
                            
                    $JobsApi = "$OrchestratorURL/odata/Jobs?"
                
                            
                        foreach($Pro in $Processes)
                        {
                            $processID=$Pro.Id
                            $ProcessName = $Pro.Name
                            do{
                                $RunningJobsName =""
                                $Jobs = UiPath-APICall $ProcessApi $OUId
                                foreach($Job in $Jobs)
                                {
                                    if($Job.State -eq "Running" -or $Job.State -eq "Pending" -and $Job.ReleaseName -like "*$APPLICATION_NAME*")
                                    {
                                        [String[]]$RunningJobsName += $Job.ReleaseName
                                        Start-Sleep -Seconds 10
                                        Write-Host "########################################################################################################"
                                        Write-Host "Job related to Process $ProcessName is running; Waiting for it to finish..."
                                        Write-Host "#########################################################################################################"
                                         
                                    }
                                }
                                           
                            }until(!$RunningJobsName.Contains($ProcessName))
                                    
                            ##Disable any Schedule related to Process before Package Activation
                            $SchedulesApi = "$OrchestratorURL/odata/processschedules"
                            $Schedules = UiPath-APICall $SchedulesApi $OUId
                            $ScheduleEnableApi="$OrchestratorURL/odata/processschedules/UiPath.Server.Configuration.OData.SetEnabled"
                            foreach($schedule in $Schedules)
                            {
                                if($schedule.ReleaseName -eq $ProcessName -and $schedule.Enabled -eq $true)
                                {
                                    $SchID=$schedule.Id
                                    [Int[]]$ScheduleIds += $SchID
                                    Write-Host "---------------------------------------------"
                                    Write-Host "*********Disabling Process Schedule***********"
                                    Write-Host "---------------------------------------------"
                                    $header=@{
                                            "X-UIPATH-OrganizationUnitId"="$OUId"
                                            "scheduleIds"="[$SchID]"
                                            "enabled"="false"
                                    }
                                    ##Disable SCHEDULES
                                    UiPath-APICall $ScheduleEnableApi $OUId "Post" $header
                                }
                            }

                            Write-Host "------------------------------------------------------------"
                            Write-Host "#######Activating Package for Process $ProcessName #########"
                            Write-Host "------------------------------------------------------------"
                            $releaseApi="$OrchestratorURL/odata/Releases($processID)/UiPath.Server.Configuration.OData.UpdateToLatestPackageVersion"
                            UiPath-APICall $releaseApi $OUId "Post"
                            Write-Host "---------------------------------------------------------------------------------------------------------------------"
                            Write-Host "################ Package Activated with latest version for Process $ProcessName #########################"
                            Write-Host "----------------------------------------------------------------------------------------------------------------------"  
                            ##ENABLE SCHEDULES AFTER ACTIVATION
                            if($ScheduleIds)
                            {
                                $ScheduleIds|%{$SchIDs="$_"+","}
                                $SchIDs=$SchIDs.Substring(0,$SchIDs.LastIndexOf(","))
                                $header=@{
                                            "X-UIPATH-OrganizationUnitId"="$OUId"
                                            "scheduleIds"="[$SchIDs]"
                                            "enabled"="false"
                                    }
                                UiPath-APICall $ScheduleEnableApi $OUId "Post" $header
                            }
                    
                        }
                            
                }
                catch
                {
                    # Remove the temp file
                    $null = (Remove-Item -Path $requestInFile -Force -Confirm:$false)

                    # Cleanup
                    $contentType = $null

                    # PowerShell garbage collector
                    [GC]::Collect()
                    Write-Host $_ 
                    Write-Host "at " $_.InvocationInfo.ScriptLineNumber
                    exit 1
                    
                }
            }
            finally
            {
                # Remove the temp file
                        
                if(Test-path $requestInFile ){ 
                    Remove-Item -Path $requestInFile -Force -Confirm:$false
                }

                # Cleanup
                $contentType = $null

                # PowerShell garbage collector
                [GC]::Collect()
            }
        }    
    displayName: UploadPackageToOrchestrator
    env:
        Environment: '${{ parameters.Environment }}'