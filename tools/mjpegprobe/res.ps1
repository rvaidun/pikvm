# GPU-decodes MJPEG test files of several sizes with mjpegprobe, 20 s apart
# (each decoder hang is a GPU reset; Windows disables the display driver
# after too many in a minute), and uploads the results to the Pi.
param([string[]]$Sizes = @('640x480', '1280x768'))
$pi = '192.168.1.8'
Set-Location (Join-Path $env:TEMP 'mjpegprobe')
$out = 'res.txt'
Remove-Item $out -ErrorAction SilentlyContinue
foreach ($r in $Sizes) {
    Invoke-WebRequest -UseBasicParsing "http://${pi}:9998/t_$r.avi" -OutFile "t_$r.avi"
    "=== $r" | Tee-Object -Append $out
    & .\mjpegprobe.exe file "$PWD\t_$r.avi" --dbwin 2>&1 |
        Where-Object { $_ -notmatch 'frame \d+ ts' -or $_ -match 'frame [1-5] ts' } |
        Tee-Object -Append $out
    Start-Sleep 20
}
Invoke-WebRequest -UseBasicParsing -Method Put -InFile $out "http://${pi}:9999/res.txt" | Out-Null
'uploaded res.txt'
