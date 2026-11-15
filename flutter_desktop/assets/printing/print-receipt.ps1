param([Parameter(Mandatory=$true)][string]$JobPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
$doc = New-Object System.Drawing.Printing.PrintDocument
$logo = $null
$font = New-Object System.Drawing.Font('Arial', 8)
$bold = New-Object System.Drawing.Font('Arial', 8, [System.Drawing.FontStyle]::Bold)
$totalFont = New-Object System.Drawing.Font('Arial', 11, [System.Drawing.FontStyle]::Bold)
$center = New-Object System.Drawing.StringFormat
$center.Alignment = [System.Drawing.StringAlignment]::Center
$right = New-Object System.Drawing.StringFormat
$right.Alignment = [System.Drawing.StringAlignment]::Far
try {
  $installed = @([System.Drawing.Printing.PrinterSettings]::InstalledPrinters)
  $printerName = [string]$job.printer
  if ($installed -notcontains $printerName -and $printerName -eq 'XP-237B') {
    $matches = @($installed | Where-Object { $_ -match '(?i)XP[ -]?237B(?:$|[^A-Z0-9])' })
    if ($matches.Count -eq 1) { $printerName = [string]$matches[0] }
    elseif ($matches.Count -gt 1) { throw 'Multiple XP-237B printers found. Select the exact Windows name in Settings.' }
  }
  if ($installed -notcontains $printerName) { throw 'Configured printer is not installed' }
  if ($printerName -match 'Print to PDF|XPS Document') { throw 'Choose the physical receipt printer, not a file dialog printer' }
  $doc.PrinterSettings.PrinterName = $printerName
  if (-not $doc.PrinterSettings.IsValid) { throw 'Invalid printer' }
  $paper = if($job.paperWidthMm){[double]$job.paperWidthMm}else{56.0}
  $width = if($job.printableWidthMm){[double]$job.printableWidthMm}else{48.0}
  $margin = if($job.marginMm){[double]$job.marginMm}else{4.0}
  $logoSize = if($job.logoMm){[double]$job.logoMm}else{18.0}
  $offset = [double]$job.offsetMm
  if($paper -lt 40 -or $paper -gt 80 -or $width -lt 30 -or $width -gt $paper -or $margin -lt 2 -or $margin -gt 10 -or [Math]::Abs($offset) -gt 10 -or $logoSize -lt 10 -or $logoSize -gt 25){throw 'Invalid receipt dimensions'}
  $doc.DocumentName = 'Nohut Falafel - Receipt'
  $doc.PrintController = New-Object System.Drawing.Printing.StandardPrintController
  $doc.OriginAtMargins = $false
  $doc.DefaultPageSettings.Landscape = $false
  $doc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0,0,0,0)
  $logo = [System.Drawing.Image]::FromFile([string]$job.logo)
  $rows = @(([string]$job.text) -split "`n" | Where-Object { $_ -notmatch '^NOHUT FALAFEL|^MALİ FİŞ DEĞİLDİR' })
  # Conservative wrapped-row budget avoids shrinking the whole receipt by its height.
  $height = $margin*2 + $logoSize + 24
  foreach($row in $rows){ $height += 6 * [Math]::Max(1,[Math]::Ceiling($row.Length/22.0)) }
  $doc.DefaultPageSettings.PaperSize = New-Object System.Drawing.Printing.PaperSize('Nohut Receipt', [int][Math]::Round($paper/0.254), [int][Math]::Ceiling($height/0.254))
  $script:row = 0
  $script:first = $true
  $script:footer = $false
  $doc.add_PrintPage({
    param($sender,$e)
    $g=$e.Graphics
    $g.PageUnit=[System.Drawing.GraphicsUnit]::Millimeter
    # Windows graphics starts at the hard margin. Work in physical paper coordinates.
    $hardX=$e.PageSettings.HardMarginX*0.254
    $hardY=$e.PageSettings.HardMarginY*0.254
    $g.TranslateTransform([single](-$hardX),[single](-$hardY))
    $area=$e.PageSettings.PrintableArea
    $safeLeft=$area.Left*0.254+0.5
    $safeRight=($area.Left+$area.Width)*0.254-0.5
    $w=[Math]::Min($width,$safeRight-$safeLeft)
    if($w -lt 25){throw 'Receipt driver printable area is too small'}
    # Shrink oversized widths only; keep type readable and center the content block.
    $x=[Math]::Max($safeLeft,[Math]::Min(($paper-$w)/2+$offset,$safeRight-$w))
    $y=[Math]::Max($margin,$hardY+1)
    $bottom=($area.Top+$area.Height)*0.254-$margin
    if($script:first){
      $g.DrawImage($logo,[single]($x+($w-$logoSize)/2),[single]$y,[single]$logoSize,[single]$logoSize)
      $y+=$logoSize+2
      $r=New-Object System.Drawing.RectangleF([single]$x,[single]$y,[single]$w,[single]7)
      $g.DrawString('HESAP ÖZETİ',$bold,[System.Drawing.Brushes]::Black,$r,$center)
      $y+=8;$script:first=$false
    }
    while($script:row -lt $rows.Count){
      $line=[string]$rows[$script:row]
      $isTotal=$line -match '^Toplam '
      $f=if($isTotal){$totalFont}else{$font}
      $h=[Math]::Max(5,$g.MeasureString($line,$f,[single]($w-1)).Height+1.5)
      if($line -match '^(\d+) × (.*?) · ([\d.,]+ ₺)$'){
        $qty=$matches[1];$name=$matches[2];$amount=$matches[3]
        $h=[Math]::Max(6,$g.MeasureString($name,$bold,[single]($w-24)).Height+2)
      }
      if($y+$h -gt $bottom){$e.HasMorePages=$true;return}
      if($isTotal){$g.DrawLine([System.Drawing.Pens]::Black,[single]$x,[single]$y,[single]($x+$w),[single]$y);$y+=1}
      if($line -match '^(\d+) × (.*?) · ([\d.,]+ ₺)$'){
        $qty=$matches[1];$name=$matches[2];$amount=$matches[3]
        $g.DrawString($qty,$bold,[System.Drawing.Brushes]::Black,[single]$x,[single]$y)
        $r=New-Object System.Drawing.RectangleF([single]($x+5),[single]$y,[single]($w-24),[single]$h)
        $g.DrawString($name,$bold,[System.Drawing.Brushes]::Black,$r)
        $r=New-Object System.Drawing.RectangleF([single]($x+$w-19),[single]$y,[single]19,[single]$h)
        $g.DrawString($amount,$font,[System.Drawing.Brushes]::Black,$r,$right)
      }elseif($line -match '^(Toplam|Net tahsilat|Kalan) ([\d.,]+ ₺)$'){
        $label=if($matches[1] -eq 'Toplam'){'TOPLAM'}elseif($matches[1] -eq 'Net tahsilat'){'Ödenen'}else{'Kalan'}
        $g.DrawString($label,$f,[System.Drawing.Brushes]::Black,[single]$x,[single]$y)
        $r=New-Object System.Drawing.RectangleF([single]($x+$w/2),[single]$y,[single]($w/2),[single]$h)
        $g.DrawString($matches[2],$f,[System.Drawing.Brushes]::Black,$r,$right)
      }else{
        $r=New-Object System.Drawing.RectangleF([single]$x,[single]$y,[single]$w,[single]$h)
        $g.DrawString($line,$font,[System.Drawing.Brushes]::Black,$r)
      }
      $y+=$h;$script:row++
    }
    if(-not $script:footer){
      if($y+15 -gt $bottom){$e.HasMorePages=$true;return}
      foreach($line in @('Afiyet olsun!','MALİ FİŞ DEĞİLDİR')){
        $y+=2;$r=New-Object System.Drawing.RectangleF([single]$x,[single]$y,[single]$w,[single]5)
        $g.DrawString($line,$bold,[System.Drawing.Brushes]::Black,$r,$center);$y+=5
      }
      $script:footer=$true
    }
    $e.HasMorePages=$false
  })
  $doc.Print()
} finally {
  if($logo){$logo.Dispose()}
  $font.Dispose();$bold.Dispose();$totalFont.Dispose();$center.Dispose();$right.Dispose();$doc.Dispose()
}
