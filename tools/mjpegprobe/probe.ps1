# Runs mjpegprobe on the Windows target and uploads the results to the Pi.
#   irm http://<pi>:9998/probe.ps1 | iex
# Downloads mjpegprobe.exe and test AVIs from the Pi's port 9998, runs each
# probe, collects GPU-reset (TDR) and app-crash events, and PUTs probe.txt
# to the Pi's port 9999.
$pi = '192.168.1.8'
$dir = Join-Path $env:TEMP 'mjpegprobe'
New-Item -ItemType Directory -Force $dir | Out-Null
Set-Location $dir
foreach ($f in 'mjpegprobe.exe', 'test_420opt.avi', 'test_422def.avi') {
    Invoke-WebRequest -UseBasicParsing "http://${pi}:9998/$f" -OutFile $f
}
$log = Join-Path $dir 'probe.txt'
$start = Get-Date
function Run($title, $argv) {
    "`n===== $title  (mjpegprobe $argv)  $(Get-Date -Format HH:mm:ss.fff)" | Tee-Object -Append $log
    & .\mjpegprobe.exe @argv 2>&1 | Tee-Object -Append $log
    "exit code $LASTEXITCODE" | Tee-Object -Append $log
}
Run 'decoders and cameras' @('list')
Run 'file 4:2:0 optimal Huffman, CPU' @('file', "$dir\test_420opt.avi", '--sw')
Run 'file 4:2:0 optimal Huffman, GPU' @('file', "$dir\test_420opt.avi")
Run 'file 4:2:2 default Huffman, GPU' @('file', "$dir\test_422def.avi")
Run 'camera, CPU' @('cam', 'BRIO', '8', '--sw')
Run 'camera, GPU' @('cam', 'BRIO', '8')

"`n===== GPU resets / display driver events since $start" | Tee-Object -Append $log
Get-WinEvent -FilterHashtable @{LogName = 'System'; StartTime = $start.AddMinutes(-60) } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Display|amdkmdag|amdwddmg|dxgkrnl|LiveKernelEvent' -or $_.Id -eq 4101 } |
    Format-List TimeCreated, ProviderName, Id, Message | Out-String -Width 300 | Tee-Object -Append $log
"`n===== Application errors" | Tee-Object -Append $log
Get-WinEvent -FilterHashtable @{LogName = 'Application'; Level = 2; StartTime = $start.AddMinutes(-60) } -ErrorAction SilentlyContinue |
    Select-Object -First 20 | Format-List TimeCreated, ProviderName, Id, Message | Out-String -Width 300 | Tee-Object -Append $log

Invoke-WebRequest -UseBasicParsing "http://${pi}:9999/probe.txt" -Method Put -InFile $log | Out-Null
"uploaded $log to the Pi"
