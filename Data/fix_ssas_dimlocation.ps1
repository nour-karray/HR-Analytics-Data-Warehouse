param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'

$engineNs = 'http://schemas.microsoft.com/analysisservices/2003/engine'
$xsiNs = 'http://www.w3.org/2001/XMLSchema-instance'

function New-EngineElement {
    param(
        [xml]$Doc,
        [string]$Name
    )

    $Doc.CreateElement($Name, $engineNs)
}

function New-ColumnBindingSource {
    param(
        [xml]$Doc,
        [string]$TableId,
        [string]$ColumnId
    )

    $source = New-EngineElement -Doc $Doc -Name 'Source'
    $typeAttr = $Doc.CreateAttribute('xsi', 'type', $xsiNs)
    $typeAttr.Value = 'ColumnBinding'
    [void]$source.Attributes.Append($typeAttr)

    $table = New-EngineElement -Doc $Doc -Name 'TableID'
    $table.InnerText = $TableId
    [void]$source.AppendChild($table)

    $column = New-EngineElement -Doc $Doc -Name 'ColumnID'
    $column.InnerText = $ColumnId
    [void]$source.AppendChild($column)

    return $source
}

function New-KeyColumn {
    param(
        [xml]$Doc,
        [string]$DataType,
        [string]$TableId,
        [string]$ColumnId
    )

    $keyColumn = New-EngineElement -Doc $Doc -Name 'KeyColumn'
    $dt = New-EngineElement -Doc $Doc -Name 'DataType'
    $dt.InnerText = $DataType
    [void]$keyColumn.AppendChild($dt)
    [void]$keyColumn.AppendChild((New-ColumnBindingSource -Doc $Doc -TableId $TableId -ColumnId $ColumnId))
    return $keyColumn
}

function Ensure-NameColumn {
    param(
        [System.Xml.XmlElement]$AttributeNode,
        [string]$DataType,
        [string]$TableId,
        [string]$ColumnId,
        [System.Xml.XmlNamespaceManager]$Ns
    )

    $doc = $AttributeNode.OwnerDocument
    $existing = $AttributeNode.SelectSingleNode("a:NameColumn", $Ns)
    if ($existing -ne $null) {
        [void]$AttributeNode.RemoveChild($existing)
    }

    $nameColumn = New-EngineElement -Doc $doc -Name 'NameColumn'
    $dt = New-EngineElement -Doc $doc -Name 'DataType'
    $dt.InnerText = $DataType
    [void]$nameColumn.AppendChild($dt)
    [void]$nameColumn.AppendChild((New-ColumnBindingSource -Doc $doc -TableId $TableId -ColumnId $ColumnId))

    $keyColumns = $AttributeNode.SelectSingleNode("a:KeyColumns", $Ns)
    [void]$AttributeNode.InsertAfter($nameColumn, $keyColumns)
}

function Ensure-AttributeRelationshipsFromLocationKey {
    param(
        [System.Xml.XmlElement]$AttributeNode,
        [System.Xml.XmlNamespaceManager]$Ns
    )

    $doc = $AttributeNode.OwnerDocument
    $relationships = $AttributeNode.SelectSingleNode("a:AttributeRelationships", $Ns)
    if ($relationships -eq $null) {
        $relationships = New-EngineElement -Doc $doc -Name 'AttributeRelationships'
        $orderByNode = $AttributeNode.SelectSingleNode("a:OrderBy", $Ns)
        if ($orderByNode -ne $null) {
            [void]$AttributeNode.InsertBefore($relationships, $orderByNode)
        }
        else {
            [void]$AttributeNode.AppendChild($relationships)
        }
    }

    while ($relationships.HasChildNodes) {
        [void]$relationships.RemoveChild($relationships.FirstChild)
    }

    foreach ($relatedAttributeId in @('State', 'Zip')) {
        $relationship = New-EngineElement -Doc $doc -Name 'AttributeRelationship'
        $attributeId = New-EngineElement -Doc $doc -Name 'AttributeID'
        $attributeId.InnerText = $relatedAttributeId
        [void]$relationship.AppendChild($attributeId)

        $relationshipType = New-EngineElement -Doc $doc -Name 'RelationshipType'
        $relationshipType.InnerText = 'Flexible'
        [void]$relationship.AppendChild($relationshipType)

        [void]$relationships.AppendChild($relationship)
    }
}

function Set-KeyAttributeForLocation {
    param(
        [xml]$Doc,
        [System.Xml.XmlNamespaceManager]$Ns
    )

    $attribute = $Doc.SelectSingleNode("/a:Dimension/a:Attributes/a:Attribute[a:ID='Location Key']", $Ns)
    if ($null -eq $attribute) {
        throw "Attribut 'Location Key' introuvable dans Dim Location.dim"
    }

    $attribute.SelectSingleNode("a:Name", $Ns).InnerText = 'Location'

    $keyColumns = $attribute.SelectSingleNode("a:KeyColumns", $Ns)
    while ($keyColumns.HasChildNodes) {
        [void]$keyColumns.RemoveChild($keyColumns.FirstChild)
    }

    [void]$keyColumns.AppendChild((New-KeyColumn -Doc $Doc -DataType 'WChar' -TableId 'dbo_DimLocation' -ColumnId 'State'))
    [void]$keyColumns.AppendChild((New-KeyColumn -Doc $Doc -DataType 'WChar' -TableId 'dbo_DimLocation' -ColumnId 'Zip'))

    Ensure-NameColumn -AttributeNode $attribute -DataType 'WChar' -TableId 'dbo_DimLocation' -ColumnId 'Zip' -Ns $Ns
    Ensure-AttributeRelationshipsFromLocationKey -AttributeNode $attribute -Ns $Ns
}

