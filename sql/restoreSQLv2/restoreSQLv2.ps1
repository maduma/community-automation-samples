# process commandline arguments
[CmdletBinding()]
param (
    [Parameter()][string]$vip = 'helios.cohesity.com',
    [Parameter()][string]$username = 'helios',
    [Parameter()][string]$domain = 'local',
    [Parameter()][string]$tenant = $null,
    [Parameter()][switch]$useApiKey,
    [Parameter()][string]$password = $null,
    [Parameter()][switch]$noPrompt,
    [Parameter()][switch]$mcm,
    [Parameter()][string]$mfaCode = $null,
    [Parameter()][string]$clusterName = $null,
    [Parameter(Mandatory=$True)][string]$sourceServer,
    [Parameter()][array]$sourceDB,
    [Parameter()][string]$sourceDBList,
    [Parameter()][switch]$allDBs,
    [Parameter()][switch]$includeSystemDBs,
    [Parameter()][string]$sourceInstance,
    [Parameter()][string]$targetServer = $sourceServer,
    [Parameter()][string]$targetInstance,
    [Parameter()][string]$targetDB,
    [Parameter()][string]$prefix,
    [Parameter()][string]$suffix,
    [Parameter()][string]$mdfFolder,
    [Parameter()][string]$ldfFolder = $mdfFolder,
    [Parameter()][hashtable]$ndfFolders,
    [Parameter()][switch]$noRecovery,
    [Parameter()][switch]$noStop,
    [Parameter()][switch]$latest = $noStop,
    [Parameter()][datetime]$logTime,
    [Parameter()][switch]$wait,
    [Parameter()][int64]$pageSize = 100,
    [Parameter()][int64]$dbsPerRecovery = 100,
    [Parameter()][int64]$sleepTime = 30,
    [Parameter()][switch]$overwrite,
    [Parameter()][switch]$keepCdc,
    [Parameter()][switch]$captureTailLogs,
    [Parameter()][switch]$exportPaths,
    [Parameter()][switch]$importPaths,
    [Parameter()][switch]$useSourcePaths
)

# source the cohesity-api helper code
. $(Join-Path -Path $PSScriptRoot -ChildPath cohesity-api.ps1)

# authentication =============================================
# demand clusterName for Helios/MCM
if(($vip -eq 'helios.cohesity.com' -or $mcm) -and ! $clusterName){
    Write-Host "-clusterName required when connecting to Helios/MCM" -ForegroundColor Yellow
    exit 1
}

# authenticate
apiauth -vip $vip -username $username -domain $domain -passwd $password -apiKeyAuthentication $useApiKey -mfaCode $mfaCode -heliosAuthentication $mcm -tenant $tenant -noPromptForPassword $noPrompt

# exit on failed authentication
if(!$cohesity_api.authorized){
    Write-Host "Not authenticated" -ForegroundColor Yellow
    exit 1
}

# select helios/mcm managed cluster
if($USING_HELIOS){
    $thisCluster = heliosCluster $clusterName
    if(! $thisCluster){
        exit 1
    }
}
# end authentication =========================================


# gather list from command line params and file
function gatherList($Param=$null, $FilePath=$null, $Required=$True, $Name='items'){
    $items = @()
    if($Param){
        $Param | ForEach-Object {$items += $_}
    }
    if($FilePath){
        if(Test-Path -Path $FilePath -PathType Leaf){
            Get-Content $FilePath | ForEach-Object {$items += [string]$_}
        }else{
            Write-Host "Text file $FilePath not found!" -ForegroundColor Yellow
            exit
        }
    }
    if($Required -eq $True -and $items.Count -eq 0){
        Write-Host "No $Name specified" -ForegroundColor Yellow
        exit
    }
    return ($items | Sort-Object -Unique)
}

$sourceDbNames = @(gatherList -Param $sourceDB -FilePath $sourceDBList -Name 'DBs' -Required $False)

$cluster = api get cluster
if($cluster.clusterSoftwareVersion -lt '6.8.1'){
    Write-Host "This script requires Cohesity 6.8.1 or later" -ForegroundColor Yellow
    exit 1
}

# import file paths
$exportFilePath = Join-Path -Path $PSScriptRoot -ChildPath "$sourceServer.json"
$importedFileInfo = $null
if($importPaths){
    if(!(Test-Path -Path $exportFilePath)){
        Write-Host "Import file $exportFilePath not found" -ForegroundColor Yellow
        exit 1
    }
    $importedFileInfo = Get-Content -Path $exportFilePath | ConvertFrom-JSON
}

