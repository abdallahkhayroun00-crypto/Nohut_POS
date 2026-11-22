param([Parameter(Mandatory=$true)][string]$JobPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName System.Drawing
$job=Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
$name=[string]$job.printer
$dialogMode=($job.showWindowsPrintDialog -eq $true)
if($dialogMode -and $job.transport -ne 'windows'){throw 'Windows yazdırma penceresi için Yazdırma yöntemi: Windows seçin. ESC/POS doğrudan fiş yazdırma ayrı bir yöntemdir.'}
$installed=@([System.Drawing.Printing.PrinterSettings]::InstalledPrinters)
if($installed -notcontains $name -and $name -eq 'XP-237B'){
  $found=@($installed|Where-Object {$_ -match '(?i)XP[ -]?237B(?:$|[^A-Z0-9])'})
  if($found.Count -eq 1){$name=[string]$found[0]}else{throw 'Select the exact installed XP-237B printer name.'}
}
if(-not $dialogMode -and $installed -notcontains $name){throw 'Yazıcı yüklü değil (not installed). Windows yazıcı adını kontrol edin.'}
if(-not $dialogMode -and $name -match 'Print to PDF|XPS Document'){throw 'Fiziksel fiş yazıcısını seçin.'}
if($job.transport -eq 'escpos'){
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class NohutRawSpool {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 public class Doc { public string Name; public string Output; public string Type; }
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool OpenPrinter(string name,out IntPtr handle,IntPtr defaults);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool ClosePrinter(IntPtr h);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern int StartDocPrinter(IntPtr h,int level,[In] Doc doc);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool StartPagePrinter(IntPtr h);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool WritePrinter(IntPtr h,byte[] bytes,int count,out int written);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool EndPagePrinter(IntPtr h);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool EndDocPrinter(IntPtr h);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool AbortPrinter(IntPtr h);
 static void Check(bool ok){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
 public static void Send(string name,byte[] bytes){
  IntPtr h;Check(OpenPrinter(name,out h,IntPtr.Zero));bool done=false,started=false;
  try{
   Check(StartDocPrinter(h,1,new Doc{Name="Nohut Falafel - Receipt",Type="RAW"})!=0);started=true;
   Check(StartPagePrinter(h));
   for(int at=0;at<bytes.Length;){int count=Math.Min(65536,bytes.Length-at),written;byte[] chunk=new byte[count];Buffer.BlockCopy(bytes,at,chunk,0,count);Check(WritePrinter(h,chunk,count,out written));if(written<=0||written>count)throw new InvalidOperationException("Incomplete printer write");at+=written;}
   Check(EndPagePrinter(h));Check(EndDocPrinter(h));done=true;
  }finally{if(started&&!done)AbortPrinter(h);ClosePrinter(h);}
 }
}
'@
  [NohutRawSpool]::Send($name,[System.IO.File]::ReadAllBytes([string]$job.rawPath))
  exit 0
}
$doc=New-Object System.Drawing.Printing.PrintDocument
if($dialogMode){
  # The standard Windows Print dialog first selects the installed driver.
  # The following WinForms Print Preview uses the very same raster/PrintPage
  # handler as silent printing; it does not submit anything until Print.
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.Application]::EnableVisualStyles()
  if($installed -contains $name){$doc.PrinterSettings.PrinterName=$name}
  $choice=New-Object System.Windows.Forms.PrintDialog
  try{
    $choice.UseEXDialog=$true
    $choice.AllowSomePages=$false
    $choice.AllowPrintToFile=$false
    $choice.Document=$doc
    if($choice.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){
      [Console]::Out.WriteLine('NOHUT_DIALOG_CANCELLED')
      exit 0
    }
    $name=[string]$doc.PrinterSettings.PrinterName
    if($installed -notcontains $name){throw 'Seçilen Windows yazıcısı yüklü değil.'}
  }finally{$choice.Dispose()}
}
$image=$null
try{
 $doc.PrinterSettings.PrinterName=$name
 if(-not $doc.PrinterSettings.IsValid){throw 'Invalid receipt printer.'}
 $image=[System.Drawing.Image]::FromFile([string]$job.imagePath)
 $paper=[double]$job.paperWidthMm;$width=[double]$job.printableWidthMm
 $margin=[double]$job.marginMm;$offset=[double]$job.offsetMm
 $height=$image.Height/8.0
 if($paper -lt 40 -or $paper -gt 80 -or $width -lt 30 -or $width -gt 48 -or $image.Width -ne [int][Math]::Round($width*8) -or $height -le 0 -or $margin -lt 2 -or $margin -gt 10 -or [Math]::Abs($offset) -gt 10){throw 'Invalid receipt dimensions.'}
 $doc.DocumentName='Nohut Falafel - Receipt'
 $doc.PrintController=New-Object System.Drawing.Printing.StandardPrintController
 $doc.OriginAtMargins=$false
 $doc.DefaultPageSettings.Landscape=$false
 $doc.DefaultPageSettings.Margins=New-Object System.Drawing.Printing.Margins(0,0,0,0)
 $doc.DefaultPageSettings.PaperSize=New-Object System.Drawing.Printing.PaperSize('Nohut Receipt',[int][Math]::Round($paper/0.254),[int][Math]::Ceiling($height/0.254))
 $doc.add_PrintPage({
  param($sender,$e)
  $actualW=$e.PageBounds.Width*0.254;$actualH=$e.PageBounds.Height*0.254
  if([Math]::Abs($actualW-$paper) -gt 1 -or $actualH -lt $height-0.5){throw 'Driver changed the receipt page size. Select Receipt mode and continuous variable-length paper, or use ESC/POS in Receipt mode.'}
  $area=$e.PageSettings.PrintableArea
  $left=($paper-$width)/2+$offset
  $safeLeft=$area.Left*0.254;$safeRight=($area.Left+$area.Width)*0.254
  $safeTop=$area.Top*0.254;$safeBottom=($area.Top+$area.Height)*0.254
  if($left -lt $safeLeft-0.2 -or $left+$width -gt $safeRight+0.2 -or $margin -lt $safeTop-0.2 -or $height-$margin -gt $safeBottom+0.2){throw 'Receipt exceeds driver printable area. Run the alignment test and correct width/offset or use ESC/POS in Receipt mode. Nothing was scaled to fit.'}
  $g=$e.Graphics;$g.PageUnit=[System.Drawing.GraphicsUnit]::Millimeter
  $g.TranslateTransform([single](-$e.PageSettings.HardMarginX*0.254),[single](-$e.PageSettings.HardMarginY*0.254))
  $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.PixelOffsetMode=[System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g.DrawImage($image,[System.Drawing.RectangleF]::new([single]$left,[single]0,[single]$width,[single]$height))
  $e.HasMorePages=$false
 })
 if($dialogMode){
  $script:userActuallyPrinted=$false
  # Preview's graphics are generated by PreviewPrintController.
  # Mark as printed only after the real StandardPrintController finishes.
  $doc.add_EndPrint({
    param($sender,$e)
    if(-not $e.Cancel -and $sender.PrintController -is [System.Drawing.Printing.StandardPrintController]){
      $script:userActuallyPrinted=$true
    }
  })
  $preview=New-Object System.Windows.Forms.PrintPreviewDialog
  try{
    $preview.Document=$doc
    $preview.Text='Nohut Falafel - Windows Fiş Önizleme ve Yazdır'
    $preview.Width=890
    $preview.Height=950
    $preview.StartPosition=[System.Windows.Forms.FormStartPosition]::CenterScreen
    $null=$preview.ShowDialog()
  }finally{$preview.Dispose()}
  if($script:userActuallyPrinted){[Console]::Out.WriteLine('NOHUT_DIALOG_PRINTED')}
  else{[Console]::Out.WriteLine('NOHUT_DIALOG_CANCELLED')}
 }else{
  $doc.Print()
 }
}finally{if($image){$image.Dispose()};$doc.Dispose()}
