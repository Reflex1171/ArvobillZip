#!/usr/bin/env bash

set -euo pipefail

ZIP_URL="https://github.com/Reflex1171/ArvobillZip/raw/refs/heads/main/ArvoBill-main.zip"
DEFAULT_INSTALL_DIR="/var/www/arvobill"
TMP_ZIP="/tmp/arvobill-update.zip"
TMP_DIR="$(mktemp -d /tmp/arvobill-update.XXXXXX)"
APP_WAS_PUT_DOWN="no"
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

    if command -v composer >/dev/null 2>&1; then
        composer config --global cafile "${COMPOSER_CAFILE_PATH}" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    rm -f "$TMP_ZIP" || true
    rm -rf "$TMP_DIR" || true
}

restore_app_mode() {
    if [[ "${APP_WAS_PUT_DOWN}" == "yes" ]] && [[ -n "${INSTALL_DIR:-}" ]] && [[ -f "${INSTALL_DIR}/artisan" ]]; then
        php "${INSTALL_DIR}/artisan" up >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT
trap restore_app_mode EXIT

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "This updater must be run as root (use sudo)."
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
    read -r -p "ArvoBill install directory [default: ${DEFAULT_INSTALL_DIR}]: " install_dir
    INSTALL_DIR="${install_dir:-$DEFAULT_INSTALL_DIR}"

    if [[ ! -d "$INSTALL_DIR" ]]; then
        error "Install directory does not exist: $INSTALL_DIR"
        exit 1
    fi

    if [[ ! -f "$INSTALL_DIR/artisan" ]]; then
        error "No Laravel app detected in: $INSTALL_DIR (artisan not found)"
        exit 1
    fi

    if [[ ! -w "$INSTALL_DIR" ]]; then
        error "Install directory is not writable: $INSTALL_DIR"
        exit 1
    fi

    success "Updating installation at: $INSTALL_DIR"
}

load_nvm_if_present() {
    if [[ -s /root/.nvm/nvm.sh ]]; then
        # shellcheck disable=SC1091
        source /root/.nvm/nvm.sh
        nvm use 20 >/dev/null 2>&1 || nvm use node >/dev/null 2>&1 || true
    fi
}

enter_maintenance_mode() {
    read -r -p "Enable maintenance mode during update? [Y/n]: " use_maintenance
    if [[ "$use_maintenance" =~ ^[Nn]$ ]]; then
        warn "Skipping maintenance mode."
        return
    fi

    php "${INSTALL_DIR}/artisan" down || true
    APP_WAS_PUT_DOWN="yes"
    success "Application is in maintenance mode."
}

download_and_extract() {
    info "Downloading latest ArvoBill ZIP..."
    curl -fsSL "$ZIP_URL" -o "$TMP_ZIP"
    success "Download complete."

    info "Extracting update package..."
    unzip -q "$TMP_ZIP" -d "$TMP_DIR"

    if [[ -d "$TMP_DIR/ArvoBill-main" ]]; then
        SOURCE_DIR="$TMP_DIR/ArvoBill-main"
    else
        SOURCE_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    fi

    if [[ -z "${SOURCE_DIR:-}" || ! -d "$SOURCE_DIR" ]]; then
        error "Failed to locate extracted source directory."
        exit 1
    fi

    success "Update package extracted."
}

sync_files() {
    info "Syncing application files..."

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --force --delete-after \
            --exclude ".env" \
            --exclude "storage/*" \
            --exclude "bootstrap/cache/*" \
            "${SOURCE_DIR}/" "${INSTALL_DIR}/"
    else
        warn "rsync is not installed, using cp fallback (no delete support)."
        shopt -s dotglob nullglob
        cp -a "${SOURCE_DIR}/"* "${INSTALL_DIR}/"
        shopt -u dotglob nullglob
    fi

    success "Files synced."
}

install_dependencies_and_build() {
    load_nvm_if_present
    ensure_composer_tls

    info "Installing PHP dependencies..."
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_CAFILE="${COMPOSER_CAFILE_PATH}" \
        SSL_CERT_FILE="${COMPOSER_CAFILE_PATH}" CURL_CA_BUNDLE="${COMPOSER_CAFILE_PATH}" \
        composer install --no-dev --optimize-autoloader --no-interaction --working-dir="$INSTALL_DIR"
    success "Composer install complete."

    info "Installing Node dependencies..."
    npm install --prefix "$INSTALL_DIR"
    success "NPM install complete."

    info "Building frontend assets..."
    npm run build --prefix "$INSTALL_DIR"
    success "Frontend build complete."
}

fix_permissions() {
    info "Applying file permissions..."

    local web_user="www-data"
    local web_group="www-data"

    if id -u "$web_user" >/dev/null 2>&1; then
        chown -R "$web_user:$web_group" "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache"
        find "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" -type d -exec chmod 775 {} \;
        find "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache" -type f -exec chmod 664 {} \;
        success "Ownership and permissions applied."
    else
        chmod -R ug+rwx "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache"
        warn "www-data user not found; applied permission-only fallback."
    fi
}

run_post_update_steps() {
    info "Running post-update optimization..."
    php "${INSTALL_DIR}/artisan" optimize:clear || true
    success "Caches cleared."

    read -r -p "Run database migrations now? [y/N]: " run_migrations
    if [[ "$run_migrations" =~ ^[Yy]$ ]]; then
        php "${INSTALL_DIR}/artisan" migrate --force
        success "Database migrations complete."
    else
        warn "Skipped migrations. Run them manually before using new schema features."
    fi
}

ensure_schedule_cron() {
    local cron_line="* * * * * cd ${INSTALL_DIR} && php artisan schedule:run >> /dev/null 2>&1"

    if crontab -l 2>/dev/null | grep -Fq "$cron_line"; then
        success "Cron job already exists for scheduler."
        return
    fi

    info "Adding scheduler cron job..."
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    success "Scheduler cron job installed."
}

finish() {
    if [[ "${APP_WAS_PUT_DOWN}" == "yes" ]]; then
        php "${INSTALL_DIR}/artisan" up || true
        APP_WAS_PUT_DOWN="no"
        success "Application is back online."
    fi

    echo
    success "ArvoBill update completed."
    echo "Install directory: ${INSTALL_DIR}"
    echo
    echo "Recommended checks:"
    echo "1) php ${INSTALL_DIR}/artisan migrate --force   (if not run already)"
    echo "2) systemctl status nginx php8.2-fpm"
    echo "3) Verify checkout, payments, and provisioning flows in panel UI"
}

main() {
    echo "-----------------------------------------------"
    echo "ArvoBill Updater (Ubuntu 22.04+)"
    echo "-----------------------------------------------"

    require_root
    check_ubuntu
    prompt_install_dir
    enter_maintenance_mode
    download_and_extract
    sync_files
    install_dependencies_and_build
    fix_permissions
    run_post_update_steps
    ensure_schedule_cron
    finish
}

main "$@"
