#!/usr/bin/env bash
set -euo pipefail

GITHUB_USER="braispm9"
REPO_NAME="K3s-Manager_RustVersion"
BRANCH="main"
INSTALL_DIR="/usr/local/bin"
INSTALLER_VERSION="3.0"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" ]] || REAL_HOME="$HOME"

need_root() { (( EUID == 0 )) || { echo 'Run with sudo: sudo ./k3sinstaller.sh [cli|gui|purge]' >&2; exit 1; }; }
download() { curl -fsSL --retry 3 "$1" -o "$2"; }

show_help() { cat <<EOF
K3s Manager Rust installer v$INSTALLER_VERSION
Usage: sudo ./k3sinstaller.sh [cli|gui|purge|-u|-v|-h]
EOF
}

resolve_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) return 1;; esac; }

install_kubectl() {
    command -v kubectl >/dev/null && return
    local arch="$(resolve_arch)" tmp="$(mktemp)"
    local version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/$version/bin/linux/$arch/kubectl" -o "$tmp"
    install -m 0755 "$tmp" /usr/local/bin/kubectl; rm -f "$tmp"
}

install_dependencies() {
    for pkg in curl ca-certificates bash sudo netcat-openbsd; do command -v "$pkg" >/dev/null 2>&1 || true; done
    install_kubectl
    if command -v k3s >/dev/null || [[ -x /usr/local/bin/k3s ]]; then systemctl enable --now k3s >/dev/null 2>&1 || true
    else curl -sfL https://get.k3s.io | sh -
    fi
}

configure_network() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    grep -q '^net.ipv4.ip_forward=' /etc/sysctl.conf 2>/dev/null && sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true; ufw reload >/dev/null 2>&1 || true; fi
}

configure_kubeconfig() {
    for _ in {1..30}; do [[ -f /etc/rancher/k3s/k3s.yaml ]] && break; sleep 1; done
    [[ -f /etc/rancher/k3s/k3s.yaml ]] || { echo 'Warning: K3s kubeconfig was not created.'; return 0; }
    install -d -m 0700 -o "$REAL_USER" -g "$REAL_USER" "$REAL_HOME/.kube"
    install -m 0600 -o "$REAL_USER" -g "$REAL_USER" /etc/rancher/k3s/k3s.yaml "$REAL_HOME/.kube/config"
    cat >> "$REAL_HOME/.profile" <<'EOF'
export KUBECONFIG="$HOME/.kube/config"
EOF
}

install_files() {
    local mode="${1:-cli}" base="https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/$BRANCH"
    download "$base/k3smanager.sh" "$INSTALL_DIR/k3smanager.sh"
    install -m 0755 -o root -g root "$INSTALL_DIR/k3smanager.sh" "$INSTALL_DIR/k3smanager"
    cp "$INSTALL_DIR/k3smanager.sh" "$INSTALL_DIR/k3smanager.sh"
    if [[ "$mode" == gui ]]; then
        download "$base/target/release/k3smanager" "$INSTALL_DIR/k3smanager-gui" 2>/dev/null || { echo 'GUI binary is not published yet. Install with: cargo install --path .'; return 1; }
        chmod 0755 "$INSTALL_DIR/k3smanager-gui"
    fi
}

configure_aliases() {
    local rc="$REAL_HOME/.bashrc"; [[ -f "$REAL_HOME/.zshrc" ]] && rc="$REAL_HOME/.zshrc"
    sed -i '/# K3s Manager Rust/d;/alias k3smanager=/d;/alias k3smanager-gui=/d;/export KUBECONFIG=/d' "$rc" 2>/dev/null || true
    cat >> "$rc" <<'EOF'
# K3s Manager Rust
export KUBECONFIG="$HOME/.kube/config"
alias k3smanager='/usr/local/bin/k3smanager'
alias k3smanager-gui='/usr/local/bin/k3smanager-gui'
EOF
    chown "$REAL_USER":"$REAL_USER" "$rc" 2>/dev/null || true
}

purge() {
    [[ -f /usr/local/bin/k3s-uninstall.sh ]] && /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
    [[ -f /usr/bin/k3s-uninstall.sh ]] && /usr/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
    rm -f "$INSTALL_DIR/k3smanager" "$INSTALL_DIR/k3smanager.sh" "$INSTALL_DIR/k3smanager-gui"
    rm -rf "$REAL_HOME/.kube"
}

verify_update() {
    local remote="$(mktemp)"
    if download "https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/$BRANCH/k3sinstaller.sh" "$remote"; then
        local version="$(grep -m1 '^INSTALLER_VERSION=' "$remote" | cut -d'=' -f2 | tr -d '"')"
        [[ "$version" != "$INSTALLER_VERSION" && -n "$version" ]] && echo "Update available: $version" || echo "Installer is up to date: $INSTALLER_VERSION"
    fi
    rm -f "$remote"
}

need_root
case "${1:-}" in
  -h|--help) show_help;; -v|--version) echo "K3s Manager Rust installer v$INSTALLER_VERSION";; -u|--verify-update) verify_update;; purge) purge;; cli|gui|"")
    mode="${1:-cli}"; mode="$mode"; [[ "$mode" == "" ]] && mode="cli"
    install_dependencies; configure_network; configure_kubeconfig; install_files "$mode"; configure_aliases
    echo 'Installation complete. Open a new shell and run: k3smanager'
    [[ "$mode" == gui ]] && echo 'GUI: k3smanager-gui' || true;;
  *) echo 'Unknown option.'; show_help; exit 1;;
esac
