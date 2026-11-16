# Frabs Benchmark for Windows: https://benchmark.frabs.net
#
# Measures this server's CPU, memory, disk and network and shows the results on
# benchmark.frabs.net. It installs nothing and changes nothing: every file it makes
# goes in one temporary folder that is deleted when it finishes, even if it fails.
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/frabsnet/benchmark/main/run.ps1))) YOURCODE
#
# What it sends: the step it is on, the measurements below, and basic facts about the
# machine (Windows version, CPU model, core count, RAM, disk size, virtualisation).
# Never hostnames, IP addresses, users, files or processes.
param([string]$Code)
$ErrorActionPreference = 'Stop'
if ($Code -notmatch '^[A-Z2-9]{9}$') {
  Write-Host 'Usage: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/frabsnet/benchmark/main/run.ps1))) YOURCODE'
  Write-Host 'Get your code at https://benchmark.frabs.net'
  return
}
# TLS 1.2 by number, so older .NET versions without the name still get it.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
$Api = "https://api.frabs.net/v1/tools/bench/$Code/event"
$Work = Join-Path ([IO.Path]::GetTempPath()) ("frabs-benchmark-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work | Out-Null

function Send($body) {
  $json = $body | ConvertTo-Json -Depth 5 -Compress
  try { Invoke-RestMethod -Uri $Api -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 10 | Out-Null }
  catch { try { $w = New-Object Net.WebClient; $w.Headers['Content-Type'] = 'application/json'; $w.UploadString($Api, $json) | Out-Null } catch { } }
}
# System facts: CIM where it exists, WMI on older Windows.
function Info($class, $filter) {
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { if ($filter) { Get-CimInstance $class -Filter $filter } else { Get-CimInstance $class } }
  else { if ($filter) { Get-WmiObject $class -Filter $filter } else { Get-WmiObject $class } }
}
function Step($key, $state, $detail, $shown) {
  Send @{ step = $key; state = $state; detail = [string]$detail }
  switch ($state) {
    'running' { Write-Host ('  {0,-34} ' -f $detail) -NoNewline }
    'done' { Write-Host "done  $shown" }
    'skipped' { Write-Host "skipped ($detail)" }
  }
}

# The measuring code, compiled in memory for this run only.
Add-Type -TypeDefinition @'
using System; using System.Diagnostics; using System.IO; using System.Net.Http; using System.Net.Sockets;
using System.Security.Cryptography; using System.Threading; using System.Threading.Tasks;
public static class FrabsBench {
  static long Hash(int seconds) {
    var data = new byte[1 << 20]; long done = 0; var sw = Stopwatch.StartNew();
    using (var sha = SHA256.Create()) { while (sw.Elapsed.TotalSeconds < seconds) { sha.ComputeHash(data); done += data.Length; } }
    return done;
  }
  public static double CpuSingle() { var sw = Stopwatch.StartNew(); long b = Hash(5); return b / sw.Elapsed.TotalSeconds / 1e6; }
  public static double CpuMulti(int threads) {
    long total = 0; var sw = Stopwatch.StartNew();
    Parallel.For(0, threads, new ParallelOptions { MaxDegreeOfParallelism = threads }, i => { Interlocked.Add(ref total, Hash(5)); });
    return total / sw.Elapsed.TotalSeconds / 1e6;
  }
  public static double Memory() {
    var a = new byte[256 << 20]; var b = new byte[256 << 20]; long done = 0; var sw = Stopwatch.StartNew();
    while (sw.Elapsed.TotalSeconds < 3) { Buffer.BlockCopy(a, 0, b, 0, a.Length); done += a.Length; }
    return done / sw.Elapsed.TotalSeconds / 1e6;
  }
  public static double DiskWrite(string path, int mb) {
    var buf = new byte[1 << 20]; new Random(1).NextBytes(buf); var sw = Stopwatch.StartNew();
    using (var f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, FileOptions.WriteThrough)) { for (int i = 0; i < mb; i++) f.Write(buf, 0, buf.Length); f.Flush(true); }
    return mb * 1048576.0 / sw.Elapsed.TotalSeconds / 1e6;
  }
  public static double DiskRead(string path) {
    var buf = new byte[1 << 20]; long done = 0; var sw = Stopwatch.StartNew();
    using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None, 1 << 20, (FileOptions)0x20000000)) { int n; while ((n = f.Read(buf, 0, buf.Length)) > 0) done += n; }
    return done / sw.Elapsed.TotalSeconds / 1e6;
  }
  public static double Disk4k(string path) {
    var buf = new byte[4096]; int count = 0; var sw = Stopwatch.StartNew();
    using (var f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { while (sw.Elapsed.TotalSeconds < 3) { f.Write(buf, 0, 4096); f.Flush(true); count++; } }
    return count / sw.Elapsed.TotalSeconds;
  }
  public static double Download(string url, int seconds) {
    using (var c = new HttpClient()) {
      c.Timeout = TimeSpan.FromSeconds(seconds + 5); long done = 0; var sw = Stopwatch.StartNew();
      try {
        using (var s = c.GetStreamAsync(url).Result) { var buf = new byte[1 << 16]; int n; while (sw.Elapsed.TotalSeconds < seconds && (n = s.Read(buf, 0, buf.Length)) > 0) done += n; }
      } catch { }
      return sw.Elapsed.TotalSeconds > 0 ? done * 8 / sw.Elapsed.TotalSeconds / 1e6 : 0;
    }
  }
  public static double Upload(int mb, int seconds) {
    using (var c = new HttpClient()) {
      c.Timeout = TimeSpan.FromSeconds(seconds + 5); var body = new ByteArrayContent(new byte[mb << 20]); var sw = Stopwatch.StartNew();
      try { c.PostAsync("https://speed.cloudflare.com/__up", body).Wait(); } catch { return 0; }
      return mb * 8 * 1048576.0 / sw.Elapsed.TotalSeconds / 1e6;
    }
  }
  public static double Connect(string host) {
    try { using (var t = new TcpClient()) { var sw = Stopwatch.StartNew(); if (t.ConnectAsync(host, 443).Wait(5000)) return sw.Elapsed.TotalMilliseconds; } } catch { }
    return 0;
  }
}
'@ -ReferencedAssemblies System.Net.Http

