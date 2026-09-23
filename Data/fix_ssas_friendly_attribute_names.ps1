param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'

$engineNs = 'http://schemas.microsoft.com/analysisservices/2003/engine'

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

function Set-AttributeDisplayName {
    param(
        [string]$DimensionFile,
        [string]$AttributeId,
        [string]$DisplayName
    )

    $path = Join-Path $ProjectPath $DimensionFile
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Fichier introuvable : $path"
    }

    [xml]$doc = Get-Content -LiteralPath $path
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('a', $engineNs)

    $attribute = $doc.SelectSingleNode("/a:Dimension/a:Attributes/a:Attribute[a:ID='$AttributeId']", $ns)
    if ($null -eq $attribute) {
        throw "Attribut '$AttributeId' introuvable dans $DimensionFile"
    }

    $nameNode = $attribute.SelectSingleNode("a:Name", $ns)
    $nameNode.InnerText = $DisplayName

    Save-Xml -Doc $doc -Path $path
}

$changes = @(
    @{ File = 'Dim Department.dim';  AttributeId = 'Department Key';  DisplayName = 'Department' },
    @{ File = 'Dim Position.dim';    AttributeId = 'Position Key';    DisplayName = 'Position' },
    @{ File = 'Dim Manager.dim';     AttributeId = 'Manager Key';     DisplayName = 'ManagerName' },
    @{ File = 'Dim Performance.dim'; AttributeId = 'Performance Key'; DisplayName = 'PerformanceScore' },
    @{ File = 'Dim Recruitment.dim'; AttributeId = 'Recruitment Key'; DisplayName = 'RecruitmentSource' }
)

foreach ($change in $changes) {
    Set-AttributeDisplayName -DimensionFile $change.File -AttributeId $change.AttributeId -DisplayName $change.DisplayName
}

$changes | ForEach-Object {
    [pscustomobject]@{
        File        = $_.File
        AttributeId = $_.AttributeId
        DisplayName = $_.DisplayName
    }
}
