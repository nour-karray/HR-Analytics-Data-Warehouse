param(
    [string]$PackagePath = (Join-Path $PSScriptRoot 'Dimensions.dtsx'),
    [string]$SortTemplatePath = (Join-Path $PSScriptRoot 'Facts.dtsx')
)

$ErrorActionPreference = 'Stop'

$DtsNamespace = 'www.microsoft.com/SqlServer/Dts'
$ConversionComponentName = 'Conversion de donn' + [char]0x00E9 + 'es'
$ConversionInputName = 'Entr' + [char]0x00E9 + 'e de conversion de donn' + [char]0x00E9 + 'es'
$ConversionOutputName = 'Sortie de conversion de donn' + [char]0x00E9 + 'es'
$SortInputName = 'Entr' + [char]0x00E9 + 'e de tri'
$SortOutputName = 'Sortie de tri'
$DestinationInputName = 'Entr' + [char]0x00E9 + 'e de destination OLE DB'

function New-GuidText {
    '{' + ([guid]::NewGuid().ToString().ToUpperInvariant()) + '}'
}

function Set-DtsAttr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$LocalName,
        [string]$Value
    )

    if ($Element.HasAttribute($LocalName, $DtsNamespace)) {
        [void]$Element.SetAttribute($LocalName, $DtsNamespace, $Value)
        return
    }

    $attr = $Element.Attributes.GetNamedItem("DTS:$LocalName")
    if ($null -ne $attr) {
        $attr.Value = $Value
        return
    }
}

function Set-Attr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Name,
        [string]$Value
    )

    [void]$Element.SetAttribute($Name, $Value)
}

function Remove-Attr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Name
    )

    if ($Element.HasAttribute($Name)) {
        $Element.RemoveAttribute($Name)
    }
}

function Clear-Children {
    param([System.Xml.XmlNode]$Node)

    while ($Node.HasChildNodes) {
        [void]$Node.RemoveChild($Node.FirstChild)
    }
}

function Replace-InNode {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$OldValue,
        [string]$NewValue
    )

    if ($Node.NodeType -in [System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::CDATA) {
        if ($Node.Value -and $Node.Value.Contains($OldValue)) {
            $Node.Value = $Node.Value.Replace($OldValue, $NewValue)
        }
    }

    if ($Node.Attributes) {
        foreach ($attribute in @($Node.Attributes)) {
            if ($attribute.Value -and $attribute.Value.Contains($OldValue)) {
                $attribute.Value = $attribute.Value.Replace($OldValue, $NewValue)
            }
        }
    }

    foreach ($child in @($Node.ChildNodes)) {
        Replace-InNode -Node $child -OldValue $OldValue -NewValue $NewValue
    }
}

