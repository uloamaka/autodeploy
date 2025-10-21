#!/bin/bash
set -Eeo pipefail  # Exit on errors, propagate failures in pipes

# =============================
# 🧾 Logging & Error Handling Setup
# =============================

# Timestamped log file
LOG_FILE="deploy_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Capture stdout & stderr into log

# Exit codes
EXIT_SUCCESS=0
EXIT_PARAM_ERROR=10
EXIT_SSH_FAILURE=20
EXIT_INSTALL_FAILURE=30
EXIT_DEPLOY_FAILURE=40
EXIT_NGINX_FAILURE=50
EXIT_CLEANUP_DONE=100

# Logging functions
log() {
    echo -e "[\$(date '+%Y-%m-%d %H:%M:%S')] [INFO] \$*"
}

error() {
    echo -e "[\$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] \$*" >&2
}

# Exit with message and optional code
error_exit() {
    local msg="\$1"
    local code="\${2:-1}"
    error "\$msg"
    echo "[EXIT CODE] \$code"
    exit $code
}

# Trap handler for unexpected errors
on_error() {
    local exit_code=\$?
    error "❌ Unexpected error occurred (exit code \$exit_code)"
    echo "Please check the log file: \$LOG_FILE"
    exit "\$exit_code"
}
trap on_error ERR

DEFAULT_BRANCH="main"
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
CLEANUP_MODE=${CLEANUP_MODE:-false}


# =============================
# 🧽 Cleanup Handler
# =============================
cleanup() {
    log "Running cleanup on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash -s <<'EOF'
        set -e
        echo "[REMOTE] Stopping and removing containers..."
        docker compose down || true
        docker rm -f $(docker ps -aq) || true
        echo "[REMOTE] Removing dangling images..."
        docker image prune -af || true
        echo "[REMOTE] Removing old Nginx config..."
        sudo rm -f /etc/nginx/sites-available/${APP_NAME}.conf || true
        sudo rm -f /etc/nginx/sites-enabled/${APP_NAME}.conf || true
        sudo nginx -t && sudo systemctl reload nginx
EOF
    log "Cleanup completed successfully."
    exit $EXIT_CLEANUP_DONE
}

# Detect --cleanup flag
if [[ "\$1" == "--cleanup" ]]; then
    cleanup
fi

log "Proceeding with standard deployment..."

############################################
# Parse flags
############################################
for arg in "$@"; do
  case $arg in
    --cleanup)
      CLEANUP_MODE=true
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      ;;
    *)
      ;;
  esac
done

############################################
# Collect parameters
############################################
collect_inputs() {
  if [ "$NON_INTERACTIVE" = true ]; then
    # Read from environment variables (for CI/CD)
    GIT_URL="${GIT_URL:-}"
    GIT_PAT="${GIT_PAT:-}"
    GIT_BRANCH="${GIT_BRANCH:-$DEFAULT_BRANCH}"
    SSH_USER="${SSH_USER:-}"
    SERVER_IP="${SERVER_IP:-}"
    SSH_KEY_PATH="${SSH_KEY_PATH:-}"
    APP_PORT="${APP_PORT:-}"
  else
    # Prompt user for inputs
    read -rp "Enter Git repository URL: " GIT_URL
    read -rsp "Enter Personal Access Token (PAT): " GIT_PAT; echo
    read -rp "Enter branch name [default: ${DEFAULT_BRANCH}]: " GIT_BRANCH
    GIT_BRANCH="${GIT_BRANCH:-$DEFAULT_BRANCH}"
    read -rp "Enter remote SSH username: " SSH_USER
    read -rp "Enter remote server IP address: " SERVER_IP
    read -rp "Enter SSH private key path: " SSH_KEY_PATH
    read -rp "Enter application internal port (container port): " APP_PORT
  fi
}

############################################
# Validate inputs
############################################
validate_inputs() {
  [[ -z "$GIT_URL" ]] && error_exit "Git repository URL is required."
  [[ "$GIT_URL" =~ ^https:\/\/|^git@ ]] || error_exit "Invalid Git URL format."

  [[ -z "$GIT_PAT" ]] && error_exit "Personal Access Token is required."

  [[ -z "$SSH_USER" ]] && error_exit "SSH username is required."
  [[ -z "$SERVER_IP" ]] && error_exit "Server IP address is required."

  [[ -f "$SSH_KEY_PATH" ]] || error_exit "SSH key path not found: $SSH_KEY_PATH"

  if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || ((APP_PORT < 1 || APP_PORT > 65535)); then
    error_exit "Invalid application port: $APP_PORT. Must be between 1–65535."
  fi

  log "✅ Input validation successful."
}

