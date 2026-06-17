#!/bin/sh
# aussi-configure: register/unregister aussi as an OCI runtime (containerd and/or docker)
# Usage: aussi-configure install | remove

AUSSI_BIN="${AUSSI_BIN:-/usr/local/bin/aussi}"
CONTAINERD_CONF="/etc/containerd/config.toml"
CONTAINERD_CONFD="/etc/containerd/conf.d"
CONTAINERD_SNIPPET="aussi.toml"
DOCKER_CONF="/etc/docker/daemon.json"

log() { echo "aussi-configure: $*"; }
warn() { echo "aussi-configure: WARN: $*" >&2; }

# containerd

containerd_install() {
  if [ ! -f "$CONTAINERD_CONF" ]; then
    log "containerd: $CONTAINERD_CONF not found, skipping"
    return 0
  fi

  if ! grep -q 'conf\.d' "$CONTAINERD_CONF" 2>/dev/null; then
    printf '\nimports = ["%s/*.toml"]\n' "$CONTAINERD_CONFD" \
      >> "$CONTAINERD_CONF" || {
        warn "containerd: failed to append imports to $CONTAINERD_CONF"
        return 1
      }
  fi

  mkdir -p "$CONTAINERD_CONFD"
  cat > "${CONTAINERD_CONFD}/${CONTAINERD_SNIPPET}" << EOF
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.solo5]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.solo5.options]
    BinaryName = "${AUSSI_BIN}"
EOF
  log "containerd: installed solo5 runtime in ${CONTAINERD_CONFD}/${CONTAINERD_SNIPPET}"

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active containerd >/dev/null 2>&1; then
    if systemctl restart containerd; then
      log "containerd: restarted"
    else
      warn "containerd: restart failed"
      return 1
    fi
  fi
}

containerd_remove() {
  if [ -f "${CONTAINERD_CONFD}/${CONTAINERD_SNIPPET}" ]; then
    rm -f "${CONTAINERD_CONFD}/${CONTAINERD_SNIPPET}"
    echo "containerd: removed solo5 runtime snippet"

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active containerd >/dev/null 2>&1; then
      systemctl restart containerd
      echo "containerd: restarted"
    fi
  fi
}

# docker

docker_install() {
  if ! command -v dockerd >/dev/null 2>&1; then
    log "docker: dockerd not found, skipping"
    return 0
  fi

  mkdir -p "$(dirname "$DOCKER_CONF")"

  if [ ! -f "$DOCKER_CONF" ]; then
    cat > "$DOCKER_CONF" << EOF
{
  "runtimes": {
    "solo5": {
      "path": "${AUSSI_BIN}"
    }
  }
}
EOF
    log "docker: created ${DOCKER_CONF} with solo5 runtime"
  elif command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    if jq --arg bin "$AUSSI_BIN" \
         '.runtimes = (.runtimes // {}) + {"solo5": {"path": $bin}}' \
         "$DOCKER_CONF" > "$tmp"
    then
      mv "$tmp" "$DOCKER_CONF"
      log "docker: added solo5 runtime to ${DOCKER_CONF}"
    else
      rm -f "$tmp"
      warn "docker: jq failed to merge runtime into ${DOCKER_CONF}"
      return 1
    fi
  else
    warn "docker: jq not found and ${DOCKER_CONF} already exists; please add manually:"
    echo '  "runtimes": { "solo5": { "path": "'"${AUSSI_BIN}"'" } }'
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
    if systemctl restart docker; then
      log "docker: restarted"
    else
      warn "docker: restart failed — runtime not active"
      return 1
    fi
  else
    warn "docker: not running under systemd; runtime change requires daemon restart"
  fi
}

docker_remove() {
  if [ -f "$DOCKER_CONF" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.runtimes.solo5' "$DOCKER_CONF" >/dev/null 2>&1; then
      tmp=$(mktemp)
      jq 'del(.runtimes.solo5)' "$DOCKER_CONF" > "$tmp"
      mv "$tmp" "$DOCKER_CONF"
      echo "docker: removed solo5 runtime from ${DOCKER_CONF}"

      if command -v systemctl >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
        systemctl restart docker
        echo "docker: restarted"
      fi
    fi
  fi
}

case "${1:-}" in
  install)
    containerd_install || warn "containerd_install reported errors"
    docker_install || warn "docker_install reported errors"
    ;;
  remove)
    containerd_remove || true
    docker_remove || true
    ;;
  *)
    echo "Usage: $0 install | remove" >&2
    exit 1
    ;;
esac