function Ensure-LocationAttribute {
    param(
        [xml]$Doc,
        [System.Xml.XmlNamespaceManager]$Ns,
        [string]$AttributeId,
        [string]$ColumnId
    )

    $attributesNode = $Doc.SelectSingleNode("/a:Dimension/a:Attributes", $Ns)
    $existing = $Doc.SelectSingleNode("/a:Dimension/a:Attributes/a:Attribute[a:ID='$AttributeId']", $Ns)
    if ($existing -eq $null) {
        $template = $Doc.SelectSingleNode("/a:Dimension/a:Attributes/a:Attribute[a:ID='Location Key']", $Ns)
        $existing = [System.Xml.XmlElement]$template.CloneNode($true)
        [void]$attributesNode.AppendChild($existing)
    }

    $existing.SelectSingleNode("a:ID", $Ns).InnerText = $AttributeId
    $existing.SelectSingleNode("a:Name", $Ns).InnerText = $AttributeId

    $usage = $existing.SelectSingleNode("a:Usage", $Ns)
    if ($usage -ne $null) {
        [void]$existing.RemoveChild($usage)
    }

    $keyColumns = $existing.SelectSingleNode("a:KeyColumns", $Ns)
    while ($keyColumns.HasChildNodes) {
        [void]$keyColumns.RemoveChild($keyColumns.FirstChild)
    }

    [void]$keyColumns.AppendChild((New-KeyColumn -Doc $Doc -DataType 'WChar' -TableId 'dbo_DimLocation' -ColumnId $ColumnId))
    Ensure-NameColumn -AttributeNode $existing -DataType 'WChar' -TableId 'dbo_DimLocation' -ColumnId $ColumnId -Ns $Ns

    $existingRelationships = $existing.SelectSingleNode("a:AttributeRelationships", $Ns)
    if ($existingRelationships -ne $null) {
        [void]$existing.RemoveChild($existingRelationships)
    }
}

function Save-Xml {
    param(
        [xml]$Doc,
        [string]$Path
    )

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)

    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Doc.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
}

$dimPath = Join-Path $ProjectPath 'Dim Location.dim'
if (-not (Test-Path -LiteralPath $dimPath)) {
    throw "Fichier introuvable: $dimPath"
}

[xml]$dimDoc = Get-Content -LiteralPath $dimPath
$ns = New-Object System.Xml.XmlNamespaceManager($dimDoc.NameTable)
$ns.AddNamespace('a', $engineNs)
$ns.AddNamespace('xsi', $xsiNs)

Set-KeyAttributeForLocation -Doc $dimDoc -Ns $ns
Ensure-LocationAttribute -Doc $dimDoc -Ns $ns -AttributeId 'State' -ColumnId 'State'
Ensure-LocationAttribute -Doc $dimDoc -Ns $ns -AttributeId 'Zip' -ColumnId 'Zip'
Save-Xml -Doc $dimDoc -Path $dimPath

$cubePath = Join-Path $ProjectPath 'Cube_RH.cube'
if (Test-Path -LiteralPath $cubePath) {
    [xml]$cubeDoc = Get-Content -LiteralPath $cubePath
    $cubeNs = New-Object System.Xml.XmlNamespaceManager($cubeDoc.NameTable)
    $cubeNs.AddNamespace('a', $engineNs)

    $cubeDim = $cubeDoc.SelectSingleNode("/a:Cube/a:Dimensions/a:Dimension[a:ID='Dim Location']", $cubeNs)
    if ($cubeDim -ne $null) {
        $attrs = $cubeDim.SelectSingleNode("a:Attributes", $cubeNs)
        while ($attrs.HasChildNodes) {
            [void]$attrs.RemoveChild($attrs.FirstChild)
        }

        foreach ($attrId in @('Location Key', 'State', 'Zip')) {
            $attrNode = New-EngineElement -Doc $cubeDoc -Name 'Attribute'
            $attrIdNode = New-EngineElement -Doc $cubeDoc -Name 'AttributeID'
            $attrIdNode.InnerText = $attrId
            [void]$attrNode.AppendChild($attrIdNode)
            [void]$attrs.AppendChild($attrNode)
        }

        Save-Xml -Doc $cubeDoc -Path $cubePath
    }
}

[pscustomobject]@{
    Dimension = 'Dim Location'
    KeyColumns = 'State, Zip'
    NameColumn = 'Zip'
    AddedAttributes = 'State, Zip'
}
