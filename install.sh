#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# WARP Web Tool 一键安装脚本
# - 支持 Docker / Docker Compose 自动安装
# - 支持 IP + 端口访问
# - 支持域名 + Caddy 自动 HTTPS
# - 若 VPS 已部署 Caddy，会追加带标记的反代配置并 reload，不覆盖原有项目
# ==============================================================================

PROJECT_NAME="warp-web-tool"
INSTALL_DIR="/root/${PROJECT_NAME}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/SIJULY/WARP-Web-Tool.git}"
APP_PORT="8000"
APP_CONTAINER="warp-web-tool"

CADDY_MARK_START="# WARP Web Tool Config Start"
CADDY_MARK_END="# WARP Web Tool Config End"
INSTALL_ENV_FILE=".install.env"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

print_info() { echo -e "${BLUE}[信息]${PLAIN} $1"; }
print_success() { echo -e "${GREEN}[成功]${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}[提示]${PLAIN} $1" >&2; }
print_error() { echo -e "${RED}[错误]${PLAIN} $1"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || print_error "请使用 root 用户运行本脚本"
}

get_compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        return 1
    fi
}

install_pkg() {
    if command -v apt-get &>/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$@"
    elif command -v yum &>/dev/null; then
        yum install -y "$@"
    else
        print_error "未检测到 apt-get/dnf/yum，请手动安装依赖：$*"
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        print_info "正在安装 Docker..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
    fi

    if ! get_compose_cmd &>/dev/null; then
        print_info "正在安装 Docker Compose..."
        if command -v apt-get &>/dev/null; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
        elif command -v dnf &>/dev/null; then
            dnf install -y docker-compose-plugin || dnf install -y docker-compose
        elif command -v yum &>/dev/null; then
            yum install -y docker-compose-plugin || yum install -y docker-compose
        fi
    fi

    get_compose_cmd &>/dev/null || print_error "Docker Compose 安装失败，请手动安装 docker compose 或 docker-compose 后重试"
}

check_basic_deps() {
    command -v curl &>/dev/null || install_pkg curl
    command -v git &>/dev/null || install_pkg git
}

cleanup_previous_failed_install() {
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${APP_CONTAINER}"; then
        print_warn "检测到上次安装残留容器 ${APP_CONTAINER}，正在清理..."
        docker rm -f "${APP_CONTAINER}" >/dev/null 2>&1 || true
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${PROJECT_NAME}-caddy"; then
        print_warn "检测到上次安装残留容器 ${PROJECT_NAME}-caddy，正在清理..."
        docker rm -f "${PROJECT_NAME}-caddy" >/dev/null 2>&1 || true
    fi
}

install_source_code() {
    print_info "正在拉取源码仓库：${GIT_REPO_URL}"
    rm -rf "${INSTALL_DIR}"
    git clone "${GIT_REPO_URL}" "${INSTALL_DIR}"
}

update_source_code() {
    [ -d "${INSTALL_DIR}/.git" ] || print_error "未检测到已安装项目，请先执行新安装"

    print_info "正在更新源码（保留 docker-compose.yml、Caddyfile 与安装记录）..."
    local backup_dir
    backup_dir=$(mktemp -d)
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && cp "${INSTALL_DIR}/docker-compose.yml" "${backup_dir}/docker-compose.yml"
    [ -f "${INSTALL_DIR}/Caddyfile" ] && cp "${INSTALL_DIR}/Caddyfile" "${backup_dir}/Caddyfile"
    [ -f "${INSTALL_DIR}/${INSTALL_ENV_FILE}" ] && cp "${INSTALL_DIR}/${INSTALL_ENV_FILE}" "${backup_dir}/${INSTALL_ENV_FILE}"

    cd "${INSTALL_DIR}"
    git fetch origin
    git reset --hard origin/main

    [ -f "${backup_dir}/docker-compose.yml" ] && cp "${backup_dir}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
    [ -f "${backup_dir}/Caddyfile" ] && cp "${backup_dir}/Caddyfile" "${INSTALL_DIR}/Caddyfile"
    [ -f "${backup_dir}/${INSTALL_ENV_FILE}" ] && cp "${backup_dir}/${INSTALL_ENV_FILE}" "${INSTALL_DIR}/${INSTALL_ENV_FILE}"
    rm -rf "${backup_dir}"
}

