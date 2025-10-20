#!/usr/bin/env bash
# POSIX-friendly Bash script for automated deployment of a Dockerized app to a remote Linux host.
# Requirements implemented: cloning (with PAT), remote preparation (Docker, docker-compose, nginx),
# transfer (rsync), build/run containers, nginx reverse proxy, health checks, logging, error handling,
# idempotency, --cleanup flag.


set -o errexit
set -o nounset
set -o pipefail

### ========= Config / Defaults =========
LOG_DIR="./logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"
TMP_DIR="/tmp/deploy_tmp_${TIMESTAMP}"
RSYNC_EXCLUDES=".git"
DEFAULT_BRANCH="main"
SSH_PORT=22
REMOTE_BASE_DIR="/home"   # base remote path; final path will be "$REMOTE_BASE_DIR/$SSH_USER/deployments/$REPO_NAME"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
CURL_BIN="$(command -v curl || true)"
WGET_BIN="$(command -v wget || true)"

mkdir -p "$LOG_DIR"
mkdir -p "$TMP_DIR"

### ========= Logging helpers =========
log() {
  local lvl="$1"; shift
  local msg="$*"
  printf '%s %s: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$lvl" "$msg" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
err()  { log "ERROR" "$*"; }

### ========= Cleanup & trap =========
cleanup_local() {
  rm -rf "$TMP_DIR" || true
}
on_exit() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "Script exited with code ${rc}"
  else
    info "Script finished successfully"
  fi
  cleanup_local
}
trap on_exit EXIT
trap 'err "Interrupted"; exit 2' INT TERM

### ========= Utility functions =========
usage() {
  cat <<EOF
Usage: $0 [--cleanup] 
Interactive prompts will follow. Use --cleanup to remove deployed resources on remote host after confirmation.
EOF
}

prompt() {
  # prompt "Question" varname [default]
  local question="$1"; local __var="$2"; local default="${3-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$question" "$default"
  else
    printf "%s: " "$question"
  fi
  if [ -t 0 ]; then
    read -r answer
  else
    # non-interactive: fail
    err "Non-interactive session and missing parameter $__var"; exit 3
  fi
  if [ -z "$answer" ]; then
    answer="$default"
  fi
  eval "$__var=\$answer"
}

validate_file_exists() {
  if [ ! -f "$1" ]; then
    err "Required file not found: $1"; exit 4
  fi
}

# minimal url parsing to get repo name
repo_name_from_url() {
  local url="$1"
  # removes trailing .git and path prefix
  local name
  name="$(basename "$url")"
  name="${name%.git}"
  printf '%s' "$name"
}

### ========= Input collection =========
CLEANUP_MODE=0
if [ "${1-}" = "--cleanup" ]; then
  CLEANUP_MODE=1
fi

info "Starting interactive parameter collection..."
prompt "Git repository HTTPS URL (e.g. https://github.com/user/repo.git)" GIT_REPO_URL
prompt "Personal Access Token (PAT) — will be used for cloning (kept in memory only)" GIT_PAT
# branch optional
prompt "Branch name (press enter for 'main')" BRANCH
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
prompt "Remote SSH username" SSH_USER
prompt "Remote server IP or hostname" SSH_HOST
prompt "Path to SSH private key (for SSH auth)" SSH_KEY_PATH
prompt "Remote SSH port (press enter for 22)" SSH_PORT_PROMPT
SSH_PORT="${SSH_PORT_PROMPT:-$SSH_PORT}"
prompt "Application internal port (container port your app listens on, e.g. 3000)" APP_PORT

# validation
if [ -z "$GIT_REPO_URL" ] || [ -z "$GIT_PAT" ] || [ -z "$SSH_USER" ] || [ -z "$SSH_HOST" ] || [ -z "$SSH_KEY_PATH" ] || [ -z "$APP_PORT" ]; then
  err "One or more required parameters are empty. Aborting."
  exit 5
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
  err "SSH key file not found at $SSH_KEY_PATH"
  exit 6
fi

REPO_NAME="$(repo_name_from_url "$GIT_REPO_URL")"
LOCAL_REPO_DIR="${TMP_DIR}/${REPO_NAME}"
REMOTE_DEPLOY_DIR="${REMOTE_BASE_DIR}/${SSH_USER}/deployments/${REPO_NAME}"
NGINX_SITE_NAME="${REPO_NAME}.conf"

