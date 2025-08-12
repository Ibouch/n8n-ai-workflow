#!/usr/bin/env bash
# ==============================================================================
# N8N INFRASTRUCTURE DEPENDENCIES INSTALLER
# ==============================================================================
# Installs required system dependencies for Debian 12 (target)
# - Keeps it simple and idempotent
# - Uses distribution packages (no custom repos) to avoid complexity
#
# Required tools for this project:
#  - docker (daemon + CLI)
#  - docker compose (docker compose)
#  - apparmor-utils (Linux security)
#  - auditd (Linux auditing)
#  - fail2ban (web protection)
#  - age (backup encryption)
#  - jq (JSON parsing)
#  - curl, wget, openssl, tar, gzip, findutils, coreutils, iproute2, net-tools, lsof

set -euo pipefail

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok() { printf "\033[0;32m✔\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
err() { printf "\033[0;31m✗ %s\033[0m\n" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  local pkgs=("$@")
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends "${pkgs[@]}"
  else
    apt-get update -y
    apt-get install -y --no-install-recommends "${pkgs[@]}"
  fi
}

systemctl_enable_now() {
  local unit="$1"
  if need_cmd systemctl; then
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      sudo systemctl enable --now "$unit" >/dev/null 2>&1 || true
    else
      systemctl enable --now "$unit" >/dev/null 2>&1 || true
    fi
  fi
}

clean_old_docker() {
  bold "Removing old Docker versions"
  sudo apt-get purge -y docker.io docker-doc docker-compose podman-docker containerd runc || true
}

install_debian() {
  bold "Detected Debian-based system"

  clean_old_docker

  # Core tooling
  apt_install ca-certificates curl wget openssl tar gzip coreutils findutils jq iproute2 net-tools lsof gnupg age apparmor-utils auditd fail2ban

  # Enable security services
  systemctl_enable_now apparmor
  systemctl_enable_now auditd
  systemctl_enable_now fail2ban

  # Add official Docker repo
  if ! apt-cache policy docker-ce >/dev/null 2>&1; then
    bold "Adding Docker official repository"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  fi

  # Install latest Docker & Compose
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Enable Docker
  systemctl_enable_now docker

  # Cleanup unused packages
  bold "Cleaning up unused packages"
  sudo apt-get autoremove -y
  sudo apt-get autoclean -y

  # Verifications
  need_cmd docker && ok "docker: $(docker --version | cut -d',' -f1)" || warn "docker not found"
  if docker compose version >/dev/null 2>&1; then
    ok "compose: $(docker compose version | head -1)"
  else
    warn "docker compose not found"
  fi
  need_cmd age && ok "age: $(age --version 2>&1 | head -1)" || warn "age not found"
  need_cmd jq && ok "jq: $(jq --version)" || warn "jq not found"
  ok "Dependency installation finished"
}

main() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release || true
  fi

  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) install_debian ;;
    *) warn "Unsupported OS detected. Please install dependencies manually" ;;
  esac
}

main "$@"