get_public_ip() {
    curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || \
    curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || \
    hostname -I 2>/dev/null | awk '{print $1}' || \
    echo "服务器IP"
}

is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -ltn "sport = :${port}" 2>/dev/null | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'
    elif command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit found ? 0 : 1}'
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"${port}" -sTCP:LISTEN -Pn &>/dev/null
    else
        return 1
    fi
}

find_available_port() {
    local start_port="$1"
    local port="${start_port}"
    while is_port_in_use "${port}"; do
        port=$((port + 1))
    done
    echo "${port}"
}

is_systemd_caddy_active() {
    systemctl is-active --quiet caddy 2>/dev/null
}

prompt_available_port() {
    local default_port="$1"
    local prompt_text="$2"
    local suggested_port="${default_port}"
    local input_port=""

    if is_port_in_use "${suggested_port}"; then
        suggested_port="$(find_available_port "${suggested_port}")"
        print_warn "端口 ${default_port} 已被占用，已为你推荐可用端口 ${suggested_port}"
    fi

    while true; do
        read -rp "${prompt_text} [${suggested_port}]: " input_port
        input_port="${input_port:-${suggested_port}}"

        if ! [[ "${input_port}" =~ ^[0-9]+$ ]] || [ "${input_port}" -lt 1 ] || [ "${input_port}" -gt 65535 ]; then
            print_warn "请输入 1-65535 之间的有效端口"
            continue
        fi

        if is_port_in_use "${input_port}"; then
            suggested_port="$(find_available_port "$((input_port + 1))")"
            print_warn "端口 ${input_port} 已被占用，请换一个端口。推荐：${suggested_port}"
            continue
        fi

        echo "${input_port}"
        return 0
    done
}

write_install_env() {
    local access_mode="$1"
    local domain="$2"
    local port="$3"
    local caddy_mode="$4"
    local caddy_file="$5"
    local caddy_container="$6"

    cat > "${INSTALL_DIR}/${INSTALL_ENV_FILE}" <<EOF_ENV
ACCESS_MODE=${access_mode}
DOMAIN=${domain}
PORT=${port}
CADDY_MODE=${caddy_mode}
CADDY_FILE=${caddy_file}
CADDY_CONTAINER=${caddy_container}
EOF_ENV
}

generate_compose() {
    local bind_ip="$1"
    local port="$2"
    local enable_project_caddy="$3"

    cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF_COMPOSE
services:
  ${PROJECT_NAME}:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${PROJECT_NAME}:local
    container_name: ${APP_CONTAINER}
    restart: always
    ports:
      - "${bind_ip}:${port}:8000"
    environment:
      - TZ=Asia/Shanghai
EOF_COMPOSE

    if [ "${enable_project_caddy}" = "true" ]; then
        cat >> "${INSTALL_DIR}/docker-compose.yml" <<EOF_COMPOSE

  caddy:
    image: caddy:latest
    container_name: ${PROJECT_NAME}-caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./caddy_data:/data
      - ./caddy_config:/config
    depends_on:
      - ${PROJECT_NAME}
EOF_COMPOSE
    fi
}

write_project_caddyfile() {
    local domain="$1"
    cat > "${INSTALL_DIR}/Caddyfile" <<EOF_CADDY
${CADDY_MARK_START}
${domain} {
    encode gzip
    reverse_proxy ${PROJECT_NAME}:8000
}
${CADDY_MARK_END}
EOF_CADDY
}

remove_marked_caddy_block() {
    local file="$1"
    [ -n "${file}" ] && [ -f "${file}" ] || return 0
    sed -i.bak "/${CADDY_MARK_START}/,/${CADDY_MARK_END}/d" "${file}"
}

append_caddy_config() {
    local caddy_file="$1"
    local domain="$2"
    local upstream="$3"

    mkdir -p "$(dirname "${caddy_file}")"
    touch "${caddy_file}"
    remove_marked_caddy_block "${caddy_file}"
    cat >> "${caddy_file}" <<EOF_CADDY

${CADDY_MARK_START}
${domain} {
    encode gzip
    reverse_proxy ${upstream}
}
${CADDY_MARK_END}
EOF_CADDY
}

