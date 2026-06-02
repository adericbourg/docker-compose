# docker-compose

Personal collection of self-hosted services managed with Docker Compose.

## Stacks

| Stack | Description |
|---|---|
| [internet-monitor](./internet-monitor/README.md) | Internet connection quality monitoring — latency, packet loss, bandwidth (VictoriaMetrics + Blackbox Exporter + Speedtest + Grafana) |

## Running a stack

```bash
cd <stack-name>
cp .env.example .env   # if the stack has an .env.example
# edit .env as needed
docker compose up -d
```

## Auto-start on boot (systemd)

To have a stack start automatically when the machine boots, create a systemd service unit.

### 1. Create the service file

Create `/etc/systemd/system/<stack-name>.service`, replacing `<stack-name>` and the path:

```ini
[Unit]
Description=<stack-name> docker compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/path/to/docker-compose/<stack-name>
ExecStart=docker compose up -d --remove-orphans
ExecStop=docker compose down

[Install]
WantedBy=multi-user.target
```

Example for `internet-monitor`:

```ini
[Unit]
Description=internet-monitor docker compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/path/to/docker-compose/internet-monitor
ExecStart=docker compose up -d --remove-orphans
ExecStop=docker compose down

[Install]
WantedBy=multi-user.target
```

### 2. Enable and start the service

```bash
# Make sure the Docker daemon itself starts on boot
sudo systemctl enable docker

# Reload systemd, enable and start your stack
sudo systemctl daemon-reload
sudo systemctl enable <stack-name>
sudo systemctl start <stack-name>
```

### 3. Check the status

```bash
sudo systemctl status <stack-name>
```

The stack will now start automatically on every boot, after Docker and the network are ready.
