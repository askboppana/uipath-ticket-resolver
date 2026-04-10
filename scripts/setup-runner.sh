#!/bin/bash
# setup-runner.sh - Set up a GitHub Actions self-hosted runner on Linux
# Installs dependencies, downloads the runner, installs security tools
# (trivy, gitleaks, syft), and configures the runner as a service.

set -euo pipefail

# --- Parse arguments ---
URL=""
TOKEN=""
LABELS=""
NAME=""
RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"

usage() {
    echo "Usage: setup-runner.sh --url <repo_url> --token <reg_token> [--labels <labels>] [--name <name>]"
    echo ""
    echo "Arguments:"
    echo "  --url      GitHub repository or organization URL"
    echo "  --token    Runner registration token"
    echo "  --labels   Comma-separated runner labels (default: self-hosted,linux,x64)"
    echo "  --name     Runner name (default: hostname)"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url)    URL="$2";    shift 2 ;;
        --token)  TOKEN="$2";  shift 2 ;;
        --labels) LABELS="$2"; shift 2 ;;
        --name)   NAME="$2";   shift 2 ;;
        --help|-h) usage ;;
        *) echo "[FAIL] Unknown argument: $1"; usage ;;
    esac
done

if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
    echo "[FAIL] --url and --token are required"
    usage
fi

if [ -z "$NAME" ]; then
    NAME="$(hostname)"
fi

if [ -z "$LABELS" ]; then
    LABELS="self-hosted,linux,x64"
fi

echo "[INFO] Runner configuration:"
echo "  URL:     ${URL}"
echo "  Name:    ${NAME}"
echo "  Labels:  ${LABELS}"
echo "  Version: ${RUNNER_VERSION}"
echo "  Dir:     ${RUNNER_DIR}"
echo ""

# --- Install system dependencies ---
echo "[INFO] Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -qq

sudo apt-get install -y -qq \
    curl \
    wget \
    jq \
    git \
    unzip \
    zip \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3 \
    python3-pip \
    docker.io \
    containerd

echo "[PASS] System dependencies installed"

# --- Download and extract GitHub Actions runner ---
echo "[INFO] Setting up GitHub Actions runner..."

sudo mkdir -p "$RUNNER_DIR"
sudo chown "$(id -u):$(id -g)" "$RUNNER_DIR"
cd "$RUNNER_DIR"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  RUNNER_ARCH="x64" ;;
    aarch64) RUNNER_ARCH="arm64" ;;
    armv7l)  RUNNER_ARCH="arm" ;;
    *)       echo "[FAIL] Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

RUNNER_TAR="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TAR}"

echo "[INFO] Downloading runner from: ${RUNNER_URL}"
curl -sL -o "$RUNNER_TAR" "$RUNNER_URL"

echo "[INFO] Extracting runner..."
tar xzf "$RUNNER_TAR"
rm -f "$RUNNER_TAR"

echo "[PASS] GitHub Actions runner downloaded and extracted"

# --- Install Trivy (vulnerability scanner) ---
echo "[INFO] Installing Trivy..."
TRIVY_VERSION="${TRIVY_VERSION:-0.54.1}"

curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | \
    sudo sh -s -- -b /usr/local/bin "v${TRIVY_VERSION}" 2>/dev/null || {
    echo "[INFO] Trivy install script failed, trying direct download..."
    TRIVY_TAR="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
    curl -sL -o "/tmp/${TRIVY_TAR}" \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${TRIVY_TAR}"
    sudo tar xzf "/tmp/${TRIVY_TAR}" -C /usr/local/bin trivy
    rm -f "/tmp/${TRIVY_TAR}"
}

if command -v trivy >/dev/null 2>&1; then
    echo "[PASS] Trivy installed: $(trivy --version 2>/dev/null | head -1)"
else
    echo "[FAIL] Trivy installation failed"
fi

# --- Install Gitleaks (secret scanner) ---
echo "[INFO] Installing Gitleaks..."
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.18.4}"

GITLEAKS_TAR="gitleaks_${GITLEAKS_VERSION}_linux_${RUNNER_ARCH}.tar.gz"
curl -sL -o "/tmp/${GITLEAKS_TAR}" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${GITLEAKS_TAR}"
sudo tar xzf "/tmp/${GITLEAKS_TAR}" -C /usr/local/bin gitleaks
rm -f "/tmp/${GITLEAKS_TAR}"

if command -v gitleaks >/dev/null 2>&1; then
    echo "[PASS] Gitleaks installed: $(gitleaks version 2>/dev/null)"
else
    echo "[FAIL] Gitleaks installation failed"
fi

# --- Install Syft (SBOM generator) ---
echo "[INFO] Installing Syft..."
SYFT_VERSION="${SYFT_VERSION:-1.9.0}"

curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | \
    sudo sh -s -- -b /usr/local/bin "v${SYFT_VERSION}" 2>/dev/null || {
    echo "[INFO] Syft install script failed, trying direct download..."
    SYFT_TAR="syft_${SYFT_VERSION}_linux_amd64.tar.gz"
    curl -sL -o "/tmp/${SYFT_TAR}" \
        "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/${SYFT_TAR}"
    sudo tar xzf "/tmp/${SYFT_TAR}" -C /usr/local/bin syft
    rm -f "/tmp/${SYFT_TAR}"
}

if command -v syft >/dev/null 2>&1; then
    echo "[PASS] Syft installed: $(syft version 2>/dev/null | head -1)"
else
    echo "[FAIL] Syft installation failed"
fi

# --- Configure the runner ---
echo "[INFO] Configuring runner..."
cd "$RUNNER_DIR"

./config.sh \
    --url "$URL" \
    --token "$TOKEN" \
    --name "$NAME" \
    --labels "$LABELS" \
    --unattended \
    --replace

echo "[PASS] Runner configured successfully"

# --- Install and start as a service ---
echo "[INFO] Installing runner as a service..."

sudo ./svc.sh install
sudo ./svc.sh start

echo "[PASS] Runner service installed and started"

# --- Verify ---
echo ""
echo "=== Setup Complete ==="
echo "[INFO] Runner name:   ${NAME}"
echo "[INFO] Runner labels: ${LABELS}"
echo "[INFO] Runner dir:    ${RUNNER_DIR}"
echo ""
echo "[INFO] Installed tools:"
command -v trivy   >/dev/null 2>&1 && echo "  [PASS] trivy"   || echo "  [FAIL] trivy"
command -v gitleaks >/dev/null 2>&1 && echo "  [PASS] gitleaks" || echo "  [FAIL] gitleaks"
command -v syft    >/dev/null 2>&1 && echo "  [PASS] syft"    || echo "  [FAIL] syft"
command -v docker  >/dev/null 2>&1 && echo "  [PASS] docker"  || echo "  [FAIL] docker"
command -v git     >/dev/null 2>&1 && echo "  [PASS] git"     || echo "  [FAIL] git"
command -v jq      >/dev/null 2>&1 && echo "  [PASS] jq"      || echo "  [FAIL] jq"
echo ""
echo "[PASS] Self-hosted runner setup complete"
exit 0
