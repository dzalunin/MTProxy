#!/bin/bash
set -Eeuo pipefail

GREEN='\033[38;5;2m'
RED='\033[38;5;1m'
RESET='\033[0m'

MT_CONFIG_DIR=/etc/mtproxy
MT_USER=mtproxy
MT_TELEGRAM_CONFIG="$MT_CONFIG_DIR/proxy-multi.conf"
MT_TELEGRAM_SECRET="$MT_CONFIG_DIR/proxy-secret"
MT_SECRET_FILE="$MT_CONFIG_DIR/secret"

: "${MT_STATS_PORT:=8888}"
: "${MT_HTTP_PORT:=443}"
: "${MT_MAX_CONNECTIONS:=60000}"
: "${MT_WORKERS:=1}"
: "${MT_SECRET_COUNT:=1}"
: "${MT_SECRET:=}"
: "${MT_FAKETLS_DOMAIN:=}"
: "${MT_AUTO_UPDATE_CONFIG:=1}"

function log() {
    printf "%b\n" "$*" >&2
}

function info() {
    log "${GREEN}INFO${RESET} ==> $*"
}

function error() {
    log "${RED}ERROR${RESET} ==> $*"
}

function check_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        error "Configuration file '$file' not found"
        return 1
    fi
    return 0
}

function get_local_ip() {
    local local_ip=$(ip -4 route get 8.8.8.8 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    if [ -z "$local_ip" ]; then
        local_ip=$(grep -vE '(local|ip6|^fd|^$)' /etc/hosts 2>/dev/null | awk 'NR==1 {print $1}')
        info "Detected local IP: $local_ip"
    fi

    if [ -z "$local_ip" ]; then
        error "Could not detect local IP." >&2
        return 1
    fi
    echo "$local_ip"
    return 0
}

function get_external_ip() {
    local external_ip=${EXTERNAL_IP:-}

    if [ -z "$external_ip" ]; then
        external_ip=$(curl -fsS -4 --connect-timeout 5 --max-time 10 https://icanhazip.com 2>/dev/null || curl -s -4 --connect-timeout 5 --max-time 10 https://ifconfig.me 2>/dev/null || true)
    fi
    
    if [ -z "$external_ip" ]; then
        error "Could not detect external IP." >&2
        return 1
    fi
    info "Auto-detected external IP: $external_ip"
    echo "$external_ip"
    return 0
}

# proxy-secret is a static public 128-byte blob used for MTProto key exchange.
function update_telegram_proxy_secret() {

    info "Obtain a secret, used to connect to telegram servers"
    curl -fsS --connect-timeout 5 --max-time 30 https://core.telegram.org/getProxySecret -o $MT_TELEGRAM_SECRET || {
        error 'Cannot download proxy secret from Telegram servers.'
        exit 2
    }
    chmod 644 "$MT_TELEGRAM_SECRET"
}

function update_telegram_proxy_config() {

    info "Obtain current telegram configuration"
    curl -fsS --connect-timeout 5 --max-time 30 https://core.telegram.org/getProxyConfig -o $MT_TELEGRAM_CONFIG || {
        error 'Cannot download proxy configuration from Telegram servers.'
        exit 2
    }
    chmod 644 "$MT_TELEGRAM_CONFIG"
}

function new_secret() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

function tg_link() {
    local secret_hex=$1
    local external_ip=$2

    if [ -n "$MT_FAKETLS_DOMAIN" ]; then
        local domain=$(printf '%s' "$MT_FAKETLS_DOMAIN" | cut -d: -f1 | tr -d ' ')
        local domain_hex=$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')

        full_secret_hex="ee${secret_hex}${domain_hex}"
    else
        full_secret_hex="$secret_hex"
    fi

    echo "https://t.me/proxy?server=${external_ip}&port=${MT_HTTP_PORT}&secret=${full_secret_hex}"
}

function read_user_secret() {

    if [ -n "$MT_SECRET" ]; then
        info "Using the explicitly passed secret: '$MT_SECRET'."
    elif [ -f "$MT_SECRET_FILE" ]; then
        MT_SECRET="$(cat "$MT_SECRET_FILE")"
        info "Using the secret in '$MT_SECRET_FILE': '$MT_SECRET'."
    else
        if [ -n "$MT_SECRET_COUNT" ]; then
            if ! [[ "$MT_SECRET_COUNT" -ge 1 && "$MT_SECRET_COUNT" -le 16 ]]; then
                error "Can generate between 1 and 16 secrets."
                exit 2
            fi
        else
            MT_SECRET_COUNT="1"
        fi
        info "No secret passed. Will generate $MT_SECRET_COUNT random ones."
        MT_SECRET="$(new_secret)"
        for pass in $(seq 2 "$MT_SECRET_COUNT"); do
            MT_SECRET="$MT_SECRET,$(new_secret)"
        done
    fi

    if echo "$MT_SECRET" | grep -qE '^[0-9a-fA-F]{32}(,[0-9a-fA-F]{32}){0,15}$'; then
        MT_SECRET="$(echo "$MT_SECRET" | tr '[:upper:]' '[:lower:]')"
        echo "$MT_SECRET" > "$MT_SECRET_FILE"
    else
        error 'Bad secret format: invalid MTProto secret'
        exit 2
    fi
}

function main() {

    local local_ip="$(get_local_ip)"
    local external_ip="$(get_external_ip)"

    if [ "$MT_AUTO_UPDATE_CONFIG" = "1" ]; then
        update_telegram_proxy_config
    fi
    check_file "$MT_TELEGRAM_CONFIG"

    if [ ! -f "$MT_TELEGRAM_SECRET" ]; then
        update_telegram_proxy_secret
    fi   
    check_file "$MT_TELEGRAM_SECRET"
    read_user_secret

    info "Starting Telegram MTProto Proxy"
    info "HTTP Port      : $MT_HTTP_PORT"
    info "Stats Port     : $MT_STATS_PORT"
    info "Workers        : $MT_WORKERS"
    info "Max connections: $MT_MAX_CONNECTIONS"
    info "Fake TLS domain: $MT_FAKETLS_DOMAIN"
    
    local PROXY_ARGS=(
        "-u" "$MT_USER"
        "-p" "$MT_STATS_PORT"
        "-H" "$MT_HTTP_PORT"
        "-M" "$MT_WORKERS"
        "-C" "$MT_MAX_CONNECTIONS"
        "--nat-info" "$local_ip:$external_ip"
        "--aes-pwd" "$MT_TELEGRAM_SECRET" "$MT_TELEGRAM_CONFIG"
    )

    if [ -n "$MT_FAKETLS_DOMAIN" ]; then
        PROXY_ARGS+=("-D" "$MT_FAKETLS_DOMAIN")
    fi

    info "======== Connection Links ========"
    IFS=',' read -ra ADDR <<< "$MT_SECRET"
    for secret in "${ADDR[@]}"; do
        PROXY_ARGS+=("-S" "$(echo "$secret" | tr -d '[:space:]')")
        info "$(tg_link "$secret" "$external_ip")"
    done

    exec /usr/bin/mtproto-proxy "${PROXY_ARGS[@]}"
}

main
