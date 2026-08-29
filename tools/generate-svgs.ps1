#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$ImagePath,

  [string]$OutName,

  [string]$OutputDir,

  [ValidateSet("png", "webp", "jpg", "jpeg", "gif")]
  [string]$ImageType,

  [double]$CornerSize = 0.06,

  [double]$BevelSize = 0.01
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ImagePath)) {
  throw "Image not found: $ImagePath"
}

if (-not $ImageType) {
  $ext = [System.IO.Path]::GetExtension($ImagePath).TrimStart('.').ToLowerInvariant()
  $ImageType = if ($ext -eq 'jpeg') { 'jpeg' } elseif ($ext -in @('png', 'webp', 'jpg', 'gif')) { $ext } else { $ext }
}

if (-not $OutputDir) {
  $OutputDir = Split-Path -Parent $PSScriptRoot
}

$mime = switch ($ImageType) {
  'png' { 'image/png' }
  'webp' { 'image/webp' }
  'jpg' { 'image/jpeg' }
  'jpeg' { 'image/jpeg' }
  'gif' { 'image/gif' }
  default { throw "Unsupported image type: $ImageType" }
}

function Read-Be16 {
  param([byte[]]$Data, [int]$Offset)
  return ([int]$Data[$Offset] -shl 8) -bor [int]$Data[$Offset + 1]
}

function Read-Be32 {
  param([byte[]]$Data, [int]$Offset)
  return ([int]$Data[$Offset] -shl 24) -bor ([int]$Data[$Offset + 1] -shl 16) -bor ([int]$Data[$Offset + 2] -shl 8) -bor [int]$Data[$Offset + 3]
}

function Get-ImageDimensions {
  param([string]$Path, [string]$Type)
  $d = [System.IO.File]::ReadAllBytes($Path)
  switch ($Type) {
    'png' {
      if ((Read-Be32 $d 0) -ne 0x89504E47) { throw 'Invalid PNG signature' }
      return @{ Width = Read-Be32 $d 16; Height = Read-Be32 $d 20 }
    }
    'gif' {
      if (-not ([System.Text.Encoding]::ASCII.GetString($d, 0, 6) -eq 'GIF89a' -or [System.Text.Encoding]::ASCII.GetString($d, 0, 6) -eq 'GIF87a')) { throw 'Invalid GIF signature' }
      return @{ Width = [int]$d[6] -bor ([int]$d[7] -shl 8); Height = [int]$d[8] -bor ([int]$d[9] -shl 8) }
    }
    'webp' {
      $id = [System.Text.Encoding]::ASCII.GetString([byte[]]$d[12..15])
      switch ($id) {
        'VP8X' {
          $w = ([int]$d[24] -bor ([int]$d[25] -shl 8) -bor ([int]$d[26] -shl 16)) + 1
          $h = ([int]$d[27] -bor ([int]$d[28] -shl 8) -bor ([int]$d[29] -shl 16)) + 1
          return @{ Width = $w; Height = $h }
        }
        'VP8 ' {
          if (-not ($d[23] -eq 0x9D -and $d[24] -eq 0x01 -and $d[25] -eq 0x2A)) { throw 'Unsupported VP8 frame header' }
          $w = ([int]$d[26] -bor ([int]$d[27] -shl 8)) -band 0x3FFF
          $h = ([int]$d[28] -bor ([int]$d[29] -shl 8)) -band 0x3FFF
          return @{ Width = $w; Height = $h }
        }
        'VP8L' {
          if (-not ($d[20] -eq 0x2F)) { throw 'Invalid VP8L signature' }
          $bits = [uint32]$d[21] -bor ([uint32]$d[22] -shl 8) -bor ([uint32]$d[23] -shl 16) -bor ([uint32]$d[24] -shl 24)
          $w = ([int]($bits -band 0x3FFF)) + 1
          $h = ([int](($bits -shr 14) -band 0x3FFF)) + 1
          return @{ Width = $w; Height = $h }
        }
        default { throw "Unsupported WebP chunk: $id" }
      }
    }
    'jpg' {
      $i = 2
      while ($i -lt ($d.Length - 9)) {
        while ($d[$i] -eq 0xFF -and $d[$i + 1] -eq 0xFF) { $i++ }
        if ($d[$i] -ne 0xFF) { $i++; continue }
        $marker = $d[$i + 1]
        if (($marker -ge 0xC0 -and $marker -le 0xCF) -and $marker -ne 0xC4 -and $marker -ne 0xC8 -and $marker -ne 0xCC) {
          return @{ Width = Read-Be16 $d ($i + 7); Height = Read-Be16 $d ($i + 5) }
        }
        if ($marker -eq 0xDA -or $marker -eq 0xD9) { break }
        if (($marker -ge 0xD0 -and $marker -le 0xD7)) { $i += 2; continue }
        $len = Read-Be16 $d ($i + 2)
        if ($len -lt 2) { break }
        $i += 2 + $len
      }
      throw 'JPEG dimensions not found (no SOF marker)'
    }
    default { throw "Unsupported image type: $Type" }
  }
}

function Format-ClipNum {
  param([double]$Value)
  if ([math]::Abs($Value - [math]::Round($Value)) -lt 0.004) { return $Value.ToString('0') }
  return $Value.ToString('0.00')
}

$dim = Get-ImageDimensions -Path $ImagePath -Type $ImageType
$W = [double]$dim.Width
$H = [double]$dim.Height

$topInnerX = $W * (1 - $BevelSize)
$topInnerY = $H * $CornerSize
$rightY = $H * ($CornerSize + $BevelSize)
$leftX = $W * $CornerSize
$leftY = $H * (1 - $CornerSize)

$points = @(
  (Format-ClipNum $topInnerX) + ',0'
  (Format-ClipNum $topInnerX) + ',' + (Format-ClipNum $topInnerY)
  (Format-ClipNum $W) + ',' + (Format-ClipNum $rightY)
  (Format-ClipNum $W) + ',' + (Format-ClipNum $H)
  (Format-ClipNum $leftX) + ',' + (Format-ClipNum $H)
  '0,' + (Format-ClipNum $leftY)
  '0,0'
) -join ' '

$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImagePath))
$svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + $W + ' ' + $H + '" width="' + $W + '" height="' + $H + '"><defs><clipPath id="cut"><polygon points="' + $points + '"/></clipPath></defs><g clip-path="url(#cut)"><image href="data:' + $mime + ';base64,' + $b64 + '" width="' + $W + '" height="' + $H + '"/></g></svg>'

if (-not $OutName) {
  $OutName = [System.IO.Path]::GetFileNameWithoutExtension($ImagePath) + '.svg'
}
$outputPath = Join-Path $OutputDir $OutName
[System.IO.File]::WriteAllText($outputPath, $svg)

Write-Output "Generated $outputPath ($([math]::Round($W))x$([math]::Round($H)) b64, clip corner $([math]::Round($CornerSize * 100))% bevel $([math]::Round($BevelSize * 100))%)"