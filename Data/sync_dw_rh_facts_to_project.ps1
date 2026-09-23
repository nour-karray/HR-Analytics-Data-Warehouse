param(
    [string]$FactsPackagePath = (Join-Path $PSScriptRoot 'Facts.dtsx'),
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [Parameter(Mandatory = $true)]
    [string]$ProjectPackagePath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $FactsPackagePath)) {
    throw "Facts package not found: $FactsPackagePath"
}

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project file not found: $ProjectPath"
}

[xml]$factsDoc = Get-Content -LiteralPath $FactsPackagePath
$factsNs = New-Object System.Xml.XmlNamespaceManager($factsDoc.NameTable)
$factsNs.AddNamespace('DTS', 'www.microsoft.com/SqlServer/Dts')

$packageRoot = $factsDoc.SelectSingleNode('/DTS:Executable', $factsNs)
if ($null -eq $packageRoot) {
    throw 'Unable to parse Facts.dtsx package root.'
}

$packageId = $packageRoot.GetAttribute('DTSID', 'www.microsoft.com/SqlServer/Dts')
$packageName = $packageRoot.GetAttribute('ObjectName', 'www.microsoft.com/SqlServer/Dts')
$versionBuild = $packageRoot.GetAttribute('VersionBuild', 'www.microsoft.com/SqlServer/Dts')
$versionGuid = $packageRoot.GetAttribute('VersionGUID', 'www.microsoft.com/SqlServer/Dts')

Copy-Item -LiteralPath $FactsPackagePath -Destination $ProjectPackagePath -Force

[xml]$projectDoc = Get-Content -LiteralPath $ProjectPath
$projectNs = New-Object System.Xml.XmlNamespaceManager($projectDoc.NameTable)
$projectNs.AddNamespace('SSIS', 'www.microsoft.com/SqlServer/SSIS')

$packagesNode = $projectDoc.SelectSingleNode('/Project/DeploymentModelSpecificContent/Manifest/SSIS:Project/SSIS:Packages', $projectNs)
$packageInfoNode = $projectDoc.SelectSingleNode('/Project/DeploymentModelSpecificContent/Manifest/SSIS:Project/SSIS:DeploymentInfo/SSIS:PackageInfo', $projectNs)
if ($null -eq $packagesNode -or $null -eq $packageInfoNode) {
    throw 'Unable to locate package nodes in DW_RH.dtproj.'
}

$existingPackage = $packagesNode.SelectSingleNode("SSIS:Package[@SSIS:Name='Facts.dtsx']", $projectNs)
if ($null -eq $existingPackage) {
    $templatePackage = $packagesNode.SelectSingleNode("SSIS:Package[@SSIS:Name='Dimensions.dtsx']", $projectNs)
    if ($null -eq $templatePackage) {
        throw 'Dimensions.dtsx entry not found in project file.'
    }

    $newPackage = $templatePackage.CloneNode($true)
    $newPackage.SetAttribute('Name', 'www.microsoft.com/SqlServer/SSIS', 'Facts.dtsx')
    [void]$packagesNode.AppendChild($newPackage)
}

$existingMeta = $packageInfoNode.SelectSingleNode("SSIS:PackageMetaData[@SSIS:Name='Facts.dtsx']", $projectNs)
if ($null -eq $existingMeta) {
    $templateMeta = $packageInfoNode.SelectSingleNode("SSIS:PackageMetaData[@SSIS:Name='Dimensions.dtsx']", $projectNs)
    if ($null -eq $templateMeta) {
        throw 'Dimensions.dtsx metadata not found in project file.'
    }

    $newMeta = $templateMeta.CloneNode($true)
    $newMeta.SetAttribute('Name', 'www.microsoft.com/SqlServer/SSIS', 'Facts.dtsx')

    $properties = $newMeta.SelectSingleNode('SSIS:Properties', $projectNs)
    foreach ($property in @($properties.SelectNodes('SSIS:Property', $projectNs))) {
        $propName = $property.GetAttribute('Name', 'www.microsoft.com/SqlServer/SSIS')
        switch ($propName) {
            'ID' { $property.InnerText = $packageId }
            'Name' { $property.InnerText = $packageName }
            'VersionBuild' { $property.InnerText = $versionBuild }
            'VersionGUID' { $property.InnerText = $versionGuid }
        }
    }

    [void]$packageInfoNode.AppendChild($newMeta)
}
else {
    $properties = $existingMeta.SelectSingleNode('SSIS:Properties', $projectNs)
    foreach ($property in @($properties.SelectNodes('SSIS:Property', $projectNs))) {
        $propName = $property.GetAttribute('Name', 'www.microsoft.com/SqlServer/SSIS')
        switch ($propName) {
            'ID' { $property.InnerText = $packageId }
            'Name' { $property.InnerText = $packageName }
            'VersionBuild' { $property.InnerText = $versionBuild }
            'VersionGUID' { $property.InnerText = $versionGuid }
        }
    }
}

$projectDoc.Save($ProjectPath)

[pscustomobject]@{
    PackageId = $packageId
    VersionGuid = $versionGuid
    ProjectPackagePath = $ProjectPackagePath
} | Format-List