reload_host_caddy() {
    local caddy_file="$1"
    if command -v caddy &>/dev/null; then
        caddy validate --config "${caddy_file}"
    fi
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || print_error "Caddy 重载失败，请检查 ${caddy_file}"
}

find_running_caddy_container() {
    docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($0) ~ /caddy/ {print $1; exit}'
}

find_container_caddyfile_mount() {
    local container="$1"
    docker inspect "${container}" --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true
}

reload_container_caddy() {
    local container="$1"
    docker exec "${container}" caddy reload --config /etc/caddy/Caddyfile >/dev/null || docker restart "${container}" >/dev/null
}

configure_caddy_for_domain() {
    local domain="$1"
    local port="$2"

    # 1) 优先复用正在运行的宿主机 systemd Caddy。只安装但启动失败的 Caddy 不能安全复用。
    if is_systemd_caddy_active; then
        local host_caddy_file="/etc/caddy/Caddyfile"
        print_info "检测到宿主机 Caddy，将追加反代配置到 ${host_caddy_file}"
        append_caddy_config "${host_caddy_file}" "${domain}" "127.0.0.1:${port}"
        reload_host_caddy "${host_caddy_file}"
        echo "host|${host_caddy_file}|"
        return 0
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service'; then
        print_warn "检测到宿主机已安装 Caddy，但当前不是 active 状态，将不会复用该 Caddy。"
    fi

    # 2) 再尝试复用已有 Docker Caddy（要求 /etc/caddy/Caddyfile 有宿主机文件挂载）
    local caddy_container
    caddy_container="$(find_running_caddy_container)"
    if [ -n "${caddy_container}" ]; then
        local mounted_file
        mounted_file="$(find_container_caddyfile_mount "${caddy_container}")"
        if [ -n "${mounted_file}" ] && [ -f "${mounted_file}" ]; then
            print_info "检测到 Docker Caddy 容器 ${caddy_container}，将追加配置到 ${mounted_file}"
            local public_ip
            public_ip="$(get_public_ip)"
            append_caddy_config "${mounted_file}" "${domain}" "${public_ip}:${port}"
            reload_container_caddy "${caddy_container}"
            echo "docker-existing|${mounted_file}|${caddy_container}"
            return 0
        fi
        print_warn "检测到 Docker Caddy 容器 ${caddy_container}，但未发现可编辑的 Caddyfile 文件挂载，无法安全追加配置。"
        print_warn "为避免影响现有项目，本次将不会启动项目自带 Caddy（80/443 可能已被占用）。"
        print_error "请手动为现有 Caddy 添加反代：${domain} -> 127.0.0.1:${port} 后重试或使用 IP+端口模式"
    fi

    # 3) 未检测到已有 Caddy，启用本项目 Caddy
    if is_port_in_use 80 || is_port_in_use 443; then
        print_error "未检测到可复用的 Caddy，但 80/443 端口已被占用，无法启动本项目自带 Caddy。请先确认占用 80/443 的服务，并把 ${domain} 反代到本项目端口 ${port}，或释放 80/443 后重试。"
    fi

    print_info "未检测到已有 Caddy，将启用本项目自带 Caddy 容器"
    write_project_caddyfile "${domain}"
    echo "project||${PROJECT_NAME}-caddy"
}

