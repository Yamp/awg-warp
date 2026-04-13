# AWG over WARP

This setup runs two containers:

- `warp`: owns the network namespace, starts Cloudflare WARP, and publishes the configured UDP port.
- `awg`: joins `warp`'s network namespace, starts AmneziaWG, and routes AWG client traffic through WARP.

The containers can be rebuilt and restarted independently. Configs and keys are stored on disk:

- AWG keys and client profile: `data/awg`
- WARP account and profile: `data/warp`

Runtime values are stored in `.env`, which is ignored by git. Run `./install.sh` to generate it. The installer detects the server endpoint, chooses a private AWG subnet, generates AmneziaWG security parameters, installs Docker when needed, starts the containers, and enables the auto-update timer on systemd hosts.

## Run

```bash
sudo ./install.sh
```

The client profile is:

```bash
data/awg/client.conf
```

If you already have Docker installed and only want to start the stack from an existing `.env`:

```bash
docker compose up -d --build
```

## Update AmneziaWG Manually

```bash
./update-awg.sh
```

This checks the latest `master` commit SHAs of:

- `amnezia-vpn/amneziawg-go`
- `amnezia-vpn/amneziawg-tools`

If neither repo changed, it exits without rebuilding or restarting anything. If either repo changed, it rebuilds only the `awg` image pinned to the new commit SHA and recreates only the `awg` container. Existing configs in `data/awg` and `data/warp` are preserved.

## Automatic Updates

Systemd timer:

```bash
systemctl status awg-auto-update.timer
systemctl list-timers awg-auto-update.timer --no-pager
```

Schedule: every day at `00:00 UTC`, which is `03:00 Moscow time`.

## Checks

```bash
docker compose ps
docker logs awg-warp-warp --tail 80
docker logs awg-warp-awg --tail 80
docker exec awg-warp-awg awg show awg0
docker exec awg-warp-warp wg show warp
docker exec awg-warp-warp curl -4fsS https://cloudflare.com/cdn-cgi/trace
```

The last command should include:

```text
warp=on
```
