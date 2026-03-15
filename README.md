# home-infra

Personal home infrastructure managed as code. This repository contains Docker Compose stacks for all self-hosted services running across two hosts — a TrueNAS NAS and a Mac Mini.

## Hosts

### `nas/`
Services running on TrueNAS via Docker. This is the primary storage and media host.

| Service | Description |
|---|---|
| Immich | Self-hosted photo and video library |
| Audiobookshelf| Self-hosted audiobook and epub library |


### `mac-mini/`
Services running on a Mac Mini.

| Service | Stack | Description |
|---|---|---|
| Home Assistant Accessories| `ha-stack` | Piper (TTS), Whisper (STT) and OpenWakeWord for voice assistants |
| Uptime Kuma | `monitoring` | Service uptime monitoring and status pages |
| Prometheus | `monitoring` | Metrics collection and alerting |
| Grafana | `monitoring` | Data Displaying for cool dashboards |
| Homepage | `services` | Cool homepage for all self-hosted apps |
| OpenWebUI | `ai` | Chat interface for AI models |



## How it works

This repo uses a **GitOps** workflow — pushing to `main` is all that's needed to deploy or update services. Two tools work together to make this happen automatically:

### [Doco-CD](https://github.com/kimdre/doco-cd)
Doco-CD is a lightweight GitOps tool that polls this repository every 30 minutes and automatically runs `docker compose up` when it detects changes on `main`. It is deployed via the root `docker-compose.yml` on each host.

Each host runs its own Doco-CD instance and deploys only the services relevant to it. The target is determined by the `DOCO_CD_TARGET` environment variable defined in the root `.env` file on each host — for example `nas` on TrueNAS and `mac-mini` on the Mac Mini. Doco-CD uses `auto_discover` to automatically find and deploy all compose stacks within the target directory.

### [Renovate](https://github.com/renovatebot/renovate)
The Renovate GitHub App monitors this repository for outdated Docker image tags. It runs every weekend and automatically creates grouped PRs for minor and patch updates, which are automerged into `main` without manual intervention. Major version updates create a PR but require manual review and approval before merging.

Once Renovate merges an update into `main`, Doco-CD picks it up on its next poll and redeploys the affected services automatically.

## Repository structure

```
home-infra/
├── docker-compose.yml        # Doco-CD itself
├── mac-mini/
│   ├── ha-stack/
│   │   └── docker-compose.yml   # Home Assistant, Piper, Whisper
│   └── monitoring/
│       ├── docker-compose.yml   # Uptime Kuma, Prometheus, Grafana
│       └── prometheus.yml
├── nas/
│   └── nas-services/
│       └── docker-compose.yml   # Immich and other NAS services
└── renovate.json                # Renovate configuration
```

## Secrets

Secrets are **not stored in this repository**. Each host has a local `.env` file stored outside the repo that is mounted into the Doco-CD container. Services that require secrets reference them via an absolute `env_file` path pointing to this local file.

## Future Steps

Planned services and improvements to be added to the infrastructure:

| Service | Host | Notes |
|---|---|---|
| Tailscale | NAS | Containerized VPN for secure remote access |
| Bitwarden (Vaultwarden) | NAS | Self-hosted password manager, requires a local domain and SSL cert |
