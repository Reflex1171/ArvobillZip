#!/usr/bin/env bash

set -euo pipefail

ZIP_URL="https://github.com/Reflex1171/ArvobillZip/raw/refs/heads/main/ArvoBill-main.zip"
TMP_ZIP="/tmp/arvobill.zip"
TMP_DIR="$(mktemp -d /tmp/arvobill.XXXXXX)"
DEFAULT_INSTALL_DIR="/var/www/arvobill"
SSL_CONFIGURED="no"
PANEL_DOMAIN=""
COMPOSER_ALLOW_SUPERUSER=1
COMPOSER_CAFILE_PATH="/etc/ssl/certs/ca-certificates.crt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ensure_composer_tls() {
    if [[ ! -f "${COMPOSER_CAFILE_PATH}" ]]; then
        if [[ -f "/etc/ssl/cert.pem" ]]; then
            COMPOSER_CAFILE_PATH="/etc/ssl/cert.pem"
        fi
    fi

    if [[ ! -f "${COMPOSER_CAFILE_PATH}" ]]; then
        info "Installing CA certificates..."
        apt-get update -y
        apt-get install -y ca-certificates openssl
    fi

    if [[ ! -f "${COMPOSER_CAFILE_PATH}" ]]; then
        info "Downloading CA bundle..."
        curl -fsSL https://curl.se/ca/cacert.pem -o /usr/local/share/ca-certificates/arvobill-extra.crt || true
        update-ca-certificates >/dev/null 2>&1 || true
    fi

    update-ca-certificates >/dev/null 2>&1 || true

    if [[ ! -f "${COMPOSER_CAFILE_PATH}" ]]; then
        if [[ -f "/etc/ssl/cert.pem" ]]; then
            COMPOSER_CAFILE_PATH="/etc/ssl/cert.pem"
        fi
    fi

    if [[ ! -f "${COMPOSER_CAFILE_PATH}" ]]; then
        error "CA bundle not found at ${COMPOSER_CAFILE_PATH}."
        exit 1
    fi

    if [[ ! -r "${COMPOSER_CAFILE_PATH}" ]]; then
        error "CA bundle is not readable at ${COMPOSER_CAFILE_PATH}."
        exit 1
    fi

    export COMPOSER_ALLOW_SUPERUSER=1
    export COMPOSER_CAFILE="${COMPOSER_CAFILE_PATH}"
    export SSL_CERT_FILE="${COMPOSER_CAFILE_PATH}"
    export CURL_CA_BUNDLE="${COMPOSER_CAFILE_PATH}"

    # Ensure Composer respects the CA bundle even if a bad global config exists.
    if command -v composer >/dev/null 2>&1; then
        composer config --global cafile "${COMPOSER_CAFILE_PATH}" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    rm -f "$TMP_ZIP" || true
    rm -rf "$TMP_DIR" || true
}

trap cleanup EXIT

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "This installer must be run as root (use sudo)."
        exit 1
    fi
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect operating system. /etc/os-release not found."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu 22.04+ is required."
        exit 1
    fi

    local version="${VERSION_ID:-0}"
    local major="${version%%.*}"
    if [[ "$major" -lt 22 ]]; then
        error "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Ubuntu 22.04+ is required."
        exit 1
    fi

    success "OS check passed: ${PRETTY_NAME}"
}