function Refresh-DtsIds {
    param(
        [System.Xml.XmlElement]$Element,
        [System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    foreach ($node in @($Element.SelectNodes('.//*[@DTS:DTSID]', $NamespaceManager))) {
        Set-DtsAttr -Element $node -LocalName 'DTSID' -Value (New-GuidText)
    }

    if ($Element.HasAttribute('DTSID', $DtsNamespace)) {
        Set-DtsAttr -Element $Element -LocalName 'DTSID' -Value (New-GuidText)
    }
}

if (-not (Test-Path -LiteralPath $PackagePath)) {
    throw "Package not found: $PackagePath"
}

if (-not (Test-Path -LiteralPath $SortTemplatePath)) {
    throw "Sort template not found: $SortTemplatePath"
}

$packageDoc = New-Object System.Xml.XmlDocument
$packageDoc.PreserveWhitespace = $true
$packageDoc.Load($PackagePath)

$namespaceManager = New-Object System.Xml.XmlNamespaceManager($packageDoc.NameTable)
$namespaceManager.AddNamespace('DTS', $DtsNamespace)

$sortTemplateDoc = New-Object System.Xml.XmlDocument
$sortTemplateDoc.PreserveWhitespace = $true
$sortTemplateDoc.Load($SortTemplatePath)
$sortTemplate = [System.Xml.XmlElement]$sortTemplateDoc.SelectSingleNode("//component[@componentClassID='Microsoft.Sort']")
if ($null -eq $sortTemplate) {
    throw 'Sort component template not found.'
}

$executablesNode = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:Executables', $namespaceManager)

foreach ($taskName in @('DimDate_Termination', 'DimDate_Review')) {
    $taskNode = $executablesNode.SelectSingleNode("DTS:Executable[@DTS:ObjectName='$taskName']", $namespaceManager)
    if ($null -ne $taskNode) {
        [void]$executablesNode.RemoveChild($taskNode)
    }
}

$dimDateTask = [System.Xml.XmlElement]$executablesNode.SelectSingleNode("DTS:Executable[@DTS:ObjectName='DimDate_Hire']", $namespaceManager)
if ($null -eq $dimDateTask) {
    $dimDateTask = [System.Xml.XmlElement]$executablesNode.SelectSingleNode("DTS:Executable[@DTS:ObjectName='DimDate']", $namespaceManager)
}
if ($null -eq $dimDateTask) {
    throw 'DimDate task not found.'
}

Replace-InNode -Node $dimDateTask -OldValue 'Package\DimDate_Hire' -NewValue 'Package\DimDate'
Set-DtsAttr -Element $dimDateTask -LocalName 'ObjectName' -Value 'DimDate'
Set-DtsAttr -Element $dimDateTask -LocalName 'refId' -Value 'Package\DimDate'
Refresh-DtsIds -Element $dimDateTask -NamespaceManager $namespaceManager

$lookupComponent = [System.Xml.XmlElement]$dimDateTask.SelectSingleNode(".//component[@componentClassID='Microsoft.Lookup']")
if ($null -eq $lookupComponent) {
    throw 'Lookup component not found in DimDate.'
}

$componentsParent = $lookupComponent.ParentNode
$sortComponent = [System.Xml.XmlElement]$packageDoc.ImportNode($sortTemplate, $true)
[void]$componentsParent.ReplaceChild($sortComponent, $lookupComponent)

Set-Attr -Element $sortComponent -Name 'refId' -Value 'Package\DimDate\Trier'
Set-Attr -Element $sortComponent -Name 'name' -Value 'Trier'
$sortComponent.SelectSingleNode("properties/property[@name='EliminateDuplicates']").InnerText = 'true'

$sortInputNode = [System.Xml.XmlElement]$sortComponent.SelectSingleNode('inputs/input[1]')
$sortOutputNode = [System.Xml.XmlElement]$sortComponent.SelectSingleNode('outputs/output[1]')
$sortInputParent = $sortInputNode.SelectSingleNode('inputColumns')
$sortOutputParent = $sortOutputNode.SelectSingleNode('outputColumns')
$templateSortInput = [System.Xml.XmlElement]$sortInputParent.SelectSingleNode('inputColumn').CloneNode($true)
$templateSortOutput = [System.Xml.XmlElement]$sortOutputParent.SelectSingleNode('outputColumn').CloneNode($true)

Set-Attr -Element $sortInputNode -Name 'refId' -Value "Package\DimDate\Trier.Inputs[$SortInputName]"
Set-Attr -Element $sortOutputNode -Name 'refId' -Value "Package\DimDate\Trier.Outputs[$SortOutputName]"
Set-Attr -Element $sortOutputNode -Name 'isSorted' -Value 'true'

Clear-Children -Node $sortInputParent
Clear-Children -Node $sortOutputParent

$conversionLineage = "Package\DimDate\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[NewDateofHire]"
$sortLineage = "Package\DimDate\Trier.Outputs[$SortOutputName].Columns[NewDateofHire]"

$sortInput = [System.Xml.XmlElement]$templateSortInput.CloneNode($true)
Set-Attr -Element $sortInput -Name 'refId' -Value "Package\DimDate\Trier.Inputs[$SortInputName].Columns[NewDateofHire]"
Set-Attr -Element $sortInput -Name 'cachedName' -Value 'NewDateofHire'
Set-Attr -Element $sortInput -Name 'lineageId' -Value $conversionLineage
Set-Attr -Element $sortInput -Name 'cachedDataType' -Value 'dbDate'
Remove-Attr -Element $sortInput -Name 'cachedCodepage'
Remove-Attr -Element $sortInput -Name 'cachedLength'
$sortInput.SelectSingleNode("properties/property[@name='NewComparisonFlags']").InnerText = '0'
$sortInput.SelectSingleNode("properties/property[@name='NewSortKeyPosition']").InnerText = '1'
[void]$sortInputParent.AppendChild($sortInput)

$sortOutput = [System.Xml.XmlElement]$templateSortOutput.CloneNode($true)
Set-Attr -Element $sortOutput -Name 'refId' -Value $sortLineage
Set-Attr -Element $sortOutput -Name 'lineageId' -Value $sortLineage
Set-Attr -Element $sortOutput -Name 'name' -Value 'NewDateofHire'
Set-Attr -Element $sortOutput -Name 'dataType' -Value 'dbDate'
Set-Attr -Element $sortOutput -Name 'sortKeyPosition' -Value '1'
Remove-Attr -Element $sortOutput -Name 'codePage'
Remove-Attr -Element $sortOutput -Name 'length'
$sortOutput.SelectSingleNode("properties/property[@name='SortColumnId']").InnerText = "#{$conversionLineage}"
[void]$sortOutputParent.AppendChild($sortOutput)

$destinationComponent = [System.Xml.XmlElement]$dimDateTask.SelectSingleNode(".//component[@componentClassID='Microsoft.OLEDBDestination']")
$destInputNode = [System.Xml.XmlElement]$destinationComponent.SelectSingleNode('inputs/input[1]')
$destInputParent = $destInputNode.SelectSingleNode('inputColumns')
$destExternalParent = $destInputNode.SelectSingleNode('externalMetadataColumns')
$templateDestInput = [System.Xml.XmlElement]$destInputParent.SelectSingleNode('inputColumn').CloneNode($true)
$templateDestExternal = [System.Xml.XmlElement]$destExternalParent.SelectSingleNode('externalMetadataColumn').CloneNode($true)

Clear-Children -Node $destInputParent
Clear-Children -Node $destExternalParent

$keyColumn = [System.Xml.XmlElement]$templateDestExternal.CloneNode($true)
Set-Attr -Element $keyColumn -Name 'refId' -Value "Package\DimDate\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[DateKey]"
Set-Attr -Element $keyColumn -Name 'name' -Value 'DateKey'
Set-Attr -Element $keyColumn -Name 'dataType' -Value 'i4'
Remove-Attr -Element $keyColumn -Name 'length'
Remove-Attr -Element $keyColumn -Name 'codePage'
[void]$destExternalParent.AppendChild($keyColumn)

$destInput = [System.Xml.XmlElement]$templateDestInput.CloneNode($true)
Set-Attr -Element $destInput -Name 'refId' -Value "Package\DimDate\Destination OLE DB.Inputs[$DestinationInputName].Columns[NewDateofHire]"
Set-Attr -Element $destInput -Name 'cachedName' -Value 'NewDateofHire'
Set-Attr -Element $destInput -Name 'externalMetadataColumnId' -Value "Package\DimDate\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[FullDate]"
Set-Attr -Element $destInput -Name 'lineageId' -Value $sortLineage
Set-Attr -Element $destInput -Name 'cachedDataType' -Value 'dbDate'
Remove-Attr -Element $destInput -Name 'cachedCodepage'
Remove-Attr -Element $destInput -Name 'cachedLength'
[void]$destInputParent.AppendChild($destInput)

$externalFullDate = [System.Xml.XmlElement]$templateDestExternal.CloneNode($true)
Set-Attr -Element $externalFullDate -Name 'refId' -Value "Package\DimDate\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[FullDate]"
Set-Attr -Element $externalFullDate -Name 'name' -Value 'FullDate'
Set-Attr -Element $externalFullDate -Name 'dataType' -Value 'dbDate'
Remove-Attr -Element $externalFullDate -Name 'length'
Remove-Attr -Element $externalFullDate -Name 'codePage'
[void]$destExternalParent.AppendChild($externalFullDate)

$pipelineNode = $dimDateTask.SelectSingleNode('.//*[local-name()="pipeline"]')
$pathsParent = $pipelineNode.SelectSingleNode('*[local-name()="paths"]')
Clear-Children -Node $pathsParent

$path1 = $packageDoc.CreateElement('path')
Set-Attr -Element $path1 -Name 'refId' -Value 'Package\DimDate.Paths[Sortie de source de fichier plat]'
Set-Attr -Element $path1 -Name 'name' -Value 'Sortie de source de fichier plat'
Set-Attr -Element $path1 -Name 'startId' -Value 'Package\DimDate\Source du fichier plat.Outputs[Sortie de source de fichier plat]'
Set-Attr -Element $path1 -Name 'endId' -Value "Package\DimDate\$ConversionComponentName.Inputs[$ConversionInputName]"
[void]$pathsParent.AppendChild($path1)

$path2 = $packageDoc.CreateElement('path')
Set-Attr -Element $path2 -Name 'refId' -Value "Package\DimDate.Paths[$ConversionOutputName]"
Set-Attr -Element $path2 -Name 'name' -Value $ConversionOutputName
Set-Attr -Element $path2 -Name 'startId' -Value "Package\DimDate\$ConversionComponentName.Outputs[$ConversionOutputName]"
Set-Attr -Element $path2 -Name 'endId' -Value "Package\DimDate\Trier.Inputs[$SortInputName]"
[void]$pathsParent.AppendChild($path2)

$path3 = $packageDoc.CreateElement('path')
Set-Attr -Element $path3 -Name 'refId' -Value "Package\DimDate.Paths[$SortOutputName]"
Set-Attr -Element $path3 -Name 'name' -Value $SortOutputName
Set-Attr -Element $path3 -Name 'startId' -Value "Package\DimDate\Trier.Outputs[$SortOutputName]"
Set-Attr -Element $path3 -Name 'endId' -Value "Package\DimDate\Destination OLE DB.Inputs[$DestinationInputName]"
[void]$pathsParent.AppendChild($path3)

Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'VersionGUID' -Value (New-GuidText)

$designProperty = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:DesignTimeProperties', $namespaceManager)
if ($null -ne $designProperty) {
    Clear-Children -Node $designProperty
    [void]$designProperty.AppendChild($packageDoc.CreateCDataSection('<?xml version="1.0"?><Objects Version="8"></Objects>'))
}

$packageDoc.Save($PackagePath)

[pscustomobject]@{
    PackagePath = $PackagePath
    DimDateMode = 'DateofHire only'
    Flow = 'Source -> Conversion -> Sort (dedupe) -> Destination'
} | Format-List