try {
  Write-Host ''
  Write-Host "  Frabs Benchmark · https://benchmark.frabs.net/$Code"
  Write-Host '  Nothing is installed. Everything it makes is removed at the end.'
  Write-Host ''
  Send @{ state = 'start'; platform = 'windows' }

  Step 'system' 'running' 'Reading the system'
  $os = Info Win32_OperatingSystem; $cpu = Info Win32_Processor | Select-Object -First 1; $cs = Info Win32_ComputerSystem
  $drive = Info Win32_LogicalDisk ("DeviceID='{0}'" -f ([IO.Path]::GetPathRoot($Work).TrimEnd('\')))
  $cores = [Environment]::ProcessorCount
  $free = [math]::Floor($drive.FreeSpace / 1MB)
  $virt = if ($cs.Model -match 'Virtual|VMware|KVM|HVM|Xen|QEMU') { $cs.Model } else { 'none' }
  Send @{ system = @{ os = "$($os.Caption) $($os.Version)"; kernel = $os.Version; arch = $env:PROCESSOR_ARCHITECTURE; cpu = $cpu.Name.Trim(); cores = $cores; ram_mb = [math]::Floor($cs.TotalPhysicalMemory / 1MB); disk_mb = [math]::Floor($drive.Size / 1MB); disk_free_mb = $free; virtualisation = $virt } }
  Step 'system' 'done' 'Reading the system' "$($cpu.Name.Trim()), $cores cores"

  Step 'cpu_single' 'running' 'CPU, single core'
  $s = [math]::Round([FrabsBench]::CpuSingle(), 1); Send @{ results = @{ cpu_single_mbs = $s } }; Step 'cpu_single' 'done' 'CPU, single core' "$s MB/s"
  Step 'cpu_multi' 'running' "CPU, all $cores cores"
  $m = [math]::Round([FrabsBench]::CpuMulti($cores), 1); Send @{ results = @{ cpu_multi_mbs = $m } }; Step 'cpu_multi' 'done' "CPU, all $cores cores" "$m MB/s"
  Step 'memory' 'running' 'Memory speed'
  $mem = [math]::Round([FrabsBench]::Memory(), 1); Send @{ results = @{ memory_mbs = $mem } }; Step 'memory' 'done' 'Memory speed' "$mem MB/s"

  $size = [math]::Min(1024, [math]::Floor($free / 10)); $file = Join-Path $Work 'test.bin'
  if ($size -lt 64) {
    foreach ($k in 'disk_write', 'disk_read', 'disk_iops') { Step $k 'skipped' 'not enough free disk space' }
  } else {
    Step 'disk_write' 'running' "Disk write, $size MB"
    $w = [math]::Round([FrabsBench]::DiskWrite($file, $size), 1); Send @{ results = @{ disk_write_mbs = $w } }; Step 'disk_write' 'done' 'Disk write' "$w MB/s"
    Step 'disk_read' 'running' "Disk read, $size MB"
    $r = [math]::Round([FrabsBench]::DiskRead($file), 1); Send @{ results = @{ disk_read_mbs = $r } }; Step 'disk_read' 'done' 'Disk read' "$r MB/s"
    Remove-Item -LiteralPath $file -Force
    Step 'disk_iops' 'running' 'Disk 4K writes'
    $i = [math]::Floor([FrabsBench]::Disk4k((Join-Path $Work '4k.bin'))); Send @{ results = @{ disk_iops = $i } }; Step 'disk_iops' 'done' 'Disk 4K writes' "$i IOPS"
  }

  $sites = @(
    @('Cloudflare (nearest)', 'https://speed.cloudflare.com/__down?bytes=50000000', 'speed.cloudflare.com'),
    @('Hetzner, Germany', 'https://fsn1-speed.hetzner.com/1GB.bin', 'fsn1-speed.hetzner.com'),
    @('OVH, France', 'https://proof.ovh.net/files/1Gb.dat', 'proof.ovh.net'),
    @('Clouvider, London', 'https://lon.speedtest.clouvider.net/1g.bin', 'lon.speedtest.clouvider.net'),
    @('Hetzner, US East', 'https://ash-speed.hetzner.com/1GB.bin', 'ash-speed.hetzner.com')
  )
  Step 'network' 'running' 'Network download'
  $dl = @(); $lat = @(); $best = 0
  foreach ($site in $sites) {
    Send @{ step = 'network'; state = 'running'; detail = "Downloading from $($site[0])" }
    $mbit = [math]::Round([FrabsBench]::Download($site[1], 8), 1); $ms = [math]::Round([FrabsBench]::Connect($site[2]), 1)
    Write-Host ''; Write-Host ('    {0,-30} {1} Mbit/s, {2} ms' -f $site[0], $mbit, $ms) -NoNewline
    $dl += @{ name = $site[0]; value = $mbit; unit = 'Mbit/s' }; $lat += @{ name = $site[0]; value = $ms; unit = 'ms' }
    if ($mbit -gt $best) { $best = $mbit }
  }
  Write-Host ''
  Send @{ results = @{ net_download = $dl; net_best_mbit = $best } }; Step 'network' 'done' 'Network download' "best $best Mbit/s"
  Step 'upload' 'running' 'Network upload'
  $u = [math]::Round([FrabsBench]::Upload(100, 8), 1); Send @{ results = @{ net_upload_mbit = $u } }; Step 'upload' 'done' 'Network upload' "$u Mbit/s"
  Step 'latency' 'running' 'Network latency'
  Send @{ results = @{ latency = $lat } }; Step 'latency' 'done' 'Network latency' ''
} finally {
  # Leave nothing behind, whatever happened above.
  Step 'cleanup' 'running' 'Removing everything it made'
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
  Step 'cleanup' 'done' 'Removing everything it made' ''
  Send @{ state = 'finished' }
  Write-Host ''
  Write-Host "  Done. Your results: https://benchmark.frabs.net/$Code"
  Write-Host ''
}
