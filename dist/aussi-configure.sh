#!/bin/sh
# aussi-configure: register/unregister aussi as an OCI runtime (containerd and/or docker)
# Usage: aussi-configure install | remove

set -e

AUSSI_BIN="${AUSSI_BIN:-/usr/local/bin/aussi}"
CONTAINERD_CONF="/etc/containerd/config.toml"
CONTAINERD_CONFD="/etc/containerd/conf.d"
CONTAINERD_SNIPPET="aussi.toml"
DOCKER_CONF="/etc/docker/daemon.json"

# containerd

containerd_install() {
  if [ ! -f "$CONTAINERD_CONF" ]; then
    return
  fi

  # Ensure conf.d imports are enabled
  if ! grep -q 'conf\.d' "$CONTAINERD_CONF" 2>/dev/null; then
    printf '\nimports = ["%s/*.toml"]\n' "$CONTAINERD_CONFD" \
      >> "$CONTAINERD_CONF"
  fi

  mkdir -p "$CONTAINERD_CONFD"
  cat > "${CONTAINERD_CONFD}/${CONTAINERD_SNIPPET}" << EOF
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.solo5]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.solo5.options]
    BinaryName = "${AUSSI_BIN}"
EOF

  echo "containerd: installed solo5 runtime in ${CONTAINERD_CONFD}/${CONTAINERD_SNIPPET}"

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active containerd >/dev/null 2>&1; then
    systemctl restart containerd
    echo "containerd: restarted"
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
    return
  fi

  mkdir -p "$(dirname "$DOCKER_CONF")"

  if [ ! -f "$DOCKER_CONF" ]; then
# create a new $DOCKER_CONF
    cat > "$DOCKER_CONF" << EOF
{
  "runtimes": {
    "solo5": {
      "path": "${AUSSI_BIN}"
    }
  }
}
EOF
    echo "docker: created ${DOCKER_CONF} with solo5 runtime"
  elif command -v jq >/dev/null 2>&1; then
# append solo5 into the existing $DOCKER_CONF
    tmp=$(mktemp)
    jq --arg bin "$AUSSI_BIN" \
      '.runtimes = (.runtimes // {}) + {"solo5": {"path": $bin}}' \
      "$DOCKER_CONF" > "$tmp"
    mv "$tmp" "$DOCKER_CONF"
    echo "docker: added solo5 runtime to ${DOCKER_CONF}"
  else
# fail
    echo "docker: jq not found, please add the following to ${DOCKER_CONF} manually:"
    echo
    echo '  "runtimes": { "solo5": { "path": "'"${AUSSI_BIN}"'" } }'
    echo
    return
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
    systemctl reload docker
    echo "docker: reloaded"
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
        systemctl reload docker
        echo "docker: reloaded"
      fi
    fi
  fi
}

case "${1:-}" in
  install)
    containerd_install
    docker_install
    ;;
  remove)
    containerd_remove
    docker_remove
    ;;
  *)
    echo "Usage: $0 install | remove" >&2
    exit 1
    ;;
esac
