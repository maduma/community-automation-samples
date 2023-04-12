### Usage: ./addRemoteCluster.ps1 -localVip 192.168.1.198 -localUsername admin -remoteVip 10.1.1.202 -remoteUsername admin

### Usage: ./addRemoteCluster.ps1 -localVip 192.168.1.198 `
#                                 -localUsername admin `
#                                 -localStorageDomain DefaultStorageDomain `
#                                 -remoteVip 10.1.1.202 `
#                                 -remoteUsername admin `
#                                 -remoteStorageDomain defaultStorageDomain

### process commandline arguments
[CmdletBinding()]
param (
    [Parameter(Mandatory = $True)][string]$localVip,      #local cluster to connect to
    [Parameter(Mandatory = $True)][string]$localUsername, #local username
    [Parameter()][string]$localDomain = 'local',          #local user domain name
    [Parameter()][string]$localPassword = $null,
    [Parameter()][string]$localStorageDomain = 'DefaultStorageDomain', #local storage domain
    [Parameter(Mandatory = $True)][string]$remoteVip,      #remote cluster to connect to
    [Parameter(Mandatory = $True)][string]$remoteUsername, #remote username
    [Parameter()][string]$remoteDomain = 'local',          #remote user domain name
    [Parameter()][string]$remotePassword = $null,
    [Parameter()][string]$remoteStorageDomain = 'DefaultStorageDomain', #remote storage domain
    [Parameter()][switch]$remoteAccess # enable remote access
)

### source the cohesity-api helper code
. $(Join-Path -Path $PSScriptRoot -ChildPath cohesityCluster.ps1)

### authenticate with both clusters
$localCluster = connectCohesityCluster -server $localVip -username $localUsername -domain $localDomain -password $localPassword
$remoteCluster = connectCohesityCluster -server $remoteVip -username $remoteUsername -domain $remoteDomain -password $remotePassword

### get cluster info
$localClusterInfo= $localCluster.get('cluster')
$remoteClusterInfo= $remoteCluster.get('cluster')
$localStorageDomainId = ($localCluster.get('viewBoxes') | Where-Object { $_.name -eq $localStorageDomain }).id
$remoteStorageDomainId = ($remoteCluster.get('viewBoxes') | Where-Object { $_.name -eq $remoteStorageDomain }).id

### add remoteCluster as partner on localCluster
$localToRemote = @{
    'name' = $remoteClusterInfo.name;
    'clusterIncarnationId' = $remoteClusterInfo.incarnationId;
    'clusterId' = $remoteClusterInfo.id;
    'remoteIps' = @(
        $remoteVip
    );
    'allEndpointsReachable' = $true;
    'viewBoxPairInfo' = @(
        @{
            'localViewBoxId' = $localStorageDomainId;
            'localViewBoxName' = $localStorageDomain;
            'remoteViewBoxId' = $remoteStorageDomainId;
            'remoteViewBoxName' = $remoteStorageDomain
        }
    );
    'userName' = $remoteUsername;
    'password' = $remoteCluster.getPwd();
    'compressionEnabled' = $true;
    'purposeReplication' = $true;
    'purposeRemoteAccess' = $false
}

### add localCluster as partner on remoteCluster
$remoteToLocal = @{
    'name' = $localClusterInfo.name;
    'clusterIncarnationId' = $localClusterInfo.incarnationId;
    'clusterId' = $localClusterInfo.id;
    'remoteIps' = @(
        $localVip
    );
    'allEndpointsReachable' = $true;
    'viewBoxPairInfo' = @(
        @{
            'localViewBoxId' = $remoteStorageDomainId;
            'localViewBoxName' = $remoteStorageDomain;
            'remoteViewBoxId' = $localStorageDomainId;
            'remoteViewBoxName' = $localStorageDomain
        }
    );
    'userName' = $localUsername;
    'password' = $localCluster.getPwd();
    'compressionEnabled' = $true;
    'purposeReplication' = $true;
    'purposeRemoteAccess' = $false
}

if($remoteAccess){
    $localToRemote.purposeRemoteAccess = $True
    $remoteToLocal.purposeRemoteAccess = $True
}

### join clusters

$localPartner = $localCluster.post('remoteClusters', $localToRemote)
if($localPartner.name){
    "Added replication partnership $($localClusterInfo.name) -> $($localPartner.name)"
}

$remotePartner = $remoteCluster.post('remoteClusters', $remoteToLocal)
if($remotePartner.name){
    "Added replication partnership $($remotePartner.name) <- $($remoteClusterInfo.name)"
}