prompt_install_dir() {
    read -r -p "Where should ArvoBill be installed? [default: ${DEFAULT_INSTALL_DIR}]: " install_dir
    INSTALL_DIR="${install_dir:-$DEFAULT_INSTALL_DIR}"

    mkdir -p "$INSTALL_DIR"

    if [[ ! -w "$INSTALL_DIR" ]]; then
        error "Install directory is not writable: $INSTALL_DIR"
        exit 1
    fi

    if [[ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
        warn "Install directory is not empty: $INSTALL_DIR"
        read -r -p "Continue and merge files into this directory? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            error "Installation aborted by user."
            exit 1
        fi
    fi

    success "Installation directory ready: $INSTALL_DIR"
}

download_and_extract() {
    info "Downloading ArvoBill ZIP archive..."
    curl -fsSL "$ZIP_URL" -o "$TMP_ZIP"
    success "Download complete."

    info "Extracting archive..."
    unzip -q "$TMP_ZIP" -d "$TMP_DIR"

    local source_dir
    if [[ -d "$TMP_DIR/ArvoBill-main" ]]; then
        source_dir="$TMP_DIR/ArvoBill-main"
    else
        source_dir="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    fi

    if [[ -z "${source_dir:-}" || ! -d "$source_dir" ]]; then
        error "Could not find extracted project directory in ZIP archive."
        exit 1
    fi

    shopt -s dotglob nullglob
    cp -a "$source_dir"/* "$INSTALL_DIR"/
    shopt -u dotglob nullglob

    success "Project files extracted to: $INSTALL_DIR"
}

package_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

package_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

cleanup_nodesource_sources() {
    # Remove stale NodeSource entries that can break apt update.
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i '/deb\.nodesource\.com/d' /etc/apt/sources.list || true
    fi

    if [[ -d /etc/apt/sources.list.d ]]; then
        local list_file
        for list_file in /etc/apt/sources.list.d/*.list; do
            [[ -e "$list_file" ]] || continue
            sed -i '/deb\.nodesource\.com/d' "$list_file" || true
        done

        rm -f /etc/apt/sources.list.d/nodesource.list
    fi
}

ensure_php_repo() {
    if apt-cache show php8.2-cli >/dev/null 2>&1; then
        return
    fi

    warn "php8.2 packages not available in current APT sources. Adding ondrej/php repository..."
    apt-get update -y
    apt-get install -y software-properties-common ca-certificates lsb-release apt-transport-https
    add-apt-repository -y ppa:ondrej/php
}

ensure_nodejs_runtime() {
    local nvm_dir="/root/.nvm"

    load_nvm() {
        # shellcheck disable=SC1090
        [[ -s "${nvm_dir}/nvm.sh" ]] && source "${nvm_dir}/nvm.sh"
    }

    expose_nvm_binaries() {
        local node_bin
        node_bin="$(command -v node || true)"
        if [[ -n "$node_bin" ]]; then
            ln -sf "$node_bin" /usr/local/bin/node || true
            local npm_bin npx_bin
            npm_bin="$(command -v npm || true)"
            npx_bin="$(command -v npx || true)"
            [[ -n "$npm_bin" ]] && ln -sf "$npm_bin" /usr/local/bin/npm || true
            [[ -n "$npx_bin" ]] && ln -sf "$npx_bin" /usr/local/bin/npx || true
        fi
    }

    local node_major="0"
    if command -v node >/dev/null 2>&1; then
        node_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)"
    fi

    if [[ "$node_major" -ge 18 ]]; then
        success "Node.js runtime is compatible (v$(node -v))."
        return
    fi

    warn "Node.js 18+ is required. Installing Node.js 20 via nvm..."
    apt-get update -y
    apt-get install -y ca-certificates curl

    if [[ ! -s "${nvm_dir}/nvm.sh" ]]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi

    load_nvm
    if ! command -v nvm >/dev/null 2>&1; then
        error "nvm installation failed."
        exit 1
    fi

    nvm install 20
    nvm alias default 20
    nvm use 20 >/dev/null

    expose_nvm_binaries
    node_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)"
    if [[ "$node_major" -lt 18 ]]; then
        error "Node.js upgrade failed. Detected version: $(node -v 2>/dev/null || echo unknown)"
        exit 1
    fi

    success "Node.js installed: $(node -v), npm: $(npm -v)"
}

install_dependencies() {
    info "Checking system dependencies..."

    # Remove stale/broken NodeSource entries from previous failed runs.
    cleanup_nodesource_sources

    ensure_php_repo

    local packages=(
        nginx
        unzip
        curl
        composer
        mariadb-server
        php8.2
        php8.2-cli
        php8.2-fpm
        php8.2-curl
        php8.2-mbstring
        php8.2-xml
        php8.2-bcmath
        php8.2-zip
        php8.2-mysql
        php8.2-intl
    )

    # MySQL client package names vary by distro/repo; prefer MariaDB client.
    if package_available "mariadb-client"; then
        packages+=("mariadb-client")
    elif package_available "default-mysql-client"; then
        packages+=("default-mysql-client")
    elif package_available "mysql-client"; then
        packages+=("mysql-client")
    else
        warn "No MySQL/MariaDB client package found in APT. Continuing with server package only."
    fi

    local missing=()
    local pkg
    for pkg in "${packages[@]}"; do
        if ! package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        success "All required packages are already installed."
        ensure_nodejs_runtime
        return
    fi

    info "Installing missing packages: ${missing[*]}"
    apt-get update -y
    apt-get install -y "${missing[@]}"
    success "System dependencies installed."

    ensure_nodejs_runtime
}

start_database_service() {
    local service_name="$1"

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q "^${service_name}\.service"; then
            systemctl enable "$service_name" >/dev/null 2>&1 || true
            systemctl restart "$service_name" >/dev/null 2>&1 || true
            if systemctl is-active --quiet "$service_name"; then
                return 0
            fi
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        if service "$service_name" start >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

ensure_database_service() {
    local candidates=(mariadb mysql mysqld)
    local candidate

    for candidate in "${candidates[@]}"; do
        info "Checking database service: ${candidate}"
        if start_database_service "$candidate"; then
            success "Database service is running via '${candidate}'."
            return
        fi
    done

    error "No MariaDB/MySQL service could be started. Check package install logs and run: systemctl status mariadb"
    exit 1
}

setup_nginx_and_ssl() {
    read -r -p "Configure Nginx and Let's Encrypt SSL now? [Y/n]: " configure_ssl
    if [[ "$configure_ssl" =~ ^[Nn]$ ]]; then
        warn "Skipping automatic Nginx/SSL setup."
        return
    fi

    info "Nginx + SSL configuration"
    read -r -p "Panel domain (e.g. panel.example.com): " domain
    read -r -p "Let's Encrypt email: " ssl_email

    if [[ -z "${domain}" || -z "${ssl_email}" ]]; then
        error "Domain and Let's Encrypt email are required for SSL setup."
        exit 1
    fi

    PANEL_DOMAIN="$domain"
    local nginx_conf="/etc/nginx/sites-available/arvobill.conf"
    local nginx_enabled="/etc/nginx/sites-enabled/arvobill.conf"

    if [[ -f "$nginx_conf" ]]; then
        warn "Existing Nginx config found: $nginx_conf"
        read -r -p "Overwrite existing ArvoBill Nginx config? [y/N]: " overwrite_conf
        if [[ ! "$overwrite_conf" =~ ^[Yy]$ ]]; then
            error "SSL setup aborted to avoid overwriting existing Nginx config."
            exit 1
        fi
    fi

    cat >"$nginx_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    root ${INSTALL_DIR}/public;
    index index.php index.html;

    access_log /var/log/nginx/arvobill_access.log;
    error_log /var/log/nginx/arvobill_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi

    ln -sf "$nginx_conf" "$nginx_enabled"
    nginx -t
    systemctl reload nginx
    success "Nginx virtual host configured for ${domain}."

    info "Installing Certbot packages if needed..."
    apt-get update -y
    apt-get install -y certbot python3-certbot-nginx

    info "Requesting Let's Encrypt certificate..."
    certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$ssl_email" --redirect
    success "SSL certificate installed and HTTPS redirect enabled."

    update_env_value "APP_URL" "https://${domain}"
    SSL_CONFIGURED="yes"
}

setup_application_dependencies() {
    if [[ -s /root/.nvm/nvm.sh ]]; then
        # shellcheck disable=SC1091
        source /root/.nvm/nvm.sh
        nvm use 20 >/dev/null 2>&1 || true
    fi

    info "Installing PHP dependencies..."
    ensure_composer_tls
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_CAFILE="${COMPOSER_CAFILE_PATH}" \
        SSL_CERT_FILE="${COMPOSER_CAFILE_PATH}" CURL_CA_BUNDLE="${COMPOSER_CAFILE_PATH}" \
        composer install --no-dev --optimize-autoloader --no-interaction --working-dir="$INSTALL_DIR"
    success "Composer dependencies installed."

    info "Installing Node dependencies..."
    npm install --prefix "$INSTALL_DIR"
    success "Node dependencies installed."

    info "Building frontend assets..."
    npm run build --prefix "$INSTALL_DIR"
    success "Frontend build complete."
}

setup_laravel() {
    info "Configuring Laravel application..."

    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
        success ".env created from .env.example"
    else
        warn ".env already exists. Keeping existing file."
    fi

    php "$INSTALL_DIR/artisan" key:generate --force
    success "Application key generated."

    local web_user="www-data"
    local web_group="www-data"

    if id -u "$web_user" >/dev/null 2>&1; then
        chown -R "$web_user:$web_group" "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache"
        find "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" -type d -exec chmod 775 {} \;
        find "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" -type f -exec chmod 664 {} \;
        success "Permissions and ownership updated for storage and bootstrap/cache."
    else
        warn "User '$web_user' not found. Applying permission-only fallback."
        chmod -R ug+rwx "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache"
        success "Permissions updated for storage and bootstrap/cache."
    fi
}

configure_cron() {
    read -r -p "Install Laravel scheduler cron job? [Y/n]: " install_cron
    if [[ "$install_cron" =~ ^[Nn]$ ]]; then
        warn "Skipping cron setup."
        return
    fi

    local cron_line="* * * * * cd ${INSTALL_DIR} && php artisan schedule:run >> /dev/null 2>&1"
    local current_cron
    current_cron="$(crontab -l 2>/dev/null || true)"

    if echo "$current_cron" | grep -Fq "$cron_line"; then
        success "Cron job already exists."
        return
    fi

    (echo "$current_cron"; echo "$cron_line") | crontab -
    success "Cron job installed: schedule:run every minute."
}

setup_queue_worker() {
    read -r -p "Install queue worker (Supervisor)? [Y/n]: " install_worker
    if [[ "$install_worker" =~ ^[Nn]$ ]]; then
        warn "Skipping queue worker setup."
        return
    fi

    if ! command -v supervisorctl >/dev/null 2>&1; then
        info "Installing Supervisor..."
        apt-get update -y
        apt-get install -y supervisor
    fi

    local conf="/etc/supervisor/conf.d/arvobill-worker.conf"
    if [[ -f "$conf" ]]; then
        success "Supervisor worker config already exists."
    else
        cat >"$conf" <<EOF
[program:arvobill-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${INSTALL_DIR}/artisan queue:work --sleep=3 --tries=3 --timeout=120
autostart=true
autorestart=true
numprocs=1
user=www-data
redirect_stderr=true
stdout_logfile=/var/log/arvobill-worker.log
stopwaitsecs=3600
EOF
        success "Supervisor worker config created."
    fi

    supervisorctl reread || true
    supervisorctl update || true
    supervisorctl status || true
}

update_env_value() {
    local key="$1"
    local value="$2"
    local env_file="$INSTALL_DIR/.env"

    if grep -qE "^${key}=" "$env_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >>"$env_file"
    fi
}

run_mysql_query() {
    local query="$1"
    local root_password="${2:-}"

    if [[ -n "$root_password" ]]; then
        MYSQL_PWD="$root_password" mysql -u root -e "$query"
    else
        mysql -u root -e "$query"
    fi
}

escape_sql_string() {
    local input="$1"
    printf "%s" "${input//\'/\'\'}"
}

create_mysql_database_and_user() {
    local db_host="$1"
    local db_name="$2"
    local db_user="$3"
    local db_password="$4"
    local db_port="$5"

    info "Creating MySQL database and user..."

    local root_password=""
    if ! mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
        warn "Direct MySQL root login failed. Root password may be required."
        read -r -s -p "MySQL root password: " root_password
        echo
    fi

    local user_host="$db_host"
    if [[ -z "$user_host" || "$user_host" == "localhost" || "$user_host" == "127.0.0.1" ]]; then
        user_host="127.0.0.1"
    fi

    local db_name_escaped db_user_escaped db_password_escaped user_host_escaped
    db_name_escaped="$(escape_sql_string "$db_name")"
    db_user_escaped="$(escape_sql_string "$db_user")"
    db_password_escaped="$(escape_sql_string "$db_password")"
    user_host_escaped="$(escape_sql_string "$user_host")"

    run_mysql_query "CREATE DATABASE IF NOT EXISTS \`$db_name_escaped\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" "$root_password"
    run_mysql_query "CREATE USER IF NOT EXISTS '$db_user_escaped'@'$user_host_escaped' IDENTIFIED BY '$db_password_escaped';" "$root_password"
    run_mysql_query "GRANT ALL PRIVILEGES ON \`$db_name_escaped\`.* TO '$db_user_escaped'@'$user_host_escaped';" "$root_password"

    if [[ "$user_host" == "127.0.0.1" ]]; then
        run_mysql_query "CREATE USER IF NOT EXISTS '$db_user_escaped'@'localhost' IDENTIFIED BY '$db_password_escaped';" "$root_password"
        run_mysql_query "GRANT ALL PRIVILEGES ON \`$db_name_escaped\`.* TO '$db_user_escaped'@'localhost';" "$root_password"
    fi

    run_mysql_query "FLUSH PRIVILEGES;" "$root_password"
    success "MySQL database/user ready: ${db_name} / ${db_user}@${user_host}"
}

prompt_database_config() {
    info "Database configuration"

    read -r -p "Database host [127.0.0.1]: " db_host
    read -r -p "Database port [3306]: " db_port
    read -r -p "Database name: " db_name
    read -r -p "Database user: " db_user
    read -r -s -p "Database password: " db_password
    echo

    if [[ -z "${db_name}" || -z "${db_user}" || -z "${db_password}" ]]; then
        error "Database name, user, and password are required."
        exit 1
    fi

    local resolved_host="${db_host:-127.0.0.1}"
    local resolved_port="${db_port:-3306}"

    read -r -p "Auto-create MySQL database and user now? [Y/n]: " create_db_user
    if [[ ! "$create_db_user" =~ ^[Nn]$ ]]; then
        create_mysql_database_and_user "$resolved_host" "$db_name" "$db_user" "$db_password" "$resolved_port"
    else
        warn "Skipping automatic DB user/database creation."
    fi

    update_env_value "DB_CONNECTION" "mysql"
    update_env_value "DB_HOST" "$resolved_host"
    update_env_value "DB_PORT" "$resolved_port"
    update_env_value "DB_DATABASE" "$db_name"
    update_env_value "DB_USERNAME" "$db_user"
    update_env_value "DB_PASSWORD" "$db_password"

    success "Database settings written to .env"
}

print_summary() {
    echo
    success "ArvoBill installation completed."
    echo
    echo "Installation directory: $INSTALL_DIR"
    echo
    echo "Next steps:"
    if [[ "$SSL_CONFIGURED" == "yes" ]]; then
        echo "1) Nginx and SSL are configured for: https://${PANEL_DOMAIN}"
        echo "2) Run database migrations:"
        echo "   cd $INSTALL_DIR && php artisan migrate"
        echo "3) Create your first admin/superuser account."
    else
        echo "1) Configure Nginx virtual host for this directory."
        echo "2) Set up SSL using Let's Encrypt."
        echo "3) Run database migrations:"
        echo "   cd $INSTALL_DIR && php artisan migrate"
        echo "4) Create your first admin/superuser account."
    fi
    echo
    warn "No payment providers or infrastructure credentials were configured by this installer."
}

main() {
    echo "-----------------------------------------------"
    echo "ArvoBill Installer (Ubuntu 22.04+)"
    echo "-----------------------------------------------"

    require_root
    check_ubuntu
    prompt_install_dir
    download_and_extract
    install_dependencies
    ensure_database_service
    setup_application_dependencies
    setup_laravel
    configure_cron
    setup_queue_worker
    prompt_database_config
    setup_nginx_and_ssl
    print_summary
}

main "$@"
