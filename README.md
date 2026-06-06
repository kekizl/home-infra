# home-infra

Personal home infrastructure managed as code. This repository contains Docker Compose stacks for all self-hosted services running across two hosts — a TrueNAS NAS and a Mac Mini.

## Hosts

### `nas/`
Services running on TrueNAS via Docker. This is the primary storage and media host.

| Service | Description |
|---|---|
| Immich | Self-hosted photo and video library |
| Audiobookshelf | Self-hosted audiobook and epub library |
| Navidrome | Self-hosted music streaming alternative |
| FreshRSS | Curated RSS feed for daily digests |
| Restic | Restic-Server, where I store snapshots |
| Syncthing | For storing remote files when needed |
| Prowlarr, Lidarr, qBittorrent | For automating my media library |

### `mac-mini/`
Services running on a Mac Mini.

| Service | Stack | Description |
|---|---|---|
| Home Assistant Accessories| `ha-stack` | Piper (TTS), Whisper (STT) and OpenWakeWord for voice assistants |
| Uptime Kuma | `monitoring` | Service uptime monitoring and status pages |
| Prometheus | `monitoring` | Metrics collection and alerting |
| Grafana | `monitoring` | Data Displaying for cool dashboards |
| Homepage | `services` | Cool homepage for all self-hosted apps |
| Vaultwarden | `services` | Personal and local password manager |
| Restic | `services` | Automated Snapshot based backups |
| Renovate | `services` | Automated Docker Dependency Updates |
| AdguardHome | `dns` | DNS handler for my tailnet |

All services are paired with a Tailscale sidecar. This gives each service a unique entry in my Tailscale mesh network, thus making them available anywhere. It aslo allows me to give them TLS certificates to enable https connections while not exposing any docker ports.

## How it works

This repo uses a **GitOps** workflow — pushing to `main` is all that's needed to deploy or update services. Two tools work together to make this happen automatically:

### [Doco-CD](https://github.com/kimdre/doco-cd)
Doco-CD is a lightweight GitOps tool that polls this repository every 30 minutes and automatically runs `docker compose up` when it detects changes on `main`. It is deployed via the root `docker-compose.yml` on each host.

Each host runs its own Doco-CD instance and deploys only the services relevant to it. The target is determined by the `DOCO_CD_TARGET` environment variable defined in the root `.env` file on each host — for example `nas` on TrueNAS and `mac-mini` on the Mac Mini. Doco-CD uses `auto_discover` to automatically find and deploy all compose stacks within the target directory.

### [Renovate](https://github.com/renovatebot/renovate)
The Renovate GitHub App monitors this repository for outdated Docker image tags. It runs every weekend and automatically creates grouped PRs for minor and patch updates, which are automerged into `main` without manual intervention. Major version updates create a PR but require manual review and approval before merging.

Once Renovate merges an update into `main`, Doco-CD picks it up on its next poll and redeploys the affected services automatically.

### [Restic](https://restic.net)
Restic handles automated snapshot-based backups of service data across both hosts. On each host, a cron job managed by Doco-CD runs restic-backup.sh on a schedule, which stops the relevant containers, takes a snapshot, and restarts them. Snapshots from both hosts are sent to the Restic Server running on the NAS and to remote.
A custom Dockerfile.restic is used to give the container the permissions needed to stop and start other Docker containers during the backup process and also to execute the script.

## Repository structure

```
home-infra/
├── docker-compose.yml        # Doco-CD itself
├── mac-mini/
│   ├── ha-stack/
│   │   └── docker-compose.yml   # Home Assistant, Piper, Whisper
│   ├── services/
│   │   ├── Dockerfile.restic    # Custom Dockerfile to allow restic to start+stop containers
│   │   ├── renovate-wrapper.sh  # Wrapper for Renovate to read my SOPS secrets.
│   │   ├── restic-backup.sh     # Bash script to start, stop and backup relevant containers
│   │   └── docker-compose.yml   # Homepage, Renovate, Restic and Vaultwarden
│   ├── ai/
│   ├── dns/
│   │   └── docker-compose.yml   # Adguard Home
│   └── monitoring/
│       └── docker-compose.yml   # Uptime Kuma, Prometheus, Grafana
├── nas/
│   ├── arr_stack/
│   │   └── docker-compose.yml   # Arr peripherals
│   ├── monitoring/ 
│   │   └── docker-compose.yml   # Node-Exporter
│   ├── syncthing/
│   │   └── docker-compose.yml   # Syncthing
│   ├── restic/
│   │   ├── Dockerfile.restic    # Custom Dockerfile for restic
│   │   ├── restic-backup.sh     # Bash script to start, stop and backup relevant containers
│   │   └── docker-compose.yml   # Restic Server
│   └── nas-services/
│       └── docker-compose.yml   # Immich, FreshRSS, Navidrome and Audiobookshelf
├── secrets/                     # SOPS age encrypted secrets used in containers 
└── renovate.json                # Renovate configuration
```

## Secrets

Secrets are **not stored in this repository**. Each host has a local `.env` file stored outside the repo that is mounted into the Doco-CD container. Services that require secrets reference them via an absolute `env_file` path pointing to this local file.

## Future Steps

Planned services and improvements to be added to the infrastructure:

| Service | Host | Notes |
|---|---|---|
Adding Authelia for 2FA on all self hosted apps.
Containerizing custom AI router