# find all databases on server
if($allDBs -or $exportPaths){
    $from = 0
    $allsearch = api get "/searchvms?environment=SQL&entityTypes=kSQL&vmName=$sourceServer&size=$pageSize&from=$from"
    $dbresults = @{'vms' = @()}
    if($allsearch.count -gt 0){
        while($True){
            $dbresults.vms = @($dbresults.vms + $allsearch.vms)
            if($allsearch.count -gt ($pageSize + $from)){
                $from += $pageSize
                $allsearch = api get "/searchvms?environment=SQL&entityTypes=kSQL&vmName=$sourceServer&size=$pageSize&from=$from"
            }else{
                break
            }
        }
    }
    $dbresults.vms = $dbresults.vms | Where-Object {$_.vmDocument.objectAliases -eq $sourceServer}

    if(! $dbresults.vms){
        Write-Host "no DBs found for $sourceServer" -ForegroundColor Yellow
        exit
    }
    if($sourceInstance){
        $dbresults.vms = $dbresults.vms | Where-Object {($_.vmDocument.objectName -split '/')[0] -eq $sourceInstance}
        if(! $dbresults.vms){
            Write-Host "no DBs found for $sourceServer/$sourceInstance" -ForegroundColor Yellow
            exit
        }
    }
    $sourceDbNames = @($dbresults.vms.vmDocument.objectName)
    if(! $includeSystemDBs){
        $sourceDbNames = $sourceDbNames | Where-Object {($_ -split '/')[-1] -notin @('Master', 'Model', 'MSDB')}
    }
    # exportFileInfo
    if($exportPaths){
        $fileInfoVec = @()
        foreach($vm in $dbresults.vms){
            if($vm.vmDocument.objectId.entity.sqlEntity.PSObject.Properties['dbFileInfoVec']){
                $dbName = $vm.vmDocument.objectName
                $fileInfo = $vm.vmDocument.objectId.entity.sqlEntity.dbFileInfoVec
                $fileInfoVec = @($fileInfoVec + @{
                    'name' = $dbName
                    'fileInfo' = $fileInfo
                })
            }
        }
        $fileInfoVec | ConvertTo-JSON -Depth 99 | Out-File -FilePath $exportFilePath
        "Exported file paths to $exportFilePath"
        exit 0
    }
}


if($sourceDbNames.Count -eq 0){
    Write-Host "No DBs specified for restore" -ForegroundColor Yellow
    exit
}

if($sourceDbNames.Count -gt 1 -and $targetDB){
    Write-Host "Can't specify -targetDB when more than one database is speficified. Please use -prefix or -suffix for renaming" -ForegroundColor Yellow
    exit
}

# find target server
$targetEntity = (api get protectionSources/registrationInfo?environments=kSQL).rootNodes | Where-Object { $_.rootNode.name -eq $targetServer }
if($null -eq $targetEntity){
    Write-Host "Target Server $targetServer Not Found" -ForegroundColor Yellow
    exit 1
}
$targetSQLApp = $targetEntity.applications | Where-Object environment -eq 'kSQL'

$restoreDate = Get-Date -UFormat '%Y-%m-%d_%H:%M:%S'

if($logTime){
    $logTimeUsecs = dateToUsecs $logTime
}

# recovery params
$recoveryParamNum = 1
$dbsSelected = 0
$recoveryIds = @()
$recoveryParams = @{
    "name" = "Recover_MS_SQL_$($sourceServer)_$($restoreDate)_$($recoveryParamNum)";
    "snapshotEnvironment" = "kSQL";
    "mssqlParams" = @{
        "recoveryAction" = "RecoverApps";
        "recoverAppParams" = @()
    }
}

