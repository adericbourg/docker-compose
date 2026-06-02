# Monitoring — Internet connection quality

Stack: **Grafana + VictoriaMetrics + Blackbox Exporter + Speedtest Exporter**  
Compatible **arm64** (Freebox Ultra)

---

## Overview

This stack continuously monitors the quality of an internet connection and stores results for up to 120 days. It measures latency and packet loss via ICMP pings, HTTP availability and response times, and periodically runs full bandwidth tests via the Ookla Speedtest CLI. All metrics are stored in VictoriaMetrics and visualised in a pre-provisioned Grafana dashboard.

---

## Architecture

```
Internet targets                     Exporters                              Storage          Visualisation
─────────────────────────────────────────────────────────────────────────────────────────────────────────
  8.8.8.8  ──┐
  1.1.1.1  ──┤── ICMP ping ──► Blackbox Exporter :9115 ───────────────────────┐
  9.9.9.9  ──┘                                                                 │
                                                                               ├─► VictoriaMetrics ──► Grafana
  google.com  ──┐                                                              │       :8428             :3000
  cloudflare ──┘── HTTP GET ──► Blackbox Exporter :9115 ──────────────────────┤
                                                                               │
  Ookla servers ──► Speedtest Exporter :9798 ──► Scheduler (crond) ──(push)───┘
```

For ICMP and HTTP, VictoriaMetrics drives the collection cycle: it scrapes the exporters on schedule, and they run the probes on demand. For bandwidth, the Speedtest Scheduler fetches from the exporter and **pushes** the results to VictoriaMetrics — allowing it to apply peak-hours logic before deciding whether to run a test. Grafana only reads — it never touches the exporters directly.

---

## Components

### Blackbox Exporter

**Config:** `blackbox/config.yml`

The Blackbox Exporter performs *synthetic network probes* on demand. VictoriaMetrics tells it which target to probe and which module to use via HTTP query parameters; the exporter runs the probe and returns the result as Prometheus metrics.

Three probe modules are defined:

| Module | Prober | Timeout | Notes |
|---|---|---|---|
| `icmp` | ICMP (ping) | 5 s | IPv4 only; measures round-trip time and packet loss |
| `http_2xx` | HTTP GET | 10 s | Accepts any 2xx status, follows redirects, supports HTTP/2 |
| `tcp_connect` | TCP | 5 s | Not currently used; available for port-level checks |

The container requires the `NET_RAW` Linux capability to send raw ICMP packets. Without it, ping probes would fail silently.

---

### Speedtest Exporter

**Image:** `miguelndecarvalho/speedtest-exporter` (arm64-compatible)

Runs the Ookla Speedtest CLI on every scrape and exposes the results as Prometheus metrics:

- `speedtest_download_bits_per_second`
- `speedtest_upload_bits_per_second`
- `speedtest_ping_latency_milliseconds`
- `speedtest_jitter_latency_milliseconds`

Each test consumes real bandwidth and takes ~30–90 seconds. The exporter is not scraped directly by VictoriaMetrics — the Speedtest Scheduler controls when tests run (see below).

---

### Speedtest Scheduler

**Script:** `speedtest-scheduler/schedule.sh`

A lightweight Alpine container running `crond`. Every hour it decides whether to run a bandwidth test based on time-of-day rules:

| Time window | Behaviour |
|---|---|
| Off-peak / weekends | Run every hour |
| Peak hours (Mon–Fri, 09h–18h, excl. lunch) | Run every 4 hours |
| Lunch break (12h–13h) | Skip |

When a test is due, the script fetches metrics from the Speedtest Exporter and **pushes** them into VictoriaMetrics via `/api/v1/import/prometheus`. This is a push model — VictoriaMetrics does not scrape the exporter directly.

The schedule is configurable via environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|---|---|---|
| `PEAK_HOURS_START` | `9` | Start of peak window (24 h) |
| `PEAK_HOURS_END` | `18` | End of peak window (24 h) |
| `LUNCH_BREAK_START` | `12` | Start of lunch exclusion |
| `LUNCH_BREAK_END` | `13` | End of lunch exclusion |

To run a test immediately without waiting for the next scheduled window:

```bash
./trigger-speedtest.sh
```

---

### VictoriaMetrics

**Config:** `victoriametrics/scrape_config.yml`

VictoriaMetrics is a Prometheus-compatible time-series database that also acts as the scrape orchestrator. It pulls metrics from the exporters on a schedule and stores them for 120 days (configurable via `--retentionPeriod` in `docker-compose.yml`).

Three scrape jobs are configured:

| Job | Target | Interval | Module |
|---|---|---|---|
| `blackbox_icmp` | 8.8.8.8, 1.1.1.1, 9.9.9.9 | 30 s | `icmp` |
| `blackbox_http` | google.com, cloudflare.com | 30 s | `http_2xx` |

Speedtest metrics are not scraped by VictoriaMetrics — they are pushed by the Speedtest Scheduler (see above).

**How the blackbox relabelling works:**  
For `blackbox_icmp` and `blackbox_http`, the targets listed in `static_configs` are the *probe destinations* (e.g. `8.8.8.8`), not the exporter address. The `relabel_configs` block rewrites the scrape address to `blackbox-exporter:9115` and passes the original target as the `?target=` query parameter. This way a single Blackbox Exporter instance handles all targets without needing separate scrape jobs per IP.

---

### Grafana

**Config:** `grafana/provisioning/`

Grafana is auto-provisioned at startup — no manual setup required:

- **Datasource** (`provisioning/datasources/victoriametrics.yml`): a single Prometheus-compatible source pointing to `http://victoriametrics:8428`, set as the default.
- **Dashboard** (`provisioning/dashboards/internet-quality.yml`): the *Internet connection quality* dashboard loads automatically into the **Network** folder.

The bundled dashboard includes:

| Panel | Type | Query |
|---|---|---|
| ICMP Latency (stat) | Gauge | Average probe duration across 3 targets, ms |
| Packet Loss (stat) | Gauge | 5-min rolling failure rate, % |
| Download (stat) | Gauge | Latest Speedtest download, bps |
| Upload (stat) | Gauge | Latest Speedtest upload, bps |
| ICMP Latency per target | Time series | Per-IP probe duration over time |
| Packet Loss per target | Time series | Per-IP rolling failure rate |
| HTTP Availability | Time series | UP/DOWN status per URL |
| HTTP Response Time | Time series | Per-URL probe duration, ms |
| Download/Upload throughput | Time series | Speedtest bandwidth over time |
| Ping & Jitter (Speedtest) | Time series | Speedtest latency and jitter |

The dashboard refreshes every **30 seconds** and defaults to a **24-hour** time window.

---

## Data flow — lifecycle of a single ICMP probe

1. Every 30 seconds VictoriaMetrics triggers a scrape of the `blackbox_icmp` job.
2. For each target (e.g. `8.8.8.8`), it sends an HTTP request to `blackbox-exporter:9115/probe?module=icmp&target=8.8.8.8`.
3. Blackbox Exporter sends an ICMP echo request to `8.8.8.8` and waits up to 5 seconds for a reply.
4. It returns the result as Prometheus metrics, including `probe_success`, `probe_duration_seconds`, and ICMP-specific fields.
5. VictoriaMetrics stores these time-series with the label `instance="8.8.8.8"`.
6. When a Grafana panel query runs (on page load or at each 30 s refresh), it queries VictoriaMetrics over the selected time range and renders the results.

---

## Configuration reference

**`.env`** (copy from `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `GF_ADMIN_PASSWORD` | `changeme` | Grafana admin password — run `./change-password.sh` after changing |

---

## Quick start

```bash
# 1. Set the Grafana password
cp .env.example .env
nano .env

# 2. Start the stack
docker compose up -d

# 3. Check everything is running
docker compose ps
docker compose logs -f
```

### Restarting the stack

Use this after a config change, a `git pull`, or to recover from a stale-container error:

```bash
# from the repo root
./restart.sh internet-monitor
```

This removes all containers first (`down --remove-orphans`) then recreates them fresh, matching the behaviour of the systemd/launchd service units. Named volumes are preserved.

Grafana is available at **http://\<VM-IP\>:3000**  
Login: `admin` / password set in `.env`

The *Internet connection quality* dashboard is pre-loaded under **Dashboards → Network**.

### Changing the admin password

Grafana only reads `GF_SECURITY_ADMIN_PASSWORD` on the **first startup** — after that the password lives in its database. To update it:

```bash
# 1. Edit .env
nano .env   # update GF_ADMIN_PASSWORD

# 2. Push the new value into Grafana
./change-password.sh
```

The script uses `grafana-cli` inside the running container to update the database directly. No restart is required.

---

### Optional: import community dashboards

Additional dashboards from Grafana.com can be imported via **Dashboards → Import**:

| Dashboard | ID | Usage |
|---|---|---|
| Prometheus Blackbox Exporter | **7587** | Alternative latency / availability view |
| Speedtest Exporter | **13665** | Alternative Speedtest view |

Select **VictoriaMetrics** as the datasource when importing.
