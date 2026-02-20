#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Config (edit these)
# ----------------------------
ZIP_PATH="bundle/project.zip"
WORKDIR="run"                  # Where it will unzip
PROJECT_DIR="$WORKDIR/project" # Folder name after unzip (we will detect if different)
BACKEND_SUBDIR="backend"
FRONTEND_SUBDIR="frontend"
DATABASE_SUBDIR="database"

BACKEND_PORT="${BACKEND_PORT:-3000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"  # only used if you serve a frontend dev server
KILL_PORTS=("${BACKEND_PORT}")          # add more if needed e.g. ("3000" "5173")

# How to start the backend:
BACKEND_START_CMD=("npm" "start")       # or: ("node" "server.js")

# ----------------------------
# Helpers
# ----------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Missing required command: $1"
    exit 1
  }
}

kill_port_if_in_use() {
  local port="$1"
  # mac/linux:
  local pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN || true)"
  else
    echo "⚠️ lsof not found; cannot check port $port"
    return 0
  fi

  if [[ -n "$pids" ]]; then
    echo "⚠️ Port $port is in use by PID(s): $pids — killing..."
    # Try graceful first, then force
    kill $pids 2>/dev/null || true
    sleep 1
    # If still running, force
    local still=""
    still="$(lsof -tiTCP:"$port" -sTCP:LISTEN || true)"
    if [[ -n "$still" ]]; then
      echo "⚠️ PID(s) still listening on $port: $still — force killing..."
      kill -9 $still 2>/dev/null || true
    fi
  else
    echo "✅ Port $port is free"
  fi
}

detect_project_dir() {
  # If zip unzips into a single top-level directory, use it.
  local top
  top="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -n "$top" ]]; then
    echo "$top"
  else
    echo ""
  fi
}

# ----------------------------
# Preflight
# ----------------------------
need_cmd unzip
need_cmd node
need_cmd npm
need_cmd lsof

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "❌ ZIP not found at: $ZIP_PATH"
  echo "   Put your ZIP there (bundle/project.zip) or update ZIP_PATH in deploy.sh"
  exit 1
fi

echo "✅ Preflight OK"

# ----------------------------
# Unzip cleanly
# ----------------------------
echo "📦 Preparing workspace..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

echo "📦 Unzipping: $ZIP_PATH -> $WORKDIR"
unzip -q "$ZIP_PATH" -d "$WORKDIR"

PROJECT_DIR_DETECTED="$(detect_project_dir)"
if [[ -n "$PROJECT_DIR_DETECTED" ]]; then
  PROJECT_DIR="$PROJECT_DIR_DETECTED"
fi

echo "📁 Project directory: $PROJECT_DIR"

# Validate structure
if [[ ! -d "$PROJECT_DIR/$BACKEND_SUBDIR" ]]; then
  echo "❌ Backend folder not found at: $PROJECT_DIR/$BACKEND_SUBDIR"
  echo "   Fix BACKEND_SUBDIR or ensure your ZIP contains the correct structure."
  exit 1
fi

# ----------------------------
# Ports
# ----------------------------
echo "🔌 Checking ports..."
for p in "${KILL_PORTS[@]}"; do
  kill_port_if_in_use "$p"
done

# ----------------------------
# Install deps
# ----------------------------
echo "📥 Installing backend dependencies..."
pushd "$PROJECT_DIR/$BACKEND_SUBDIR" >/dev/null

if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

# Ensure env file exists
if [[ ! -f ".env" ]]; then
  if [[ -f ".env.example" ]]; then
    cp ".env.example" ".env"
    echo "✅ Created backend/.env from .env.example"
  else
    echo "⚠️ No .env or .env.example found in backend/. Proceeding anyway."
  fi
fi

popd >/dev/null

# Optional: frontend deps (only if it has its own package.json)
if [[ -d "$PROJECT_DIR/$FRONTEND_SUBDIR" ]] && [[ -f "$PROJECT_DIR/$FRONTEND_SUBDIR/package.json" ]]; then
  echo "📥 Installing frontend dependencies..."
  pushd "$PROJECT_DIR/$FRONTEND_SUBDIR" >/dev/null
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  popd >/dev/null
else
  echo "ℹ️ No frontend package.json detected (static HTML or served by backend). Skipping frontend install."
fi

# ----------------------------
# Database init (SQLite style)
# ----------------------------
# If you use SQLite schema.sql, you can auto-init it here if sqlite3 exists.
if command -v sqlite3 >/dev/null 2>&1; then
  if [[ -f "$PROJECT_DIR/$DATABASE_SUBDIR/schema.sql" ]]; then
    mkdir -p "$PROJECT_DIR/$DATABASE_SUBDIR"
    if [[ ! -f "$PROJECT_DIR/$DATABASE_SUBDIR/app.db" ]]; then
      echo "🗄️ Initializing SQLite DB..."
      sqlite3 "$PROJECT_DIR/$DATABASE_SUBDIR/app.db" < "$PROJECT_DIR/$DATABASE_SUBDIR/schema.sql"
      echo "✅ Created database/app.db from schema.sql"
    else
      echo "ℹ️ database/app.db already exists. Skipping DB init."
    fi
  fi
else
  echo "ℹ️ sqlite3 not installed. Skipping DB init."
fi

# ----------------------------
# Start services
# ----------------------------
echo "🚀 Starting backend on port $BACKEND_PORT..."
pushd "$PROJECT_DIR/$BACKEND_SUBDIR" >/dev/null

# Export PORT for common Node patterns
export PORT="$BACKEND_PORT"

# Run in background and log
mkdir -p ../logs
( "${BACKEND_START_CMD[@]}" ) > ../logs/backend.log 2>&1 &

BACKEND_PID=$!
echo "✅ Backend started (PID: $BACKEND_PID). Logs: $PROJECT_DIR/logs/backend.log"

popd >/dev/null

echo ""
echo "✅ Done."
echo "➡️ Open your app (depending on your project):"
echo "   - Backend: http://localhost:$BACKEND_PORT"
echo ""
echo "To stop backend:"
echo "   kill $BACKEND_PID"