############################################
# Clone or update the Git repository
############################################
clone_or_update_repo() {
  local REPO_NAME
  REPO_NAME=$(basename "$GIT_URL" .git)

  log "📦 Preparing repository: $REPO_NAME"

  # Clean PAT for safety in logs (mask actual token)
  local SAFE_GIT_URL="${GIT_URL/https:\/\/*@/https:\/\/[MASKED]@}"

  # If repo directory exists -> update instead of clone
  if [ -d "$REPO_NAME/.git" ]; then
    log "🔄 Repository already exists. Pulling latest changes..."
    pushd "$REPO_NAME" > /dev/null || error_exit "Cannot access $REPO_NAME directory."

    git fetch origin "$GIT_BRANCH" &>> "$LOG_FILE" || error_exit "Failed to fetch branch: $GIT_BRANCH"
    git checkout "$GIT_BRANCH" &>> "$LOG_FILE" || error_exit "Failed to checkout branch: $GIT_BRANCH"
    git pull origin "$GIT_BRANCH" &>> "$LOG_FILE" || error_exit "Failed to pull latest changes."

    popd > /dev/null || true
    log "✅ Repository updated successfully."
  else
    log "📥 Cloning repository..."

    # Embed PAT securely into the clone URL
    local AUTH_URL
    if [[ "$GIT_URL" =~ ^https:// ]]; then
      # e.g., https://github.com/user/repo.git -> https://<PAT>@github.com/user/repo.git
      AUTH_URL="${GIT_URL/https:\/\//https:\/\/${GIT_PAT}@}"
    else
      error_exit "Only HTTPS clone URLs are supported for PAT authentication (not SSH)."
    fi

    git clone --branch "$GIT_BRANCH" "$AUTH_URL" "$REPO_NAME" &>> "$LOG_FILE" || error_exit "Git clone failed."
    log "✅ Repository cloned successfully."
    export REPO_DIR=$(basename "$GIT_URL" .git)

    # Mask PAT in logs (remove after use)
    unset AUTH_URL
  fi

  # Move into the repo directory
  cd "$REPO_NAME" || error_exit "Cannot enter repository directory."
  log "📂 Changed directory to $(pwd)"

    # Verify presence of Docker configuration
  if [[ -f "docker-compose.yml" ]]; then
    log "🧾 Found docker-compose.yml file."

    # Optionally detect Docker Compose version 2 syntax
    if grep -q "version: *['\"]*2" docker-compose.yml; then
      log "ℹ️ Detected Docker Compose v2 syntax."
    elif grep -q "version: *['\"]*3" docker-compose.yml; then
      log "ℹ️ Detected Docker Compose v3 syntax."
    else
      log "⚠️ No version key found in docker-compose.yml (might be Compose v2+ plugin style)."
    fi

  elif [[ -f "Dockerfile" ]]; then
    log "🧾 Found Dockerfile."
  else
    error_exit "Neither Dockerfile nor docker-compose.yml found in repository."
  fi


  log "✅ Repository preparation complete."
}

############################################
# SSH Connectivity checks
############################################
check_ssh_connectivity() {
  log "🔐 Checking SSH connectivity to remote server: ${SSH_USER}@${SERVER_IP}"

  # Optional: test ping first (if available)
  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 2 "$SERVER_IP" &>/dev/null; then
      log "✅ Ping successful to $SERVER_IP"
    else
      log "⚠️ Ping to $SERVER_IP failed (host may block ICMP). Continuing to SSH test..."
    fi
  else
    log "ℹ️ Ping command not available, skipping ICMP test."
  fi

  # SSH dry-run (BatchMode disables password prompt)
  if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${SERVER_IP}" "echo ok" &>/dev/null; then
    log "✅ SSH connection successful to ${SSH_USER}@${SERVER_IP}"
  else
    error_exit "SSH connection failed. Check credentials, key permissions, or server availability."
  fi

  log "🔗 Remote server connectivity verified."
}

############################################
# Prepare the remote environment
############################################
prepare_remote_environment() {
  log "🛠️ Preparing remote environment on ${SSH_USER}@${SERVER_IP}..."

  ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${SERVER_IP}" bash -s <<'REMOTE_CMDS'
set -euo pipefail

echo "Updating system packages..."
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null
elif command -v yum >/dev/null 2>&1; then
  sudo yum makecache -y >/dev/null
fi

echo "Checking and installing Docker if needed..."
if ! command -v docker >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y ca-certificates curl gnupg >/dev/null
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg >/dev/null 2>&1
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y >/dev/null
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y yum-utils >/dev/null
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
    sudo yum install -y docker-ce docker-ce-cli containerd.io >/dev/null
  fi
  sudo systemctl enable docker >/dev/null
  sudo systemctl start docker >/dev/null
  echo "✅ Docker installed successfully."
else
  echo "✅ Docker already installed: $(docker --version)"
fi

echo "Checking Docker Compose..."
if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin >/dev/null || sudo apt-get install -y docker-compose >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y docker-compose-plugin >/dev/null || sudo yum install -y docker-compose >/dev/null
  fi
  echo "✅ Docker Compose installed."
else
  echo "✅ Docker Compose already installed."
fi

echo "Checking Nginx..."
if ! command -v nginx >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y nginx >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y nginx >/dev/null
  fi
  sudo systemctl enable nginx >/dev/null
  sudo systemctl start nginx >/dev/null
  echo "✅ Nginx installed successfully."
else
  echo "✅ Nginx already installed: $(nginx -v 2>&1)"
fi

# Add user to docker group if not root
if [ "$EUID" -ne 0 ]; then
  if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER"
    echo "👤 Added user $USER to docker group. (Logout required for effect)"
  fi
fi

echo "🧾 Version check:"
docker --version
if command -v docker-compose >/dev/null 2>&1; then docker-compose --version; else docker compose version; fi
nginx -v

REMOTE_CMDS

  log "✅ Remote environment prepared successfully."
}

# =============================
# 6️⃣ Transfer Project & Deploy Containers
# =============================
transfer_and_deploy() {
log "Transferring project files to remote server..."

REMOTE_APP_PATH="/home/$SSH_USER/$(basename "$REPO_DIR")"

# Sync project files to remote server
rsync -az --delete -e "ssh -i $SSH_KEY_PATH" "$REPO_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_APP_PATH"
if [[ $? -ne 0 ]]; then
    error_exit "File transfer failed via rsync."
fi
log "Project files transferred successfully."

# Determine app name and host port (use 80 if not provided)
APP_NAME=$(basename "$REPO_DIR")
HOST_PORT=${HOST_PORT:-80}

log "Deploying Dockerized application on remote server..."

# Build and deploy remotely
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash -s <<EOF
set -e
cd "$REMOTE_APP_PATH"

if [[ -f "docker-compose.yml" ]]; then
    echo "[REMOTE] docker-compose.yml found, deploying with Docker Compose..."
    docker compose pull || true
    docker compose up -d --remove-orphans --build
else
    echo "[REMOTE] No docker-compose.yml found. Using Dockerfile..."
    IMAGE_NAME="${APP_NAME,,}:latest"
    docker build -t \$IMAGE_NAME .
    docker rm -f "\$IMAGE_NAME" || true
    docker run -d --name "\$IMAGE_NAME" -p $HOST_PORT:$APP_PORT --restart unless-stopped "\$IMAGE_NAME"
fi

# Validate container status
echo "[REMOTE] Checking container status..."
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$APP_NAME" || {
    echo "[REMOTE] Error: Container not running as expected."
    exit 1
}

# Optional: Brief log stream for health check
echo "[REMOTE] Displaying recent logs..."
docker logs --tail 10 "\$IMAGE_NAME" || docker compose logs --tail 10

EOF

if [[ $? -eq 0 ]]; then
    log "Application deployed successfully on remote server."
else
    error_exit "Deployment failed. Check logs above."
fi
}

# =============================
# 7️⃣ Configure Nginx Reverse Proxy
# =============================
configure_nginx() {
log "Configuring Nginx reverse proxy on remote server..."

APP_NAME=$(basename "$REPO_DIR")
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}.conf"

# Send remote setup commands
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash -s <<EOF
set -e

APP_PORT=$APP_PORT
HOST_PORT=${HOST_PORT:-80}
APP_NAME="$APP_NAME"
NGINX_CONF="$NGINX_CONF"
NGINX_ENABLED="$NGINX_ENABLED"

echo "[REMOTE] Setting up Nginx reverse proxy for \$APP_NAME..."

# Ensure Nginx is installed and active
if ! command -v nginx >/dev/null 2>&1; then
    echo "[REMOTE] Installing Nginx..."
    sudo apt-get update -y && sudo apt-get install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
fi

# Create Nginx config (idempotent)
if [[ ! -f "\$NGINX_CONF" ]]; then
    echo "[REMOTE] Creating Nginx config at \$NGINX_CONF..."

    sudo tee "\$NGINX_CONF" > /dev/null <<NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$HOST_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SSL placeholder - to enable, replace with Certbot or self-signed cert paths
    # listen 443 ssl;
    # ssl_certificate /etc/ssl/certs/\${APP_NAME}.crt;
    # ssl_certificate_key /etc/ssl/private/\${APP_NAME}.key;
}
NGINXCONF

    echo "[REMOTE] Nginx config created."