foreach($sourceDbName in $sourceDbNames | Sort-Object){
    if(! $sourceDbName.Contains('/')){
        if($sourceInstance){
            $sourceDbName = "$sourceInstance/$sourceDbName"
        }else{
            $sourceDbName = "MSSQLSERVER/$sourceDbName"
        }
    }
    $thisSourceInstance, $shortDbName = $sourceDbName -split '/'    
    $search = api get -v2 "data-protect/search/protected-objects?snapshotActions=RecoverApps&searchString=$sourceDbName&environments=kSQL"
    $search.objects = $search.objects | Where-Object name -eq $sourceDbName
    $search.objects = $search.objects | Where-Object {$_.mssqlParams.hostInfo.name -eq $sourceServer -or $_.mssqlParams.aagInfo.name -eq $sourceServer}
    if($search.objects.Count -eq 0){
        Write-Host "$sourceDbName not found on server $sourceServer" -ForegroundColor Yellow
        continue
    }
    Write-Host "$($search.objects[0].name)"
    $thisSourceServer = $search.objects[0].mssqlParams.hostInfo.name
    if($targetServer -eq $sourceServer){
        $thisTargetServer = $thisSourceServer
    }else{
        $thisTargetServer = $targetServer
    }

    $latestSnapshotInfo = ($search.objects[0].latestSnapshotsInfo | Sort-Object -Property protectionRunStartTimeUsecs)[-1]
    $clusterId, $clusterIncarnationId, $jobId = $latestSnapshotInfo.protectionGroupId -split ':'

    # something about aag GET https://ve4/irisservices/api/v1/public/protectionSources/sqlAagHostsAndDatabases?sqlProtectionSourceIds=3705
    $pitQuery = @{
        "jobUids" = @(
            @{
                "clusterId" = [int64]$clusterId;
                "clusterIncarnationId" = [int64]$clusterIncarnationId;
                "id" = [int64]$jobId
            }
        );
        "environment" = "kSQL";
        "protectionSourceId" = $search.objects[0].id;
        "startTimeUsecs" = 0;
        "endTimeUsecs" = dateToUsecs
    }
    $logsAvailable = $True
    $logs = api post restore/pointsForTimeRange $pitQuery
    $timeRanges = $logs.timeRanges
    if(!$timeRanges){
        $logsAvailable = $False
    }
    $fullSnapshotInfo = $logs.fullSnapshotInfo
    if($logsAvailable){
        $logTimeValid = $False
        if($logTime -or $latest){
            foreach($timeRange in $timeRanges | Sort-Object -Property endTimeUsecs -Descending){
                if($latest){
                    $selectedPIT = $timeRange.endTimeUsecs
                    $logTimeValid = $True
                    break
                }
                if($logTimeUsecs -ge $timeRange.startTimeUsecs){
                    if($logTimeUsecs -ge $timeRange.endTimeUsecs){
                        $selectedPIT = $timeRange.endTimeUsecs
                    }else{
                        $selectedPIT = $logTimeUsecs
                    }
                    $logTimeValid = $True
                    break
                }
                $lastTimeRange = $timeRange
            }
            if($logTimeValid -eq $False){
                $selectedPIT = $lastTimeRange.startTimeUsecs
            }
            $fullSnapshot = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending | Where-Object {$_.restoreInfo.startTimeUsecs -le $selectedPIT})[0]
            $runStartTimeUsecs = $fullSnapshot.restoreInfo.startTimeUsecs
        }else{
            $fullSnapshot = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending)[0]
            $selectedPIT = $runStartTimeUsecs = $fullSnapshot.restoreInfo.startTimeUsecs
        }
    }else{
        if($logTime){
            $fullSnapshot = ($fullSnapshotInfo | Sort-Object -Property {$_.restoreInfo.startTimeUsecs} -Descending | Where-Object {$_.restoreInfo.startTimeUsecs -le $logTimeUsecs})[0]
            $selectedPIT = $runStartTimeUsecs = $fullSnapshot.restoreInfo.startTimeUsecs
        }else{
            $selectedPIT = $runStartTimeUsecs = $search.objects[0].latestSnapshotsInfo[0].protectionRunStartTimeUsecs
        }       
    }
    if($logTimeUsecs -and $logTimeUsecs -gt $selectedPIT){
        Write-Host "    Best available PIT is $(usecsToDate $selectedPIT)" -ForegroundColor Yellow
    }elseif($logTimeUsecs -and $logTimeUsecs -lt $selectedPIT){
        Write-Host "    Best available PIT is $(usecsToDate $selectedPIT)" -ForegroundColor Yellow
    }
    Write-Host "    Selected Snapshot $(usecsToDate $runStartTimeUsecs)"
    Write-Host "    Selected PIT $(usecsToDate $selectedPIT)"
    
    $search2 = api get -v2 "data-protect/search/protected-objects?snapshotActions=RecoverApps&searchString=$sourceDbName&protectionGroupIds=$($latestSnapshotInfo.protectionGroupId)&filterSnapshotToUsecs=$runStartTimeUsecs&filterSnapshotFromUsecs=$runStartTimeUsecs&environments=kSQL"
    $search2.objects = $search2.objects | Where-Object {$_.mssqlParams.hostInfo.name -eq $thisSourceServer}
    $search2.objects = $search2.objects | Where-Object {$_.name -eq $sourceDbName}

    # recover to original instance
    $thisParam  = @{
        "snapshotId" = $search2.objects[0].latestSnapshotsInfo[0].localSnapshotInfo.snapshotId;
        "targetEnvironment" = "kSQL";
        "sqlTargetParams" = @{
            "recoverToNewSource" = $false;
            "originalSourceConfig" = @{
                "restoreTimeUsecs" = $selectedPIT;
                "keepCdc" = $false;
                "withNoRecovery" = $false;
                "captureTailLogs" = $false
            }
        }
    }
    if($logsAvailable){
        if($noStop){
            $thisParam['pointInTimeUsecs'] = (3600 + (datetousecs (Get-Date)) / 1000000)
        }else{
            $thisParam['pointInTimeUsecs'] = $selectedPIT
        }
    }
    $targetConfig = $thisParam.sqlTargetParams.originalSourceConfig
    if($captureTailLogs){
        $targetConfig.captureTailLogs = $True        
    }

    # rename DB
    $newDbName = $shortDbName
    $renameDB = $false
    if($targetDB -or $prefix -or $suffix){
        $renameDB = $True
        if($targetDB){
            $newDbName = $targetDB
        }
        if($prefix){
            $newDbName = "$($prefix)-$($newDbName)"
        }
        if($suffix){
            $newDbName = "$($newDbName)-$($suffix)"
        }
        $thisParam.sqlTargetParams.originalSourceConfig.newDatabaseName = $newDbName
    }

    # recover to alternate instance
    $alternateInstance = $false
    if($targetServer -ne $thisSourceServer -or ($targetInstance -and $targetInstance -ne $thisSourceInstance)){
        $alternateInstance = $True
        if(! $targetInstance){
            $targetInstance = 'MSSQLSERVER'
        }
        $thisParam.sqlTargetParams = @{
            "recoverToNewSource" = $true;
            "newSourceConfig" = @{
                "host" = @{
                    "id" = $targetEntity.rootNode.id
                };
                "instanceName" = $targetInstance;
                "keepCdc" = $false;
                "withNoRecovery" = $false;
                "databaseName" = $newDbName
            }
        }

        $targetConfig = $thisParam.sqlTargetParams.newSourceConfig

        if($logsAvailable){
            if($noStop){
                $targetConfig['restoreTimeUsecs'] = (3600 + (datetousecs (Get-Date)) / 1000000)
            }else{
                $targetConfig['restoreTimeUsecs'] = $selectedPIT
            }
        }
        if($overWrite){
            $targetConfig['overwritingPolicy'] = 'Overwrite'
        }
    }else{
        if($renameDB -eq $false){
            if(! $overWrite){
                Write-Host "Please use -overwrite to overwrite original database(s)" -ForegroundColor Yellow
                exit 1
            }
        }
    }

    # file destinations
    if($alternateInstance -eq $True -or $renameDB -eq $True){
        # use source paths
        $secondaryFileLocation = $null
        if($useSourcePaths){
            $dbFileInfoVec = $null
            if($importedFileInfo){
                $importedDBFileInfo = $importedFileInfo | Where-Object {$_.name -eq $sourceDbName}
                if($importedDBFileInfo){
                    $dbFileInfoVec = $importedDBFileInfo.fileInfo                    
                }
            }else{
                $fileSearch = api get "/searchvms?environment=SQL&entityIds=$($search2.objects[0].id)"
                if($fileSearch.vms[0].vmDocument.objectId.entity.sqlEntity.PSObject.Properties['dbFileInfoVec']){
                    $dbFileInfoVec = $fileSearch.vms[0].vmDocument.objectId.entity.sqlEntity.dbFileInfoVec
                }
            }
            if(! $dbFileInfoVec){
                if(! $mdfFolder){
                    Write-Host "File info not found for $sourceDBName, please use -mdfFolder, -ldfFolder, -ndfFolders" -ForegroundColor Yellow
                    exit
                }
            }
            $mdfFolderFound = $False
            $ldfFolderFound = $False
            $secondaryFileLocation = @()
            foreach($datafile in $dbFileInfoVec){
                $path = $datafile.fullPath.subString(0, $datafile.fullPath.LastIndexOf('\'))
                $fileName = $datafile.fullPath.subString($datafile.fullPath.LastIndexOf('\') + 1)
                if($datafile.type -eq 0){
                    if($mdfFolderFound -eq $False){
                        $mdfFolder = $path
                        $mdfFolderFound = $True
                    }else{
                        $secondaryFileLocation = @($secondaryFileLocation + @{"filenamePattern" = $datafile.fullPath; "directory" = $path})
                    }
                }
                if($datafile.type -eq 1){
                    if($ldfFolderFound -eq $False){
                        $ldfFolder = $path
                        $ldfFolderFound = $True
                    }
                }
            }
        }

        if(! $mdfFolder -or ! $ldfFolder){
            Write-Host "-mdfFolder required when restoring to an alternate database" -ForegroundColor Yellow
            exit 1
        }
        $targetConfig['dataFileDirectoryLocation'] = $mdfFolder
        $targetConfig['logFileDirectoryLocation'] = $ldfFolder
        if($secondaryFileLocation){
            $targetConfig['secondaryDataFilesDirList'] = $secondaryFileLocation
        }elseif($ndfFolders){
            $ndfParams = @()
            foreach($key in $ndfFolders.Keys){
                $ndfParams = @($ndfParams + @{"filenamePattern" = "$key"; "directory" = $ndfFolders["$key"]})
            }
            $targetConfig['secondaryDataFilesDirList'] = @($ndfParams)
        }
    }

    # no recovery
    if($noRecovery){
        $targetConfig['withNoRecovery'] = $True
    }

    # keep CDC
    if($keepCdc){
        $targetConfig['keepCdc'] = $True
    }

    # add this param to recovery params
    $recoveryParams.mssqlParams.recoverAppParams = @($recoveryParams.mssqlParams.recoverAppParams + $thisParam)
    $dbsSelected += 1

    # perform recovery group
    if($dbsSelected -ge $dbsPerRecovery){
        # perform this recovery
        $recovery = api post -v2 data-protect/recoveries $recoveryParams
        if(! $recovery.id){
            exit 1
        }
        $recoveryIds = @($recoveryIds + $recovery.id)
        # reset params for next recovery
        $recoveryParamNum += 1
        $dbsSelected = 0
        $recoveryParams = @{
            "name" = "Recover_MS_SQL_$($sourceServer)_$($restoreDate)_$($recoveryParamNum)";
            "snapshotEnvironment" = "kSQL";
            "mssqlParams" = @{
                "recoveryAction" = "RecoverApps";
                "recoverAppParams" = @()
            }
        }
    }
}

# perform last recovery group (if any)
if($recoveryParams.mssqlParams.recoverAppParams.Count -gt 0){
    $recovery = api post -v2 data-protect/recoveries $recoveryParams
    if(! $recovery.id){
        exit 1
    }
    $recoveryIds = @($recoveryIds + $recovery.id)
}

# wait for completion
$failuresDetected = $False
if($wait -and $recoveryIds.Count -gt 0){
    $finishedStates = @('Succeeded', 'Canceled', 'Failed', 'Warning', 'SucceededWithWarning')
    Write-Host "`nWaiting for recoveries to complete...`n"
    Start-Sleep $sleepTime
    foreach($recoveryId in $recoveryIds){
        $thisRecovery = api get -v2 "data-protect/recoveries/$recoveryId"
        while($thisRecovery.status -notin $finishedStates){
            Start-Sleep $sleepTime
            $thisRecovery = api get -v2 "data-protect/recoveries/$recoveryId"
        }
        $childRecoveries = api get -v2 "data-protect/recoveries?returnOnlyChildRecoveries=true&ids=$recoveryId"
        foreach($childRecovery in $childRecoveries.recoveries | Sort-Object -Property {$_.mssqlParams.recoverAppParams[0].objectInfo.name}){
            $dbName = $childRecovery.mssqlParams.recoverAppParams[0].objectInfo.name
            $status = $childRecovery.status
            Write-Host "$dbName completed with status: $status"
            if($childRecovery.messages){
                Write-Host "$($childRecovery.messages[0])`n" -ForegroundColor Yellow
            }
            if($status -ne 'Succeeded'){
                $failuresDetected = $True
            }
        }
    }
    if($failuresDetected -or $recoveryIds.Count -eq 0){
        Write-Host "`nFailures Detected`n"
        exit 1
    }else{
        Write-Host "`nRestores Completed Successfully"
        exit 0
    }
}
exit 0
