# Frabs Benchmark

Benchmark any Linux or Windows server with one command and see the results at
[benchmark.frabs.net](https://benchmark.frabs.net).

Open [benchmark.frabs.net](https://benchmark.frabs.net) to get your own code, then run the
command it shows you on the server.

**Linux**

```sh
curl -sL https://raw.githubusercontent.com/frabsnet/benchmark/main/run.sh | bash -s YOURCODE
```

**Windows** (PowerShell)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/frabsnet/benchmark/main/run.ps1))) YOURCODE
```

## What it measures

| Test | How |
| --- | --- |
| CPU, single core | SHA-256 hashing on one core, in MB/s |
| CPU, all cores | The same on every core at once |
| Memory | Copying through RAM, in MB/s |
| Disk write and read | A test file up to 1 GB (never more than a tenth of the free space), direct I/O where the filesystem allows it |
| Disk 4K writes | Small direct writes, in IOPS |
| Network download | Up to 8 seconds from each of Cloudflare (nearest), Clouvider (UK), Hetzner (DE), OVH (FR) and Hetzner (US) public test files |
| Network upload | 8 seconds to Cloudflare's speed test |
| Latency | TCP connection time to each of the above |

A run takes about two to three minutes.

## Your server, untouched

- Nothing is installed. Linux needs only `bash`, `curl`, `dd`, `sha256sum` and `awk`; Windows
  needs only PowerShell.
- Everything it writes goes in one temporary folder (`/var/tmp/frabs-benchmark.*` or your
  Windows temp folder), which is deleted when it finishes, fails or is stopped.
- No root or Administrator rights are needed.

## What is sent

Only to `api.frabs.net`, for your results page: the step it is on, the measurements above, and
the OS, kernel, architecture, CPU model, core count, RAM, disk size and free space, and
virtualisation type. Never hostnames, IP addresses, user names, files or processes. Results are
kept for 7 days.

## License

Apache-2.0. Made by [Frabs](https://frabs.net).