else
    echo "[REMOTE] Nginx config already exists. Skipping creation."
fi

# Enable config (symlink) if not already linked
if [[ ! -L "\$NGINX_ENABLED" ]]; then
    sudo ln -s "\$NGINX_CONF" "\$NGINX_ENABLED"
fi

# Test and reload Nginx
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx --no-pager | head -n 5

echo "[REMOTE] Nginx reverse proxy configured successfully."
EOF

if [[ $? -eq 0 ]]; then
    log "Nginx reverse proxy configured successfully."
else
    error_exit "Nginx configuration failed. Check logs above."
fi
}

# =============================
# 8️⃣ Validate Deployment
# =============================
validate_deployment() {
log "Validating deployment on remote server..."

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash -s <<EOF
set -e

APP_NAME="$APP_NAME"
APP_PORT=$APP_PORT
HOST_PORT=${HOST_PORT:-80}

echo "[REMOTE] Checking Docker service status..."
if ! systemctl is-active --quiet docker; then
    echo "[REMOTE] ❌ Docker service is not active!"
    exit 1
else
    echo "[REMOTE] ✅ Docker service is active."
fi

echo "[REMOTE] Checking running containers..."
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "\$APP_NAME" || {
    echo "[REMOTE] ❌ Container not running."
    exit 1
}
echo "[REMOTE] ✅ Container is running."

# Check health status if defined
CONTAINER_ID=\$(docker ps -qf "name=\$APP_NAME")
if [[ -n "\$CONTAINER_ID" ]]; then
    HEALTH=\$(docker inspect --format='{{json .State.Health.Status}}' "\$CONTAINER_ID" 2>/dev/null || echo "none")
    echo "[REMOTE] Health status: \$HEALTH"
fi

# Test internal HTTP access (localhost)
echo "[REMOTE] Testing HTTP endpoint locally..."
HTTP_CODE=\$(curl -s -o /tmp/curl_out.txt -w "%{http_code}" --max-time 10 http://localhost:\$HOST_PORT/ || echo "000")
echo "[REMOTE] Local HTTP response code: \$HTTP_CODE"
if [[ "\$HTTP_CODE" != "200" && "\$HTTP_CODE" != "301" && "\$HTTP_CODE" != "302" ]]; then
    echo "[REMOTE] ❌ Unexpected response from app: \$(head -n 5 /tmp/curl_out.txt)"
    exit 1
else
    echo "[REMOTE] ✅ App responded successfully on localhost:\$HOST_PORT"
fi
EOF

# Local validation (from your machine)
log "Performing external access test from local system..."
HTTP_CODE_LOCAL=$(curl -s -o /tmp/deploy_local_test.txt -w "%{http_code}" --max-time 10 "http://$SERVER_IP/" || echo "000")

if [[ "$HTTP_CODE_LOCAL" == "200" || "$HTTP_CODE_LOCAL" == "301" || "$HTTP_CODE_LOCAL" == "302" ]]; then
    log "✅ Application is reachable externally (HTTP $HTTP_CODE_LOCAL)"
    head -n 5 /tmp/deploy_local_test.txt | log
else
    error_exit "❌ Application is not reachable from local system (HTTP $HTTP_CODE_LOCAL)"
fi
}

############################################
# Main logic
############################################
main() {
  log "🚀 Starting deployment script..."
  
  if [ "$CLEANUP_MODE" = true ]; then
    log "⚙️ Cleanup mode activated (will remove resources later)."
  fi

  collect_inputs
  validate_inputs
  clone_or_update_repo
  check_ssh_connectivity
  prepare_remote_environment
  transfer_and_deploy
  configure_nginx
  validate_deployment

  log "✅ Deployment completed successfully!"
}

main "$@"