install_panel() {
    require_root
    check_basic_deps
    check_docker
    cleanup_previous_failed_install
    install_source_code

    echo -e "\n${YELLOW}--- 访问方式 ---${PLAIN}"
    echo "1) IP + 端口（默认）"
    echo "2) 域名 + 自动 HTTPS（Caddy）"
    read -rp "请选择 [1]: " net_choice
    net_choice="${net_choice:-1}"

    local domain=""
    local port="${APP_PORT}"
    local caddy_mode="none"
    local caddy_file=""
    local caddy_container=""
    local access_url=""

    if [ "${net_choice}" = "2" ]; then
        read -rp "请输入已解析到本 VPS 的域名: " domain
        [ -n "${domain}" ] || print_error "域名不能为空"
        port="8001"
        port="$(prompt_available_port "${port}" "应用本地监听端口")"

        local caddy_result
        caddy_result="$(configure_caddy_for_domain "${domain}" "${port}" | tail -n 1)"
        caddy_mode="$(echo "${caddy_result}" | awk -F'|' '{print $1}')"
        caddy_file="$(echo "${caddy_result}" | awk -F'|' '{print $2}')"
        caddy_container="$(echo "${caddy_result}" | awk -F'|' '{print $3}')"

        if [ "${caddy_mode}" = "project" ]; then
            generate_compose "127.0.0.1" "${port}" "true"
        elif [ "${caddy_mode}" = "host" ]; then
            generate_compose "127.0.0.1" "${port}" "false"
        else
            generate_compose "0.0.0.0" "${port}" "false"
        fi
        access_url="https://${domain}"
        write_install_env "domain" "${domain}" "${port}" "${caddy_mode}" "${caddy_file}" "${caddy_container}"
    else
        port="$(prompt_available_port "${APP_PORT}" "开放端口")"
        generate_compose "0.0.0.0" "${port}" "false"
        local public_ip
        public_ip="$(get_public_ip)"
        access_url="http://${public_ip}:${port}"
        write_install_env "ip" "" "${port}" "none" "" ""
    fi

    print_info "开始构建镜像并启动服务（首次安装 Playwright Chromium 依赖，耗时可能较长）..."
    cd "${INSTALL_DIR}"
    local compose_cmd
    compose_cmd="$(get_compose_cmd)"
    ${compose_cmd} up -d --build

    print_success "WARP Web Tool 安装完成！"
    echo -e "访问地址: ${GREEN}${access_url}${PLAIN}"
    echo -e "安装目录: ${GREEN}${INSTALL_DIR}${PLAIN}"
}

update_panel() {
    require_root
    check_basic_deps
    check_docker
    update_source_code

    print_info "开始重建并更新服务..."
    cd "${INSTALL_DIR}"
    local compose_cmd
    compose_cmd="$(get_compose_cmd)"
    ${compose_cmd} up -d --build
    print_success "WARP Web Tool 更新完成！"
}

uninstall_panel() {
    require_root
    local caddy_mode="none"
    local caddy_file=""
    local caddy_container=""

    if [ -f "${INSTALL_DIR}/${INSTALL_ENV_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${INSTALL_DIR}/${INSTALL_ENV_FILE}"
        caddy_mode="${CADDY_MODE:-none}"
        caddy_file="${CADDY_FILE:-}"
        caddy_container="${CADDY_CONTAINER:-}"
    fi

    if [ -d "${INSTALL_DIR}" ]; then
        if get_compose_cmd &>/dev/null; then
            local compose_cmd
            compose_cmd="$(get_compose_cmd)"
            (cd "${INSTALL_DIR}" && ${compose_cmd} down) || true
        fi
    fi

    if [ "${caddy_mode}" = "host" ] || [ "${caddy_mode}" = "docker-existing" ]; then
        print_info "正在从已有 Caddy 配置中移除本项目配置块..."
        remove_marked_caddy_block "${caddy_file}"
        if [ "${caddy_mode}" = "host" ]; then
            reload_host_caddy "${caddy_file}" || true
        elif [ -n "${caddy_container}" ]; then
            reload_container_caddy "${caddy_container}" || true
        fi
    fi

    rm -rf "${INSTALL_DIR}"
    print_success "WARP Web Tool 已卸载"
}

show_menu() {
    clear
    echo "========================================="
    echo -e "${BLUE}      WARP Web Tool 管理脚本${PLAIN}"
    echo "========================================="
    echo "  1. 新安装"
    echo "  2. 更新（保留部署配置）"
    echo "  3. 卸载"
    echo "  0. 退出"
    read -rp "选择: " choice

    case "${choice}" in
        1) install_panel ;;
        2) update_panel ;;
        3) uninstall_panel ;;
        0) exit 0 ;;
        *) print_error "无效选项" ;;
    esac
}

show_menu