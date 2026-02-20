#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Settings
# ----------------------------
WORKDIR="run"
BACKEND_DIR_NAME="backend"

ZIP_CANDIDATES=(
  "bundle/project.zip"
  "bundle/README.zip"
  "project.zip"
  "README.zip"
)

HTTP_PORT_DEFAULT="${HTTP_PORT:-8080}"
HTTPS_PORT_DEFAULT="${HTTPS_PORT:-8443}"

# ----------------------------
# Output helpers
# ----------------------------
info() { echo -e "ℹ️  $*"; }
ok()   { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*"; }
die()  { echo -e "❌ $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# ----------------------------
# Locate ZIP
# ----------------------------
find_zip() {
  for z in "${ZIP_CANDIDATES[@]}"; do
    if [[ -f "$z" ]]; then
      echo "$z"
      return 0
    fi
  done
  return 1
}

# ----------------------------
# Detect extracted project root
# ----------------------------
detect_project_root() {
  # Flat zip case: run/backend exists
  if [[ -d "$WORKDIR/$BACKEND_DIR_NAME" ]]; then
    echo "$WORKDIR"
    return 0
  fi

  # Single top-level directory case
  local only_dir
  only_dir="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -n "$only_dir" && -d "$only_dir/$BACKEND_DIR_NAME" ]]; then
    echo "$only_dir"
    return 0
  fi

  # Search at depth 2
  local found
  found="$(find "$WORKDIR" -maxdepth 2 -type d -name "$BACKEND_DIR_NAME" | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    echo "$(dirname "$found")"
    return 0
  fi

  die "Could not detect project root (no '$BACKEND_DIR_NAME/' found after unzip)."
}

# ----------------------------
# Port management
# ----------------------------
get_listen_pids() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser -n tcp "$port" 2>/dev/null || true
  else
    warn "Neither lsof nor fuser found; cannot check port $port"
    echo ""
  fi
}

kill_port_if_needed() {
  local port="$1"
  local pids
  pids="$(get_listen_pids "$port" | tr '\n' ' ' | xargs echo -n || true)"

  if [[ -n "${pids// }" ]]; then
    warn "Port $port in use by PID(s): $pids — killing..."
    kill $pids 2>/dev/null || true
    sleep 1
    local still
    still="$(get_listen_pids "$port" | tr '\n' ' ' | xargs echo -n || true)"
    if [[ -n "${still// }" ]]; then
      warn "Port $port still in use — force killing PID(s): $still"
      kill -9 $still 2>/dev/null || true
    fi
  else
    ok "Port $port is free"
  fi
}

# ----------------------------
# npm install with fallback
# ----------------------------
install_node_deps() {
  local dir="$1"
  pushd "$dir" >/dev/null

  [[ -f package.json ]] || die "package.json not found in: $dir"

  if [[ -f package-lock.json ]]; then
    info "package-lock.json found → trying npm ci..."
    rm -rf node_modules || true
    if npm ci; then
      ok "npm ci succeeded."
    else
      warn "npm ci failed (lockfile out of sync). Falling back to npm install..."
      npm install
      ok "npm install completed."
    fi
  else
    info "No package-lock.json → running npm install..."
    npm install
    ok "npm install completed."
  fi

  popd >/dev/null
}

# ----------------------------
# Patch backend ports if hardcoded 80/443
# ----------------------------
patch_backend_ports() {
  local server_js="$1"
  local http_port="$2"
  local https_port="$3"

  [[ -f "$server_js" ]] || { warn "No server.js at $server_js (skipping port patch)"; return 0; }

  if grep -qE '\.listen\(\s*80\s*,' "$server_js" && grep -qE '\.listen\(\s*443\s*,' "$server_js"; then
    info "Patching $server_js to use HTTP_PORT/HTTPS_PORT (defaults $http_port/$https_port)..."
    cp "$server_js" "$server_js.bak"

    # GNU sed
    if sed --version >/dev/null 2>&1; then
      sed -i \
        -e "s/\.listen(\s*80\s*,/\.listen(parseInt(process.env.HTTP_PORT || '${http_port}', 10),/g" \
        -e "s/\.listen(\s*443\s*,/\.listen(parseInt(process.env.HTTPS_PORT || '${https_port}', 10),/g" \
        "$server_js"
    else
      # BSD sed (macOS)
      sed -i '' \
        -e "s/\.listen(\s*80\s*,/\.listen(parseInt(process.env.HTTP_PORT || '${http_port}', 10),/g" \
        -e "s/\.listen(\s*443\s*,/\.listen(parseInt(process.env.HTTPS_PORT || '${https_port}', 10),/g" \
        "$server_js"
    fi

    ok "Patched ports. Backup saved: $server_js.bak"
  else
    info "No hardcoded 80/443 listen patterns found (no port patch needed)."
  fi
}

# ----------------------------
# Ensure TLS files in backend
# ----------------------------
ensure_tls_files() {
  local project_root="$1"
  local backend_dir="$2"

  local expected_cert="$backend_dir/kaka.com.pem"
  local expected_key="$backend_dir/kaka.com-key.pem"

  [[ -d "$backend_dir" ]] || return 0

  if [[ ! -f "$expected_cert" && -f "$project_root/kaka.com.pem" ]]; then
    cp "$project_root/kaka.com.pem" "$expected_cert"
    ok "Copied kaka.com.pem into backend/"
  fi
  if [[ ! -f "$expected_key" && -f "$project_root/kaka.com-key.pem" ]]; then
    cp "$project_root/kaka.com-key.pem" "$expected_key"
    ok "Copied kaka.com-key.pem into backend/"
  fi
}

# ----------------------------
# MAIN
# ----------------------------
need_cmd unzip
need_cmd node
need_cmd npm

ZIP_PATH="$(find_zip)" || die "ZIP not found. Put it at bundle/project.zip (preferred) or bundle/README.zip."
ok "Using ZIP: $ZIP_PATH"

# Use absolute paths to avoid cwd issues
REPO_ROOT="$(pwd)"
ABS_WORKDIR="$REPO_ROOT/$WORKDIR"
ABS_LOGDIR="$ABS_WORKDIR/logs"

info "Preparing workspace..."
rm -rf "$ABS_WORKDIR"
mkdir -p "$ABS_WORKDIR"
mkdir -p "$ABS_LOGDIR"

info "Unzipping (structure preserved)..."
unzip -q "$REPO_ROOT/$ZIP_PATH" -d "$ABS_WORKDIR"

# For detection functions, work with relative WORKDIR but from repo root
# We'll temporarily cd to repo root to keep it consistent.
cd "$REPO_ROOT"

# Because unzip went to ABS_WORKDIR, set WORKDIR to absolute for detection safely
WORKDIR="$ABS_WORKDIR"

PROJECT_ROOT="$(detect_project_root)"
ok "Project root detected: $PROJECT_ROOT"

[[ -d "$PROJECT_ROOT/$BACKEND_DIR_NAME" ]] || die "Missing backend folder at: $PROJECT_ROOT/$BACKEND_DIR_NAME"

info "Installing Node dependencies..."
install_node_deps "$PROJECT_ROOT"

ensure_tls_files "$PROJECT_ROOT" "$PROJECT_ROOT/$BACKEND_DIR_NAME"

HTTP_PORT="$HTTP_PORT_DEFAULT"
HTTPS_PORT="$HTTPS_PORT_DEFAULT"

if [[ "$(id -u)" -ne 0 ]]; then
  info "Not running as root → using non-privileged ports HTTP=$HTTP_PORT HTTPS=$HTTPS_PORT"
  patch_backend_ports "$PROJECT_ROOT/$BACKEND_DIR_NAME/server.js" "$HTTP_PORT" "$HTTPS_PORT"
fi

info "Checking/clearing ports..."
kill_port_if_needed "$HTTP_PORT"
kill_port_if_needed "$HTTPS_PORT"

# Ensure .env exists if you use it
if [[ -f "$PROJECT_ROOT/.env.example" && ! -f "$PROJECT_ROOT/.env" ]]; then
  cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
  ok "Created .env from .env.example"
fi

info "Starting application..."
pushd "$PROJECT_ROOT" >/dev/null

export HTTP_PORT HTTPS_PORT

# Ensure log dir exists right before start (extra safety)
mkdir -p "$ABS_LOGDIR"

nohup npm start > "$ABS_LOGDIR/backend.log" 2>&1 &
APP_PID=$!
echo "$APP_PID" > "$ABS_LOGDIR/app.pid"

popd >/dev/null

ok "App started (PID: $APP_PID)"
ok "Logs: $ABS_LOGDIR/backend.log"
echo ""
echo "➡️  Try:"
echo "   HTTP : http://localhost:${HTTP_PORT}"
echo "   HTTPS: https://localhost:${HTTPS_PORT}"
echo ""
echo "🛑 Stop:"
echo "   kill $(cat "$ABS_LOGDIR/app.pid")"