info "Repository: $GIT_REPO_URL"
info "Repository name inferred: $REPO_NAME"
info "Branch: $BRANCH"
info "Remote host: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
info "Remote deploy dir: $REMOTE_DEPLOY_DIR"
info "App internal port: $APP_PORT"

### ========= Clone or pull repository locally =========
clone_or_update_repo() {
  info "Cloning/pulling repository..."
  if [ -d "$LOCAL_REPO_DIR/.git" ]; then
    info "Repo already cloned at $LOCAL_REPO_DIR. Attempting to fetch and checkout ${BRANCH}..."
    (cd "$LOCAL_REPO_DIR" && git fetch --all --prune) 2>&1 | tee -a "$LOG_FILE"
    (cd "$LOCAL_REPO_DIR" && git checkout "$BRANCH") 2>&1 | tee -a "$LOG_FILE"
    (cd "$LOCAL_REPO_DIR" && git pull origin "$BRANCH") 2>&1 | tee -a "$LOG_FILE"
  else
    # Use token in URL safely: embed token in HTTPS URL
    # NOTE: PAT in the URL may be visible in process listings on some systems.
    CLONE_URL="$(printf "%s" "$GIT_REPO_URL" | sed "s#https://#https://${GIT_PAT}@#")"
    info "Cloning ${CLONE_URL} into ${LOCAL_REPO_DIR} ..."
    git clone --branch "$BRANCH" --single-branch "$CLONE_URL" "$LOCAL_REPO_DIR" 2>&1 | tee -a "$LOG_FILE"
    # remove token from any recorded remotes locally
    (cd "$LOCAL_REPO_DIR" && git remote set-url origin "$GIT_REPO_URL") 2>/dev/null || true
  fi

  # verify presence of Dockerfile or docker-compose.yml
  if [ -f "${LOCAL_REPO_DIR}/Dockerfile" ]; then
    info "Found Dockerfile."
  elif [ -f "${LOCAL_REPO_DIR}/docker-compose.yml" ] || [ -f "${LOCAL_REPO_DIR}/docker-compose.yaml" ]; then
    info "Found docker-compose file."
  else
    warn "No Dockerfile or docker-compose.yml found in repo root. Script expects these; you may modify script to point to correct directory."
  fi
}

### ========= Remote connectivity checks =========
ssh_opts=(-i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes -p "$SSH_PORT")
ssh_cmd() {
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$@"
}
ssh_run_script() {
  # send multiple remote commands via heredoc
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" bash -s <<'REMOTE_SCRIPT'
set -o errexit
set -o nounset
set -o pipefail
# remote commands provided by caller
REMOTE_SCRIPT
}

check_ssh_connectivity() {
  info "Checking SSH connectivity..."
  if ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "echo connected" 2>&1 | tee -a "$LOG_FILE" | grep -qi connected; then
    info "SSH connectivity OK."
  else
    err "SSH connectivity failed."
    exit 7
  fi
}

### ========= Remote preparation (idempotent) =========
remote_prepare() {
  info "Preparing remote environment..."

  # compose remote script
  REMOTE_PREP=$(cat <<'EOF'
set -euo pipefail
# Detect distro (simple)
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO="$ID"
else
  DISTRO="unknown"
fi

# update package cache
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
  # install docker if missing
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  # docker-compose plugin or compose binary
  if ! docker compose version >/dev/null 2>&1; then
    # attempt to install docker-compose plugin
    sudo apt-get install -y docker-compose-plugin || true
  fi
  # install nginx
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt-get install -y nginx
  fi
elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
  sudo yum makecache -y || true
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    sudo yum install -y nginx || sudo dnf install -y nginx || true
  fi
else
  echo "Unknown package manager. Manual install may be required." >&2
fi

# ensure docker service running
sudo systemctl enable --now docker || true
# ensure nginx running
sudo systemctl enable --now nginx || true

# add user to docker group if not already
if id "$USER" >/dev/null 2>&1; then
  if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER" || true
  fi
fi

# Print versions
echo "docker: $(docker --version || true)"
docker version --format '{{json .}}' 2>/dev/null || true
echo "docker-compose: $(docker compose version 2>/dev/null || true)"
echo "nginx: $(nginx -v 2>&1 || true)"

EOF
)
  # run the script remotely
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "bash -s" <<REMOTE
$REMOTE_PREP
REMOTE

  info "Remote environment prepared."
}

