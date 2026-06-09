---
name: podman
requires: podman
description: "Run and manage containers with Podman — a daemonless, rootless drop-in for Docker. Use when the mission involves pulling images, running containers, building images, managing pods, inspecting logs, or wiring up volumes and networks."
---

# Podman

Podman is a daemonless, rootless container engine. Its CLI is a near-identical drop-in for Docker — replace `docker` with `podman` on almost every standard command (`run`, `build`, `push`, `pull`, `ps`, `logs`, `exec`, `inspect`, `stop`, `rm`, `rmi`, `volume`, `network`, etc.).

This skill covers only what **differs** from Docker.

## Prerequisites

The runtime is **Debian 12 (Bookworm) on arm64**. Podman is in Debian's official repo with arm64 support — no external repo needed.

- Official install docs: https://podman.io/docs/installation
- Debian 12 package: https://packages.debian.org/bookworm/podman

```bash
apt-get update && apt-get install -y \
  podman \
  podman-netavark \   # default network backend
  slirp4netns \       # rootless networking
  uidmap \            # user namespace UID mapping
  fuse-overlayfs      # rootless overlay storage

podman info   # verify runtime is reachable
```

## Key differences from Docker

| Topic | Docker | Podman |
|---|---|---|
| Daemon | Required (`dockerd`) | None — containers are child processes |
| Root | Default (rootless opt-in) | Rootless by default |
| Compose | `docker compose` built-in | `podman compose` (v4.7+) or `podman-compose` |
| Pods | No native pods | `podman pod` commands |
| Systemd | Limited | `podman generate systemd` |
| SELinux volumes | Optional | `:Z` flag often required |

## Rootless containers

Rootless containers map UID 0 inside the container to the invoking user outside — not real root. Most things just work; exceptions are privileged ports (<1024) and some bind-mount permissions.

```bash
podman unshare cat /proc/self/uid_map   # inspect UID mapping
```

## SELinux volume mounts

On SELinux-enabled hosts, bind mounts need a context relabel or they will be denied:

```bash
podman run -v /host/data:/app/data:Z myapp:latest   # :Z relabels for this container
podman run -v /host/data:/app/data:z myapp:latest   # :z shares label across containers
```

## Pods (Podman-specific)

Pods group containers that share one network namespace — analogous to a Kubernetes pod.

```bash
podman pod create --name mypod -p 8080:80
podman run -d --pod mypod --name frontend nginx:alpine
podman run -d --pod mypod --name backend myapp:latest
podman pod ps
podman pod stop mypod
podman pod rm mypod          # removes pod and all its containers
```

## Systemd integration

```bash
podman generate systemd --name web --files --new
# Produces container-web.service — place in ~/.config/systemd/user/
systemctl --user enable --now container-web.service
```

## arm64 notes

This runtime is linux/arm64. Pull images that explicitly support `linux/arm64`; amd64-only images will fail or run slowly under emulation. Specify the platform when needed:

```bash
podman pull --platform linux/arm64 myimage:latest
podman build --platform linux/arm64 -t myapp:latest .
```

## Guardrails

- Run `podman info` first to confirm the runtime is reachable.
- Use `:Z` on bind mounts when on an SELinux host.
- Prefer `--rm` for one-shot tasks.
- Never run `podman system prune -a` without explicit user confirmation.
- Avoid `--privileged`; use `--cap-add` for specific capabilities instead.
