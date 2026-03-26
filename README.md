# docker-to-corefile

Watches the Docker event stream and automatically generates [CoreDNS](https://coredns.io/) zone files and a Corefile from container labels. Designed to sit alongside any reverse proxy (Traefik, Caddy, nginx, etc.) and keep local DNS in sync with running containers — no restarts required.

## How it works

1. On startup, scans all running containers for labels matching `LABEL_PREFIX`
2. Extracts FQDNs from those labels and groups them by domain
3. Writes a zone file per domain and regenerates the Corefile
4. Watches the Docker event stream for `start`, `stop`, `die`, `destroy`, `pause`, and `unpause` events
5. Re-runs the scan on any event, updating zone files and the Corefile in place
6. CoreDNS picks up changes automatically via its `reload` plugin — no CoreDNS restart needed

## Usage

### Label your containers

Add a label to any container you want a DNS record for:

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - proxy.host=myapp.example.com
```

Multiple FQDNs per container are supported as a comma-separated list:

```yaml
labels:
  - proxy.host=myapp.example.com, alias.example.com
```

### Run docker-to-corefile

```yaml
services:
  docker-to-corefile:
    image: ghcr.io/yourusername/docker-to-corefile:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - coredns_config:/etc/coredns
    environment:
      - PROXY_IP=192.168.1.10        # IP all DNS records point to (your proxy host)
      - UPSTREAM_DNS=1.1.1.1 8.8.8.8 # Fallback DNS for non-local queries
```

### Run CoreDNS

CoreDNS should share the same config volume and have the `reload` plugin enabled in its Corefile. `docker-to-corefile` will manage the Corefile automatically, but you need CoreDNS running to serve it:

```yaml
services:
  coredns:
    image: coredns/coredns:latest
    restart: unless-stopped
    ports:
      - "53:53/udp"
      - "53:53/tcp"
    volumes:
      - coredns_config:/etc/coredns
    command: -conf /etc/coredns/Corefile

volumes:
  coredns_config:
```

The generated Corefile includes a `reload` block in the catch-all zone, so CoreDNS will pick up zone file changes within the configured `RELOAD_INTERVAL` without restarting.

## Environment variables

| Variable | Default | Required | Description |
|---|---|---|---|
| `PROXY_IP` | — | ✅ | IP address all DNS A records will point to |
| `LABEL_PREFIX` | `proxy.host` | | Docker label key to watch for FQDNs |
| `COREDNS_DIR` | `/etc/coredns` | | Directory to write zone files and Corefile into |
| `COREFILE` | `${COREDNS_DIR}/Corefile` | | Full path to the Corefile |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | | Path to the Docker unix socket |
| `TTL` | `60` | | DNS TTL for generated records (seconds) |
| `SOA_NS` | `ns1` | | SOA nameserver hostname prefix |
| `SOA_ADMIN` | `admin` | | SOA admin contact hostname prefix |
| `UPSTREAM_DNS` | `1.1.1.1 8.8.8.8` | | Space-separated upstream resolvers for the catch-all forward block |
| `RELOAD_INTERVAL` | `10s` | | CoreDNS reload interval written into the Corefile |

## Example with Traefik

A common pattern is to use the same alias variable for both Traefik routing labels and the DNS label:

```yaml
# .env
ALIAS=myapp
PORT=8080
PROXY_IP=192.168.1.10
```

```yaml
services:
  myapp:
    image: myapp:latest
    container_name: ${ALIAS}
    labels:
      - traefik.enable=true
      - traefik.http.routers.${ALIAS}.rule=Host(`${ALIAS}.example.com`)
      - traefik.http.routers.${ALIAS}.entrypoints=websecure
      - traefik.http.services.${ALIAS}.loadbalancer.server.port=${PORT}
      - proxy.host=${ALIAS}.example.com
```

## ⚠️ Caveats and known limitations

### No FQDN validation

Label values are used as-is to generate DNS zone entries. If a label contains an invalid hostname, malformed FQDN, special characters, or anything that isn't a valid DNS name, it will be written directly into the zone file. CoreDNS may reject the zone or behave unexpectedly as a result.

**Garbage in, garbage out** — make sure your label values are valid FQDNs. There is currently no sanitisation or validation of label values before they are written.

### Single IP per label

All generated A records point to the same `PROXY_IP`. There is no support for per-container IPs or multiple A records for the same hostname.

### Two-label domain extraction

The domain is extracted by taking the last two dot-separated labels of the FQDN (e.g. `example.com` from `service.example.com`). This means multi-part TLDs like `.co.uk` are not handled correctly — `service.example.co.uk` would produce a zone for `co.uk` rather than `example.co.uk`.

### Docker socket access

This container requires read access to the Docker socket (`/var/run/docker.sock`). This grants significant privilege — treat it accordingly and do not expose it unnecessarily.

## Building locally

```sh
docker build -t docker-to-corefile .
```

## License

MIT