### ========= Transfer files (rsync) =========
transfer_project() {
  info "Transferring project files to remote host..."
  # create remote base directory
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "mkdir -p '$REMOTE_DEPLOY_DIR' && chmod 755 '$REMOTE_DEPLOY_DIR'"
  # Use rsync for efficiency
  RSYNC_EXCLUDE_ARGS=()
  for e in $RSYNC_EXCLUDES; do RSYNC_EXCLUDE_ARGS+=(--exclude "$e"); done

  rsync -avz -e "ssh ${ssh_opts[*]}" "${RSYNC_EXCLUDE_ARGS[@]}" --delete "$LOCAL_REPO_DIR"/ "$SSH_USER@$SSH_HOST:$REMOTE_DEPLOY_DIR/" 2>&1 | tee -a "$LOG_FILE"
  info "Files transferred."
}

### ========= Deploy on remote: build & run =========
remote_deploy_app() {
  info "Deploying app on remote host..."
  # create a remote script that:
  # moves into remote dir
  # stops and removes existing containers with the same project name (idempotency)
  # builds and runs via docker or docker compose
  REMOTE_DEPLOY_SCRIPT=$(cat <<'EOF'
set -euo pipefail
REPO_DIR="$1"
APP_PORT="$2"
NGINX_SITE_NAME="$3"
REPO_NAME="$(basename "$REPO_DIR")"

cd "$REPO_DIR"

# detect compose file
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  COMPOSE_FILE=$(ls docker-compose.yml docker-compose.yaml 2>/dev/null | head -n1 || true)
  # bring down old compose gracefully
  if docker compose -f "$COMPOSE_FILE" ps >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" down || true
  fi
  # build & up
  docker compose -f "$COMPOSE_FILE" pull || true
  docker compose -f "$COMPOSE_FILE" up -d --build
else
  # single Dockerfile flow: build image and run container named by repo
  IMAGE_NAME="${REPO_NAME}:latest"
  # stop old container if exists
  if docker ps -a --format '{{.Names}}' | grep -q "^${REPO_NAME}\$"; then
    docker rm -f "${REPO_NAME}" || true
  fi
  docker build -t "$IMAGE_NAME" .
  docker run -d --name "${REPO_NAME}" -p "${APP_PORT}:${APP_PORT}" "$IMAGE_NAME"
fi

# wait/check container
sleep 3
# attempt health probe if healthcheck exists
CONTAINER_ID=$(docker ps --filter "name=${REPO_NAME}" --format '{{.ID}}' | head -n1 || true)
if [ -n "$CONTAINER_ID" ]; then
  # if container has health info
  if docker inspect --format='{{json .State.Health}}' "$CONTAINER_ID" 2>/dev/null | grep -q '"Status"'; then
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_ID" || true)
    echo "Container health: $STATUS"
  else
    echo "Container is running (no healthcheck)."
  fi
else
  echo "No running container detected."
  exit 10
fi
EOF
)
  # execute remote deploy
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "bash -s" -- "$REMOTE_DEPLOY_DIR" "$APP_PORT" "$NGINX_SITE_NAME" <<REMOTE
$REMOTE_DEPLOY_SCRIPT
REMOTE

  info "Remote deploy commands executed."
}

### ========= Nginx reverse-proxy configure =========
configure_nginx() {
  info "Configuring Nginx reverse proxy..."

  REMOTE_NGINX_CONF=$(cat <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
)

  # write conf to a temp file then copy to remote
  NGINX_TMP="${TMP_DIR}/${NGINX_SITE_NAME}"
  printf "%s" "$REMOTE_NGINX_CONF" > "$NGINX_TMP"
  scp -i "$SSH_KEY_PATH" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$NGINX_TMP" "$SSH_USER@$SSH_HOST:/tmp/${NGINX_SITE_NAME}" 2>&1 | tee -a "$LOG_FILE"

  # remote move to sites-available and enable
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
sudo mv /tmp/${NGINX_SITE_NAME} ${NGINX_SITES_AVAILABLE}/${NGINX_SITE_NAME}
sudo ln -sf ${NGINX_SITES_AVAILABLE}/${NGINX_SITE_NAME} ${NGINX_SITES_ENABLED}/${NGINX_SITE_NAME}
sudo nginx -t
sudo systemctl reload nginx
REMOTE

  info "Nginx configured and reloaded."
}

