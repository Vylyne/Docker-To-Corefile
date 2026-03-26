#!/bin/sh
set -euo pipefail

# ── Required environment variables ────────────────────────────────────────────
: "${PROXY_IP:?PROXY_IP environment variable is required}"

# ── Optional environment variables ────────────────────────────────────────────
COREDNS_DIR="${COREDNS_DIR:-/etc/coredns}"
COREFILE="${COREFILE:-${COREDNS_DIR}/Corefile}"
DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
LABEL_PREFIX="${LABEL_PREFIX:-proxy.host}"
TTL="${TTL:-60}"
SOA_ADMIN="${SOA_ADMIN:-admin}"
SOA_NS="${SOA_NS:-ns1}"
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1 8.8.8.8}"
RELOAD_INTERVAL="${RELOAD_INTERVAL:-10s}"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Call the Docker API via the unix socket
docker_api() {
    curl -sf --unix-socket "${DOCKER_SOCKET}" "http://localhost$1"
}

# Generate a serial number based on current unix timestamp
serial() {
    date -u +%s
}

# Extract the domain from a FQDN by taking the last two dot-separated labels
# e.g. service.brunton.ca -> brunton.ca
#      a.b.brunton.ca     -> brunton.ca
#      srv.issa-rp.com    -> issa-rp.com
extract_domain() {
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

# Collect all FQDNs from running containers with LABEL_PREFIX.
# Outputs lines of: fqdn
collect_all_fqdns() {
    docker_api "/containers/json" | \
    jq -r --arg labelRegex "^${LABEL_PREFIX}(_[0-9]*)?$" '
       .[].Labels
       | with_entries(if (.key|test($labelRegex)) then {"key": .key, "value": .value} else empty end )
       | .[]
       | select(startswith("*") | not)
       | select(contains("."))
       | split(",")
       | .[]
       | ltrimstr(" ")
       | rtrimstr(" ")
    ' | sort -u
}

# Write a single zone file for a given domain with its hostnames
# Args: $1 = domain, $2 = newline-separated list of FQDNs
write_zone_file() {
    local domain="$1"
    local fqdns="$2"
    local zone_file="${COREDNS_DIR}/${domain}.zone"
    local tmp="${zone_file}.tmp"
    local serial_val
    serial_val=$(serial)

    log "Writing zone: ${zone_file}"

    if [ ! -d "${COREDNS_DIR}/" ]; then
        mkdir -p "${COREDNS_DIR}/"
        chmod +rx "${COREDNS_DIR}/"
    fi

    cat > "${tmp}" <<EOF
\$ORIGIN ${domain}.
\$TTL ${TTL}
@   IN  SOA ${SOA_NS}.${domain}. ${SOA_ADMIN}.${domain}. (
                ${serial_val} ; serial (unix timestamp)
                3600           ; refresh
                900            ; retry
                604800         ; expire
                ${TTL} )       ; minimum TTL

EOF

    echo "${fqdns}" | while IFS= read -r fqdn; do
        [ -z "${fqdn}" ] && continue
        # Get relative name by stripping the domain suffix
        relative="${fqdn%.${domain}}"
        # If nothing was stripped it's the apex
        if [ "${relative}" = "${fqdn}" ]; then
            relative="@"
        fi
        printf "%-40s IN  A   %s\n" "${relative}" "${PROXY_IP}" >> "${tmp}"
        log "  + ${fqdn} -> ${PROXY_IP}"
    done

    chmod +rx "${tmp}"
    mv "${tmp}" "${zone_file}"
}

# Remove zone files for domains that no longer have any containers
cleanup_stale_zones() {
    local active_domains="$1"

    for zone_file in "${COREDNS_DIR}"/*.zone; do
        [ -f "${zone_file}" ] || continue
        local zone_domain
        zone_domain=$(basename "${zone_file}" .zone)
        if ! echo "${active_domains}" | grep -qx "${zone_domain}"; then
            log "Removing stale zone: ${zone_file}"
            rm -f "${zone_file}"
        fi
    done
}

# Regenerate the CoreDNS Corefile based on currently known domains
write_corefile() {
    local active_domains="$1"
    local tmp="${COREFILE}.tmp"

    log "Regenerating Corefile: ${COREFILE}"

    local forward_targets
    forward_targets=$(echo "${UPSTREAM_DNS}" | tr ',' ' ')

    echo "${active_domains}" | while IFS= read -r domain; do
        [ -z "${domain}" ] && continue
        cat >> "${tmp}" <<EOF
${domain} {
    file ${COREDNS_DIR}/${domain}.zone
    log
    errors
}

EOF
        log "  + Corefile block for ${domain}"
    done

    cat >> "${tmp}" <<EOF
. {
    forward . ${forward_targets}
    cache
    reload ${RELOAD_INTERVAL}
    log
    errors
}
EOF

    chmod +rx "${tmp}"
    mv "${tmp}" "${COREFILE}"
    log "Corefile written"
}

# ── Main refresh: collect, group by domain, write zones + Corefile ────────────

refresh() {
    log "Refreshing DNS from Docker labels..."

    all_fqdns=$(collect_all_fqdns)

    if [ -z "${all_fqdns}" ]; then
        log "No FQDNs found in container labels — nothing to write"
        return
    fi

    active_domains=$(echo "${all_fqdns}" | while IFS= read -r fqdn; do
        extract_domain "${fqdn}"
    done | sort -u)

    log "Found domains: $(echo "${active_domains}" | tr '\n' ' ')"

    echo "${active_domains}" | while IFS= read -r domain; do
        [ -z "${domain}" ] && continue
        domain_fqdns=$(echo "${all_fqdns}" | grep -E "\.${domain}$|^${domain}$" || true)
        if [ -n "${domain_fqdns}" ]; then
            write_zone_file "${domain}" "${domain_fqdns}"
        fi
    done

    cleanup_stale_zones "${active_domains}"
    write_corefile "${active_domains}"

    log "Refresh complete"
}

# ── Startup ───────────────────────────────────────────────────────────────────

log "Starting Docker-To-Corefile"
log "  PROXY_IP       = ${PROXY_IP}"
log "  COREDNS_DIR    = ${COREDNS_DIR}"
log "  LABEL_PREFIX   = ${LABEL_PREFIX}"
log "  UPSTREAM_DNS   = ${UPSTREAM_DNS}"
log "  RELOAD_INTERVAL= ${RELOAD_INTERVAL}"

mkdir -p "${COREDNS_DIR}"

refresh

# ── Event loop ────────────────────────────────────────────────────────────────

log "Watching Docker events..."

# URL-encoded filter: {"type":["container"],"event":["start","stop","die","destroy","pause","unpause"]}
EVENTS_FILTER='filters=%7B%22type%22%3A%5B%22container%22%5D%2C%22event%22%3A%5B%22start%22%2C%22stop%22%2C%22die%22%2C%22destroy%22%2C%22pause%22%2C%22unpause%22%5D%7D'

docker_api "/events?${EVENTS_FILTER}" | \
while IFS= read -r event; do
    event_type=$(echo "${event}" | jq -r '.Action // empty')
    container_name=$(echo "${event}" | jq -r '.Actor.Attributes.name // empty')

    [ -z "${event_type}" ] && continue

    log "Docker event: ${event_type} (${container_name})"
    refresh
done

log "Docker event stream ended — exiting"
