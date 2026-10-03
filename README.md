# iXRay installer

Installs and manages the iXRay panel on a server.

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/sephrrr/iXRay-Install/main/ixray.sh)" @ install
```

Needs Ubuntu 22.04+ or Debian 12+, a domain pointing at the server, and a
GitHub token with the `read:packages` scope (the panel image is private).

Afterwards the `ixray` command manages the panel:

| Command | What it does |
| --- | --- |
| `ixray key` | One-time key for creating the owner or resetting its password |
| `ixray status` | Containers and the dashboard address |
| `ixray logs -f` | Follow the panel log |
| `ixray update [version]` | Back up, download the new version, start it |
| `ixray backup` / `ixray restore <file>` | Database dump and restore |
| `ixray path [new]` | Change the secret dashboard address |
| `ixray domain <name>` | Move the panel to another domain |
| `ixray uninstall [--purge]` | Remove the containers (`--purge` also deletes the data) |