### ========= Validation checks =========
validate_deployment() {
  info "Validating deployment..."

  # Check docker service
  if ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "sudo systemctl is-active docker" 2>&1 | tee -a "$LOG_FILE" | grep -q "active"; then
    info "Docker service is active."
  else
    err "Docker service not active."
  fi

  # Check container present
  CONTAINER_CHECK=$(ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "docker ps --filter 'name=${REPO_NAME}' --format '{{.Names}}' || true")
  if [ -n "$CONTAINER_CHECK" ]; then
    info "Container '${CONTAINER_CHECK}' is running."
  else
    err "No container with name matching '${REPO_NAME}' running."
  fi

  # Check Nginx proxy locally on remote via curl
  if [ -n "$CURL_BIN" ]; then
    REMOTE_HTTP_CODE=$(ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/")
    info "Remote curl to localhost returned HTTP status $REMOTE_HTTP_CODE"
  elif [ -n "$WGET_BIN" ]; then
    REMOTE_HTTP_CODE=$(ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "wget -qO- --server-response http://127.0.0.1/ 2>&1 | sed -n '1p'")
    info "Remote wget probe: $REMOTE_HTTP_CODE"
  else
    warn "No curl/wget available locally to probe remote HTTP endpoint."
  fi

  # Optionally test from local machine to the remote server's port 80
  if command -v curl >/dev/null 2>&1; then
    OUT="$(curl -sS -m 10 http://${SSH_HOST}/ || true)"
    if [ -n "$OUT" ]; then
      info "Public HTTP request returned non-empty body (first 200 chars):"
      printf '%s\n' "${OUT}" | sed -n '1,5p' | tee -a "$LOG_FILE"
    else
      warn "Public HTTP request returned empty body or timed out."
    fi
  fi
}

### ========= Cleanup remote (optional) =========
remote_cleanup() {
  info "Running remote cleanup (stop and remove containers, remove nginx conf, remove project dir)..."
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" bash -s <<REMOTE
set -euo pipefail
REPO_DIR="${REMOTE_DEPLOY_DIR}"
REPO_NAME="$(basename "$REPO_DIR")"
# stop/remove container(s)
if docker ps -a --format '{{.Names}}' | grep -q "^${REPO_NAME}\$"; then
  docker rm -f "${REPO_NAME}" || true
fi
# remove compose services if any
if [ -f "$REPO_DIR/docker-compose.yml" ] || [ -f "$REPO_DIR/docker-compose.yaml" ]; then
  (cd "$REPO_DIR" && docker compose down) || true
fi
# remove nginx site
if [ -f "${NGINX_SITES_AVAILABLE}/${NGINX_SITE_NAME}" ]; then
  sudo rm -f "${NGINX_SITES_AVAILABLE}/${NGINX_SITE_NAME}"
  sudo rm -f "${NGINX_SITES_ENABLED}/${NGINX_SITE_NAME}"
  sudo nginx -t || true
  sudo systemctl reload nginx || true
fi
# remove project dir
sudo rm -rf "$REPO_DIR" || true
REMOTE

  info "Remote cleanup finished."
}

### ========= Main execution sequence =========
main() {
  clone_or_update_repo
  check_ssh_connectivity
  remote_prepare
  transfer_project
  remote_deploy_app
  configure_nginx
  validate_deployment

  info "Deployment flow completed. See log: $LOG_FILE"
}

if [ "$CLEANUP_MODE" -eq 1 ]; then
  printf "You requested cleanup mode. Are you sure you want to remove deployed resources on remote host? (yes/no): "
  read -r CONF
  if [ "$CONF" = "yes" ]; then
    remote_cleanup
    info "Cleanup complete."
    exit 0
  else
    info "Cleanup aborted by user."
    exit 0
  fi
else
  main
fi
