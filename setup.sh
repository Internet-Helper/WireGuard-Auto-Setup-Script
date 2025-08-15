#!/bin/bash

# WireGuard Easy Setup by Internet Helper (Version 1.0 - Start)

set -e

# --- ФУНКЦИЯ-ПЕРЕХВАТЧИК ДЛЯ АВАРИЙНОГО ЗАВЕРШЕНИЯ ---
cleanup_on_exit() {
    echo -e "\n\n❌ Скрипт был прерван. Выполняется очистка..."
    # Завершаем сервер экспорта, если он был запущен
    if [ -n "$SERVER_PID" ] && ps -p "$SERVER_PID" > /dev/null; then
        sudo kill "$SERVER_PID" 2>/dev/null
    fi
    # Удаляем временный архив, если он остался
    if [ -n "$CONFIG_DIR" ] && [ -n "$ARCHIVE_NAME" ] && [ -f "$CONFIG_DIR/$ARCHIVE_NAME" ]; then
        sudo rm -f "$CONFIG_DIR/$ARCHIVE_NAME"
    fi
    echo "✅ Очистка завершена."
    
    # Принудительно завершаем скрипт с кодом, соответствующим прерыванию по Ctrl+C
    exit 130
}

# Устанавливаем перехватчик на сигналы прерывания (Ctrl+C) и завершения
trap cleanup_on_exit INT TERM

# --- ФУНКЦИЯ: ЕДИНАЯ ПРОВЕРКА ПРИ ПЕРВОМ ЗАПУСКЕ (ЗАВИСИМОСТИ И БЕЗОПАСНОСТЬ) ---
run_first_time_setup() {
    local CHECKED_FLAG_FILE="/etc/wireguard/.checked"
    if [ -f "$CHECKED_FLAG_FILE" ]; then
        return 0
    fi

    echo "⚙️  Проверка необходимых пакетов..."
    
    # --- Проверка зависимостей ---
    if ! command -v apt-get &> /dev/null; then
        echo "❌ Ошибка! Этот скрипт предназначен для Debian-подобных систем (использующих apt)."
        echo "❌ На вашей системе не найден пакетный менеджер 'apt-get'."
        exit 1
    fi
    
    local missing_deps=()
    ! command -v wg &> /dev/null && missing_deps+=("wireguard-tools")
    ! command -v qrencode &> /dev/null && missing_deps+=("qrencode")
    ! command -v zip &> /dev/null && missing_deps+=("zip")
    ! command -v python3 &> /dev/null && missing_deps+=("python3")
    ! command -v sudo &> /dev/null && missing_deps+=("sudo")
    ! command -v ss &> /dev/null && ! command -v netstat &> /dev/null && missing_deps+=("iproute2" "net-tools")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "⚠️  Обнаружены отсутствующие пакеты:"
        printf '   %s\n' "${missing_deps[@]}"
        read -p "❓ Установить? (1 - да, 2 - нет): " choice
        if [[ "$choice" == "1" ]]; then
            echo "🔧 Обновление списка пакетов и установка..."
            sudo apt-get update
            sudo apt-get install -y "${missing_deps[@]}"
            echo "✅ Установка завершена!"
        else
            echo "❌ Установка отменена. Скрипт не может продолжить работу без необходимых пакетов."
            exit 1
        fi
        echo
    else
        echo "✅ Все необходимые пакеты установлены!"
    fi

    # --- Проверки безопасности ---
    echo "🛡️  Проверка безопасности..."
    local needs_pause=false

    # Проверка SSH и Firewall
    security_issues=false

    if command -v sshd &> /dev/null; then
       local permit_root_login
       permit_root_login=$(sudo sshd -T | grep -i '^permitrootlogin' | awk '{print $2}')
       local password_auth
       password_auth=$(sudo sshd -T | grep -i '^passwordauthentication' | awk '{print $2}')
       if [[ "$permit_root_login" != "no" ]] || [[ "$password_auth" != "no" ]]; then
           if [[ "$password_auth" != "no" ]]; then
               echo "⚠️  Обнаружено: Аутентификация по паролю"
           fi
           security_issues=true
       fi
    fi

    if command -v iptables &> /dev/null; then
       local input_policy
       input_policy=$(sudo iptables -L INPUT -n 2>/dev/null | head -n 1 | grep -oP 'policy \K[A-Z]+')
       local forward_policy
       forward_policy=$(sudo iptables -L FORWARD -n 2>/dev/null | head -n 1 | grep -oP 'policy \K[A-Z]+')
       if [[ "$input_policy" == "ACCEPT" ]] || [[ "$forward_policy" == "ACCEPT" ]]; then
           if [[ "$input_policy" == "ACCEPT" ]]; then
               echo "⚠️  Обнаружено: Входящий трафик - разрешен"
           fi
           if [[ "$forward_policy" == "ACCEPT" ]]; then
               echo "⚠️  Обнаружено: Транзитный трафик - разрешен"
           fi
           security_issues=true
       fi
    fi

    if [[ "$security_issues" == true ]]; then
       printf "\n\033[1;33m⚠️  Не обязательно, но рекомендуется это изменить по инструкции:\033[0m\n"
       printf "🔗 https://github.com/Internet-Helper/WireGuard-Auto-Setup-Script/wiki \n"
       needs_pause=true
    fi
    
    # Если были показаны предупреждения, делаем паузу
    if [ "$needs_pause" = true ]; then
        echo
        read -p "Нажмите Enter, чтобы продолжить..."
        echo
    fi
    
    echo "✅ Проверки безопасности и пакетов завершены."
    sudo mkdir -p /etc/wireguard
    sudo touch "$CHECKED_FLAG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

SERVER_HAS_PUBLIC_IPV6="false"

# --- ФУНКЦИЯ: ОПРЕДЕЛЕНИЕ ПУБЛИЧНОГО IP-АДРЕСА СЕРВЕРА ---
get_server_public_ip() {
    SERVER_HAS_PUBLIC_IPV6="false"
    local public_ip_v4=""
    local public_ip_v6=""

    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo'); do
        public_ip_v4=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|169\.254\.)' | head -n 1)
        if [ -n "$public_ip_v4" ]; then
            break
        fi
    done
    
    if [ -z "$public_ip_v4" ]; then
        public_ip_v4=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    fi

    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo'); do
        public_ip_v6=$(ip -6 addr show "$iface" scope global 2>/dev/null | grep -oP '(?<=inet6\s)[\da-f:]+(?<!::)/\d+' | grep -v '2001:db8' | head -n 1)
        if [ -n "$public_ip_v6" ]; then
            SERVER_HAS_PUBLIC_IPV6="true"
            break
        fi
    done

    if [ -n "$public_ip_v4" ]; then
        echo "$public_ip_v4"
        return 0
    else
        echo "error"
        return 1
    fi
}


# --- ФУНКЦИЯ-ПОМОЩНИК ДЛЯ ПАУЗЫ ПОСЛЕ ВАЖНЫХ ОПЕРАЦИЙ ---
pause_and_wait() {
    echo
    read -p "Нажмите Enter для возврата в главное меню..."
}

# --- ФУНКЦИИ-ПОМОЩНИКИ ДЛЯ КОНФИГУРАЦИИ ---
get_dns_settings() {
    local __result_var=$1
    local has_ipv6=$2
    local dns_line=""

    echo
    printf "\033[38;5;242m💡 ПОДСКАЗКА:\n"
    printf "   Это помогает обойти блокировки или получить доступ к сайтам вроде СhatGPT, Canva и т.д.\033[0m\n"
    read -p "❓ Использовать публичные DNS? (1 - да, 2 - нет): " use_dns_choice
    if [[ "$use_dns_choice" != "1" ]]; then
        printf -v "$__result_var" ''
        return
    fi
    
    echo
    echo "❓ Выберите DNS:"
    echo "   1. Cloudflare + Google"
    echo "   2. Прокси DNS (обход геоблокировок - актуально для российских серверов)"
    
    local dns_selection
    while true; do
        read -p "-> " dns_selection
        if [[ "$dns_selection" == "1" || "$dns_selection" == "2" ]]; then
            break
        else
            echo "❌ Неверный выбор."
        fi
    done

    local dns_ipv4 dns_ipv6
    if [[ "$dns_selection" == "1" ]]; then
        dns_ipv4="1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4"
        dns_ipv6="2606:4700:4700::1111, 2606:4700:4700::1001, 2001:4860:4860::8888, 2001:4860:4860::8844"
    else
        dns_ipv4="185.87.51.182, 45.95.233.23, 64.188.98.242"
        dns_ipv6="2a05:541:104:7f::1, 2a01:ecc0:2c1:2::2"
    fi

    if [[ "$has_ipv6" == "true" ]]; then
        dns_line="DNS = $dns_ipv4, $dns_ipv6"
        echo "   (i) Обнаружен публичный IPv6, в DNS добавлены адреса AAAA."
    else
        dns_line="DNS = $dns_ipv4"
    fi
    
    printf -v "$__result_var" '%s' "$dns_line"
}

get_obfuscation_settings() {
    local __result_var=$1
    local obfuscation_settings=""
    
    echo
    read -p "❓ Включить отправку мусорных пакетов для маскировки Wireguard? (1 - да, 2 - нет): " use_obfs_choice
    if [[ "$use_obfs_choice" != "1" ]]; then
        printf -v "$__result_var" ''
        return
    fi
    
    echo
    echo "⚙️  Выберите параметры маскировки:"
    echo "   1. Jc = 4, Jmin = 40, Jmax = 70"
    echo "   2. Jc = 8, Jmin = 40, Jmax = 70"
    echo "   3. Jc = 120, Jmin = 23, Jmax = 911"
    echo "   4. Использовать случайные значения"
    
    local obfs_selection
    while true; do
        read -p "-> " obfs_selection
        if [[ "$obfs_selection" =~ ^[1-4]$ ]]; then
            break
        else
            echo "❌ Неверный выбор."
        fi
    done

    local jc jmin jmax
    case $obfs_selection in
        1) jc=4; jmin=40; jmax=70 ;;
        2) jc=8; jmin=40; jmax=70 ;;
        3) jc=120; jmin=23; jmax=911 ;;
        4) 
           jc=$((RANDOM % (125 - 8 + 1) + 8))
           jmin=$((RANDOM % (50 - 10 + 1) + 10))
           jmax=$((RANDOM % (950 - 100 + 1) + 100))
           echo "🎲 Сгенерированные значения: Jc = $jc, Jmin = $jmin, Jmax = $jmax"
           ;;
    esac

    printf -v obfuscation_settings "Jc = %d\nJmin = %d\nJmax = %d\nS1 = 0\nS2 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4" "$jc" "$jmin" "$jmax"
    
    printf -v "$__result_var" '%s' "$obfuscation_settings"
}

get_network_base() {
    local __result_var=$1
    local context=$2
    local prompt_message=$3
    shift 3
    local used_subnets=("${@}")
    
    local tunnel_subnets
    tunnel_subnets=$(sudo grep -hRo --exclude='*.zip' 'Address\s*=\s*[0-9\.\/]*' /etc/wireguard/*/wg-*.conf 2>/dev/null | grep -o '[0-9\.]\+\/24' | sed 's/\.[0-9]\{1,3\}\/24$/\.0\/24/' || true)
    
    local lan_subnets
    lan_subnets=$(sudo grep -hRo --exclude='*.zip' 'AllowedIPs\s*=\s*.*' /etc/wireguard/*/wg-*.conf 2>/dev/null | \
                  tr ',' '\n' | \
                  grep -oP '(192\.168(\.[0-9]{1,3}){1,2}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}|10(\.[0-9]{1,3}){1,2})\.0\/24' || true)

    mapfile -t existing_subnets < <(printf "%s\n%s\n%s" "$tunnel_subnets" "$lan_subnets" "$(IFS=$'\n'; echo "${used_subnets[*]}")" | grep . | sort -u)

    find_free_subnet() {
        local base_prefix=$1
        local is_taken
        if [[ "$base_prefix" == "192.168" ]]; then
            for i in {0..255}; do
                local p_subnet="192.168.$i.0/24"
                is_taken=false; for used in "${existing_subnets[@]}"; do if [[ "$used" == "$p_subnet" ]]; then is_taken=true; break; fi; done
                if ! $is_taken; then echo "$p_subnet"; return; fi
            done
        elif [[ "$base_prefix" == "172" ]]; then
             for i in {16..31}; do
                for j in {0..255}; do
                    local p_subnet="172.$i.$j.0/24"
                    is_taken=false; for used in "${existing_subnets[@]}"; do if [[ "$used" == "$p_subnet" ]]; then is_taken=true; break; fi; done
                    if ! $is_taken; then echo "$p_subnet"; return; fi
                done
            done
        elif [[ "$base_prefix" == "10" ]]; then
            for i in {0..255}; do
                for j in {0..255}; do
                    local p_subnet="10.$i.$j.0/24"
                    is_taken=false; for used in "${existing_subnets[@]}"; do if [[ "$used" == "$p_subnet" ]]; then is_taken=true; break; fi; done
                    if ! $is_taken; then echo "$p_subnet"; return; fi
                done
            done
        fi
        echo ""
    }

    local suggested_192; suggested_192=$(find_free_subnet "192.168")
    local suggested_172; suggested_172=$(find_free_subnet "172")
    local suggested_10;  suggested_10=$(find_free_subnet "10")

    while true; do
        echo; echo "❓ $prompt_message"
        local opt1 opt2 opt3 val1 val2 val3
        if [[ "$context" == "router" ]]; then
            opt1="$suggested_192 (рекомендуется)"; val1="$suggested_192"
            opt2="$suggested_172"; val2="$suggested_172"
            opt3="$suggested_10"; val3="$suggested_10"
        else
            opt1="$suggested_172 (рекомендуется)"; val1="$suggested_172"
            opt2="$suggested_10"; val2="$suggested_10"
            opt3="$suggested_192"; val3="$suggested_192"
        fi

        [ -n "$val1" ] && echo "   1) $opt1"
        [ -n "$val2" ] && echo "   2) $opt2"
        [ -n "$val3" ] && echo "   3) $opt3"
        echo "   4) Ввести свою подсеть"
        read -p "-> " choice

        local chosen_subnet=""
        case $choice in
            1) chosen_subnet=$val1 ;;
            2) chosen_subnet=$val2 ;;
            3) chosen_subnet=$val3 ;;
            4) 
                read -p "🔎 Введите числа для подсети (например, 10.100.200 или 192.168.55): " custom_prefix
                if [[ "$custom_prefix" =~ ^(10\.([0-9]{1,3}\.){1,2}[0-9]{1,3})$ || "$custom_prefix" =~ ^(172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3})$ || "$custom_prefix" =~ ^(192\.168\.[0-9]{1,3})$ ]]; then
                    local proposed_subnet="${custom_prefix}.0/24"
                    local is_taken=false
                    for used in "${existing_subnets[@]}"; do if [[ "$used" == "$proposed_subnet" ]]; then is_taken=true; break; fi; done
                    if $is_taken; then
                        echo "❌ Ошибка! Подсеть $proposed_subnet уже используется."
                        continue
                    else
                        chosen_subnet="$proposed_subnet"
                    fi
                else
                    echo "❌ Ошибка! Неверный формат или недопустимый диапазон приватной сети."
                    echo "   Доступные диапазоны: 10.[0-255].[0-255], 172.[16-31].[0-255] или 192.168.[0-255]"
                    continue
                fi
                ;;
            *) echo "❌ Неверный выбор."; continue ;;
        esac

        if [ -n "$chosen_subnet" ]; then
            printf -v "$__result_var" '%s' "$chosen_subnet"
            return 0
        else
            echo "❌ Ошибка выбора. Попробуйте снова."
        fi
    done
}

get_wg_network() {
    local __result_var=$1
    get_network_base "$__result_var" "wg" "Укажите подсеть для WireGuard туннеля:"
}

get_router_lan_subnet() {
    local __result_var=$1
    local router_num=$2
    shift 2
    get_network_base "$__result_var" "router" "Укажите локальную подсеть для 📡 роутера $router_num:" "$@"
}

get_config_mode() {
    local conf_name=$1
    local config_file
    
    config_file=$(sudo find "/etc/wireguard/$conf_name" -name "wg-*.conf" -print -quit 2>/dev/null)

    if [ -f "$config_file" ]; then
        if sudo grep -q "(Mode 1)" "$config_file"; then
            echo "[☁️  Сервер]"
        elif sudo grep -q "(Mode 2)" "$config_file"; then
            echo "[📡 Роутер]"
        elif sudo grep -q "(Mode 3)" "$config_file"; then
            echo "[🏠 LAN]"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

is_config_truly_active() {
    local conf_name=$1
    if systemctl is-active --quiet "wg-quick@wg-$conf_name" && sudo wg show "wg-$conf_name" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

verify_tunnel_activation() {
    local WG_INTERFACE=$1
    echo "⌛ Проверка активации..."
    sleep 2 
    if sudo wg show "$WG_INTERFACE" &>/dev/null; then
        echo "✅ Туннель '$WG_INTERFACE' успешно активирован!"
        return 0
    else
        echo "❌ ОШИБКА: Не удалось активировать туннель '$WG_INTERFACE'"
        echo "⚠️  Пожалуйста, проверьте журнал командой чтобы посмотреть причину ошибки: journalctl -u wg-quick@${WG_INTERFACE} -e"
        return 1
    fi
}

deep_clean_config() {
    local CONFIG_NAME=$1
    local WG_INTERFACE="wg-$CONFIG_NAME"
    
    sudo wg-quick down "$WG_INTERFACE" &>/dev/null || true
    sudo systemctl stop "wg-quick@${WG_INTERFACE}" &>/dev/null || true
    sudo systemctl disable "wg-quick@${WG_INTERFACE}" &>/dev/null || true
    
    sudo rm -f "/etc/wireguard/${WG_INTERFACE}.conf"
    sudo rm -rf "/etc/wireguard/$CONFIG_NAME"

    if ip link show "$WG_INTERFACE" &>/dev/null; then
        sudo ip link delete dev "$WG_INTERFACE"
    fi
    echo -e "\n✅ Удаление '$CONFIG_NAME' завершено!"
}

export_configs() {
    CONFIG_NAME=$1
    CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"
    ARCHIVE_NAME="${CONFIG_NAME}.zip"

    if [ -z "$(sudo find "$CONFIG_DIR" -maxdepth 1 -type f \( -name 'client*.conf' -o -name 'router*.conf' \) -print -quit)" ]; then
        echo "ℹ️  Конфиги для '$CONFIG_NAME' не найдены. Пропускаю."
        return
    fi

    sudo zip -j "$CONFIG_DIR/$ARCHIVE_NAME" "$CONFIG_DIR"/client*.conf "$CONFIG_DIR"/router*.conf > /dev/null 2>&1

    local PORT=58585
    if command -v ss &> /dev/null; then
        # Используем ss для проверки порта
        while sudo ss -tlnp | grep -q ":$PORT "; do
            PORT=$((PORT + 1))
        done
    elif command -v netstat &> /dev/null; then
        # Используем netstat как запасной вариант
        while sudo netstat -tlnp | grep -q ":$PORT "; do
            PORT=$((PORT + 1))
        done
    else
        # Если нет ни ss, ни netstat, используем порт по умолчанию с предупреждением
        echo "⚠️  Утилиты 'ss' и 'netstat' не найдены. Не могу проверить доступность порта. Использую 58800 по умолчанию."
    fi
    
    local SERVER_IP; SERVER_IP=$(get_server_public_ip)
    if [ "$SERVER_IP" == "error" ]; then
        echo "❌ Критическая ошибка: не удалось определить IP-адрес сервера для Endpoint."
        return 1
    fi

    cd "$CONFIG_DIR"
    sudo sh -c "python3 -m http.server $PORT > /dev/null 2>&1" &
    SERVER_PID=$!
    cd - > /dev/null

    local cleanup_command="sleep 600; if ps -p $SERVER_PID > /dev/null; then sudo kill $SERVER_PID 2>/dev/null; sudo rm -f '$CONFIG_DIR/$ARCHIVE_NAME'; fi"
    nohup sh -c "$cleanup_command" >/dev/null 2>&1 &
    local TIMER_PID=$!

    printf "📌 Ссылка на архив %s:\n" "$ARCHIVE_NAME"
    printf "🔗 http://%s:%s/%s\n\n" "$SERVER_IP" "$PORT" "$ARCHIVE_NAME"
    
    echo "📱 Или отсканируйте QR-код для загрузки архива:"
    echo
    if command -v qrencode &>/dev/null; then
        qrencode -t ansiutf8 -m 1 "http://${SERVER_IP}:${PORT}/${ARCHIVE_NAME}"
    else
        echo "   (qrencode не установлен, QR-код не может быть показан)"
    fi
    echo

    read -p "📌 Ссылка будет активна 10 минут, или пока вы не нажмете Enter... "

    echo
    sudo kill $SERVER_PID 2>/dev/null
    if ps -p $TIMER_PID > /dev/null; then
        kill $TIMER_PID 2>/dev/null 
    fi
    sudo rm -f "$CONFIG_DIR/$ARCHIVE_NAME"

    unset SERVER_PID CONFIG_NAME CONFIG_DIR ARCHIVE_NAME
}

generate_client_allowed_ips_string() {
    local subnets_to_process=("$@")
    local broad_subnets=()
    for subnet in "${subnets_to_process[@]}"; do
        if [[ "$subnet" =~ ^10\. ]]; then
            broad_subnets+=("10.0.0.0/16")
        elif [[ "$subnet" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
            broad_subnets+=("172.16.0.0/12")
        elif [[ "$subnet" =~ ^192\.168\. ]]; then
            broad_subnets+=("192.168.0.0/16")
        fi
    done
    printf "%s\n" "${broad_subnets[@]}" | sort -u | paste -sd ',' | sed 's/,/, /g'
}

# --- ФУНКЦИЯ СОЗДАНИЯ: РЕЖИМ 1 ---
run_creation_flow_mode1() {
    local CONFIG_NAME=$1; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local WG_INTERFACE="wg-$CONFIG_NAME"
    
    if ip link show "$WG_INTERFACE" &>/dev/null; then echo "❌ Ошибка: Сетевой интерфейс '$WG_INTERFACE' уже существует."; return 1; fi
    
    DEFAULT_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -z "$DEFAULT_INTERFACE" ]; then echo "❌ Не удалось определить сетевой интерфейс по умолчанию."; return 1; fi
    
    SERVER_IP=$(get_server_public_ip)
    if [ "$SERVER_IP" == "error" ]; then echo "❌ Не удалось определить IP-адрес сервера."; return 1; fi

    local max_port=58799
    if [ -d "/etc/wireguard" ]; then
        for dir in /etc/wireguard/*/ ; do
            if [ -d "$dir" ] && [ "$dir" != "$CONFIG_DIR/" ]; then
                config_file=$(sudo find "$dir" -name "wg-*.conf" -print -quit 2>/dev/null); if [ -f "$config_file" ]; then
                    port=$(sudo grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$config_file" | head -n 1 || echo "0"); if [[ "$port" -gt "$max_port" ]]; then max_port=$port; fi
                fi
            fi
        done
    fi
    
    local LISTEN_PORT
    local SUGGESTED_PORT=$((max_port + 1))
    echo
    while true; do
        read -p "❓ Выберите внешний порт (нажмите Enter чтобы использовать '$SUGGESTED_PORT'): " user_port
        LISTEN_PORT=${user_port:-$SUGGESTED_PORT}
        if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1024 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
            echo "❌ Ошибка! Введите корректный номер порта (1024-65535)."
            continue
        fi
        if sudo grep -qR --include='wg-*.conf' "^\s*ListenPort\s*=\s*$LISTEN_PORT\s*$" /etc/wireguard/ 2>/dev/null; then
            local conflicting_config
            conflicting_config=$(sudo grep -lR --include='wg-*.conf' "^\s*ListenPort\s*=\s*$LISTEN_PORT\s*$" /etc/wireguard/ | head -n 1 | xargs dirname | xargs basename)
            echo "❌ Ошибка! Порт $LISTEN_PORT уже используется конфигурацией '$conflicting_config'."
            continue
        fi
        break
    done

    local WG_SUBNET_V4; get_wg_network WG_SUBNET_V4
    if [ -z "$WG_SUBNET_V4" ]; then echo "❌ Не удалось определить подсеть для WireGuard."; return 1; fi
    local WG_NETWORK_V4_PREFIX; WG_NETWORK_V4_PREFIX=$(echo "$WG_SUBNET_V4" | cut -d'.' -f1-3)

    echo
    while true; do read -p "❓ Сколько клиентов создать для '$CONFIG_NAME'? (1-253): " CLIENT_COUNT
        if [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] && [ "$CLIENT_COUNT" -ge 1 ] && [ "$CLIENT_COUNT" -le 253 ]; then break; else echo "❌ Ошибка! Введите число от 1 до 253."; fi
    done

    local DNS_SETTINGS; get_dns_settings DNS_SETTINGS "$SERVER_HAS_PUBLIC_IPV6"
    local OBFUSCATION_SETTINGS; get_obfuscation_settings OBFUSCATION_SETTINGS
    
    local SERVER_ADDRESS_LINE="Address = ${WG_NETWORK_V4_PREFIX}.1/24"
    local POST_UP_CMDS="PostUp = iptables -A FORWARD -i %i -j ACCEPT --wait 10; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE --wait 10"
    local POST_DOWN_CMDS="PostDown = iptables -D FORWARD -i %i -j ACCEPT --wait 10; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE --wait 10"
    
    local NEW_OCTET_3=$(echo $WG_NETWORK_V4_PREFIX | cut -d'.' -f3)
    local NEW_OCTET_2=$(echo $WG_NETWORK_V4_PREFIX | cut -d'.' -f2)
    local WG_NETWORK_V6=""
    if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
        WG_NETWORK_V6="fd42:42:$(printf '%x' $NEW_OCTET_2):$(printf '%x' $NEW_OCTET_3)::"
        SERVER_ADDRESS_LINE+=", ${WG_NETWORK_V6}1/64"
        POST_UP_CMDS+="; ip6tables -A FORWARD -i %i -j ACCEPT --wait 10; ip6tables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE --wait 10"
        POST_DOWN_CMDS+="; ip6tables -D FORWARD -i %i -j ACCEPT --wait 10; ip6tables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE --wait 10"
    fi

    echo -e "\n🚀 Запуск конфигурации '$CONFIG_NAME'..."
    sudo mkdir -p "$CONFIG_DIR"; sudo chmod 700 "$CONFIG_DIR"
    
    SERVER_PRIVATE=$(wg genkey); SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey)
    declare -a CLIENT_PRIVATE_KEYS; declare -a CLIENT_PUBLIC_KEYS; declare -a CLIENT_PSKS
    for i in $(seq 1 $CLIENT_COUNT); do
        CLIENT_PRIVATE_KEYS[$i]=$(wg genkey); CLIENT_PUBLIC_KEYS[$i]=$(echo "${CLIENT_PRIVATE_KEYS[$i]}" | wg pubkey); CLIENT_PSKS[$i]=$(wg genpsk)
    done
    
    SERVER_CONFIG_FILE_NAME="${WG_INTERFACE}.conf"
    sudo tee "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF
# $CONFIG_NAME (Mode 1)
[Interface]
PrivateKey = $SERVER_PRIVATE
$SERVER_ADDRESS_LINE
ListenPort = $LISTEN_PORT
$POST_UP_CMDS
$POST_DOWN_CMDS
EOF
    for i in $(seq 1 $CLIENT_COUNT); do
        local CLIENT_IP_V4="${WG_NETWORK_V4_PREFIX}.$((i + 1))"
        local CLIENT_ALLOWED_IPS="AllowedIPs = ${CLIENT_IP_V4}/32"
        if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
            local CLIENT_IP_V6="${WG_NETWORK_V6}$((i + 1))"
            CLIENT_ALLOWED_IPS+=", ${CLIENT_IP_V6}/128"
        fi
        
        sudo tee -a "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF

# Peer: Client $i
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEYS[$i]}
PresharedKey = ${CLIENT_PSKS[$i]}
$CLIENT_ALLOWED_IPS
EOF
    done
    
    for i in $(seq 1 $CLIENT_COUNT); do
        local CLIENT_IP_V4="${WG_NETWORK_V4_PREFIX}.$((i + 1))"
        local CLIENT_ADDRESS_LINE="Address = ${CLIENT_IP_V4}/24"
        if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
            local CLIENT_IP_V6="${WG_NETWORK_V6}$((i + 1))"
            CLIENT_ADDRESS_LINE+=", ${CLIENT_IP_V6}/64"
        fi
        local CLIENT_FILE=$([ $i -eq 1 ] && echo "client.conf" || echo "client${i}.conf")
        
        {
            echo "# Client $i for $CONFIG_NAME"
            echo "[Interface]"
            echo "PrivateKey = ${CLIENT_PRIVATE_KEYS[$i]}"
            echo "$CLIENT_ADDRESS_LINE"
            if [ -n "$DNS_SETTINGS" ]; then echo "$DNS_SETTINGS"; fi
            if [ -n "$OBFUSCATION_SETTINGS" ]; then printf "%s\n" "$OBFUSCATION_SETTINGS"; fi
            
            echo ""
            echo "[Peer]"
            echo "PublicKey = $SERVER_PUBLIC"
            echo "PresharedKey = ${CLIENT_PSKS[$i]}"
            echo "Endpoint = $SERVER_IP:$LISTEN_PORT"
            echo "AllowedIPs = 0.0.0.0/0, ::/0"
            echo "PersistentKeepalive = 25"
        } | sudo tee "$CONFIG_DIR/$CLIENT_FILE" > /dev/null
    done
    
    sudo chmod 600 "$CONFIG_DIR"/*; sudo ln -sf "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" "/etc/wireguard/$SERVER_CONFIG_FILE_NAME"
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
        sudo sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    fi
    sudo systemctl enable --now "wg-quick@${WG_INTERFACE}"
    
    if verify_tunnel_activation "$WG_INTERFACE"; then
        clear
        show_summary_for_config "$CONFIG_NAME"
        export_configs "$CONFIG_NAME"
    fi
}

# --- ФУНКЦИЯ СОЗДАНИЯ: РЕЖИМ 2 ---
run_creation_flow_mode2() {
    local CONFIG_NAME=$1; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local WG_INTERFACE="wg-$CONFIG_NAME"
    
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true)
    local active_mode2_config=""
    for conf in "${all_configs[@]}"; do
        if is_config_truly_active "$conf"; then
            local conf_file
            conf_file=$(sudo find "/etc/wireguard/$conf" -name "wg-*.conf" -print -quit 2>/dev/null)
            if [ -f "$conf_file" ] && sudo grep -q "(Mode 2)" "$conf_file"; then
                active_mode2_config=$conf
                break
            fi
        fi
    done
    
    if [ -n "$active_mode2_config" ]; then
        echo "⚠️  ВНИМАНИЕ! Обнаружена активная конфигурация в режиме 2 - '$active_mode2_config'"
        read -p "❓ Остановить и удалить '$active_mode2_config', чтобы создать новую? (1 - да, 2 - нет): " choice
        if [[ "$choice" == "1" ]]; then
            deep_clean_config "$active_mode2_config"; sudo systemctl daemon-reload; sudo systemctl reset-failed
        else
            echo "❌ Создание отменено."; return 1
        fi
    fi

    if ip link show "$WG_INTERFACE" &>/dev/null; then echo "❌ Ошибка: Сетевой интерфейс '$WG_INTERFACE' уже существует."; return 1; fi

    DEFAULT_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -z "$DEFAULT_INTERFACE" ]; then echo "❌ Не удалось определить сетевой интерфейс по умолчанию."; return 1; fi
    DEFAULT_GATEWAY=$(ip -4 route ls | grep default | grep -Po '(?<=via )(\S+)' | head -1)
    if [ -z "$DEFAULT_GATEWAY" ]; then echo "❌ Не удалось определить шлюз по умолчанию."; return 1; fi
    
    SERVER_IP=$(get_server_public_ip)
    if [ "$SERVER_IP" == "error" ]; then echo "❌ Не удалось определить IP-адрес сервера."; return 1; fi
    
    local max_port=58799; local max_table_id=100
    if [ -d "/etc/wireguard" ]; then
        for dir in /etc/wireguard/*/ ; do
            if [ -d "$dir" ] && [ "$dir" != "$CONFIG_DIR/" ]; then
                config_file=$(sudo find "$dir" -name "wg-*.conf" -print -quit 2>/dev/null); if [ -f "$config_file" ]; then
                    port=$(sudo grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$config_file" | head -n 1 || echo "0"); if [[ "$port" -gt "$max_port" ]]; then max_port=$port; fi
                    table_id=$(sudo grep -oP 'table\s+\K[0-9]+' "$config_file" | head -n 1 || echo "0"); if [[ "$table_id" -gt "$max_table_id" ]]; then max_table_id=$table_id; fi
                fi
            fi
        done
    fi
    local NEW_TABLE_ID=$((max_table_id + 1))
    
    local LISTEN_PORT
    local SUGGESTED_PORT=$((max_port + 1))
    echo
    while true; do
        read -p "❓ Выберите внешний порт (нажмите Enter чтобы использовать '$SUGGESTED_PORT'): " user_port
        LISTEN_PORT=${user_port:-$SUGGESTED_PORT}
        if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1024 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
            echo "❌ Ошибка! Введите корректный номер порта (1024-65535)."
            continue
        fi
        if sudo grep -qR --include='wg-*.conf' "^\s*ListenPort\s*=\s*$LISTEN_PORT\s*$" /etc/wireguard/ 2>/dev/null; then
            local conflicting_config
            conflicting_config=$(sudo grep -lR --include='wg-*.conf' "^\s*ListenPort\s*=\s*$LISTEN_PORT\s*$" /etc/wireguard/ | head -n 1 | xargs dirname | xargs basename)
            echo "❌ Ошибка! Порт $LISTEN_PORT уже используется конфигурацией '$conflicting_config'."
            continue
        fi
        break
    done

    local WG_SUBNET_V4; get_wg_network WG_SUBNET_V4
    if [ -z "$WG_SUBNET_V4" ]; then echo "❌ Не удалось определить подсеть для WireGuard."; return 1; fi
    local WG_NETWORK_PREFIX; WG_NETWORK_PREFIX=$(echo "$WG_SUBNET_V4" | cut -d'.' -f1-3)
    
    local ROUTER_COUNT;
    echo
    while true; do read -p "❓ Сколько 📡 роутеров создать для '$CONFIG_NAME'? (1-100): " ROUTER_COUNT
        if [[ "$ROUTER_COUNT" =~ ^[0-9]+$ ]] && [ "$ROUTER_COUNT" -ge 1 ] && [ "$ROUTER_COUNT" -le 100 ]; then break; else echo "❌ Ошибка! Введите число от 1 до 100."; fi
    done
    
    declare -a ROUTER_LAN_SUBNETS
    local chosen_lan_subnets=()
    for i in $(seq 1 $ROUTER_COUNT); do
        local new_subnet
        get_router_lan_subnet new_subnet "$i" "$WG_SUBNET_V4" "${chosen_lan_subnets[@]}"
        if [ -z "$new_subnet" ]; then echo "❌ Создание отменено из-за ошибки выбора подсети."; return 1; fi
        ROUTER_LAN_SUBNETS[$i]="$new_subnet"
        chosen_lan_subnets+=("$new_subnet")
    done
    
    local GATEWAY_ROUTER_NUM=1
    if [ "$ROUTER_COUNT" -gt 1 ]; then
        echo
        while true; do
            read -p "❓ Какой роутер будет шлюзом для выхода в интернет? (1-${ROUTER_COUNT}): " user_choice
            if [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le $ROUTER_COUNT ]; then
                GATEWAY_ROUTER_NUM=$user_choice; break
            else
                echo "❌ Ошибка! Введите число от 1 до ${ROUTER_COUNT}."; fi
        done
    fi
    
    local CLIENT_COUNT
    while true; do echo; read -p "❓ Сколько 📱 клиентов создать для '$CONFIG_NAME'? (1-100): " CLIENT_COUNT
        if [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] && [ "$CLIENT_COUNT" -ge 1 ] && [ "$CLIENT_COUNT" -le 100 ]; then break; else echo "❌ Ошибка! Введите число от 1 до 100."; fi
    done
    
    local DNS_SETTINGS; get_dns_settings DNS_SETTINGS "$SERVER_HAS_PUBLIC_IPV6"
    local OBFUSCATION_SETTINGS; get_obfuscation_settings OBFUSCATION_SETTINGS

    echo -e "\n🚀 Запуск конфигурации '$CONFIG_NAME'..."
    sudo mkdir -p "$CONFIG_DIR"; sudo chmod 700 "$CONFIG_DIR"

    SERVER_PRIVATE=$(wg genkey); SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey); 
    declare -a ROUTER_PRIVKEYS; declare -a ROUTER_PUBKEYS; declare -a ROUTER_PSKS
    for i in $(seq 1 $ROUTER_COUNT); do ROUTER_PRIVKEYS[$i]=$(wg genkey); ROUTER_PUBKEYS[$i]=$(echo "${ROUTER_PRIVKEYS[$i]}" | wg pubkey); ROUTER_PSKS[$i]=$(wg genpsk); done
    
    declare -a CLIENT_PRIVKEYS; declare -a CLIENT_PUBKEYS; declare -a CLIENT_PSKS
    for i in $(seq 1 $CLIENT_COUNT); do CLIENT_PRIVKEYS[$i]=$(wg genkey); CLIENT_PUBKEYS[$i]=$(echo "${CLIENT_PRIVKEYS[$i]}" | wg pubkey); CLIENT_PSKS[$i]=$(wg genpsk); done
    
    local SERVER_WG_IP="${WG_NETWORK_PREFIX}.1"
    
    POST_UP="iptables -A INPUT -p udp --dport $LISTEN_PORT -j ACCEPT --wait 10; iptables -A FORWARD -i %i -j ACCEPT --wait 10; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE --wait 10; ip route add default dev $DEFAULT_INTERFACE via $DEFAULT_GATEWAY table $NEW_TABLE_ID ; ip rule add from $SERVER_IP table $NEW_TABLE_ID"
    POST_DOWN="iptables -D INPUT -p udp --dport $LISTEN_PORT -j ACCEPT --wait 10; iptables -D FORWARD -i %i -j ACCEPT --wait 10; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE --wait 10; ip rule delete from $SERVER_IP table $NEW_TABLE_ID ; ip route flush table $NEW_TABLE_ID"

    SERVER_CONFIG_FILE_NAME="${WG_INTERFACE}.conf"
    sudo tee "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF
# $CONFIG_NAME (Mode 2)
# Routing Table: $NEW_TABLE_ID
[Interface]
PrivateKey = $SERVER_PRIVATE
Address = $SERVER_WG_IP/24
ListenPort = $LISTEN_PORT
PostUp = $POST_UP
PostDown = $POST_DOWN
EOF

    local ip_counter=2
    for i in $(seq 1 $ROUTER_COUNT); do
        local ROUTER_WG_IP="${WG_NETWORK_PREFIX}.$ip_counter"
        local ALLOWED_IPS="$ROUTER_WG_IP/32, ${ROUTER_LAN_SUBNETS[$i]}"
        if [ "$i" -eq "$GATEWAY_ROUTER_NUM" ]; then
            ALLOWED_IPS+=", 0.0.0.0/0, ::/0"
        fi
        
        sudo tee -a "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF

# Peer: Router $i (LAN: ${ROUTER_LAN_SUBNETS[$i]})
[Peer]
PublicKey = ${ROUTER_PUBKEYS[$i]}
PresharedKey = ${ROUTER_PSKS[$i]}
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF
        ip_counter=$((ip_counter + 1))
    done

    for i in $(seq 1 $CLIENT_COUNT); do
        local CLIENT_WG_IP="${WG_NETWORK_PREFIX}.$ip_counter"
        sudo tee -a "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF

# Peer: Client $i
[Peer]
PublicKey = ${CLIENT_PUBKEYS[$i]}
PresharedKey = ${CLIENT_PSKS[$i]}
AllowedIPs = $CLIENT_WG_IP/32
PersistentKeepalive = 25
EOF
        ip_counter=$((ip_counter + 1))
    done
    
    ip_counter=2
    for i in $(seq 1 $ROUTER_COUNT); do
        local ROUTER_WG_IP="${WG_NETWORK_PREFIX}.$ip_counter"
        local ROUTER_FILE_NAME=$([ $i -eq 1 ] && echo "router.conf" || echo "router${i}.conf")
        # ИСПРАВЛЕНИЕ: AllowedIPs для роутера в режиме 2
        local router_file_allowed_ips="${WG_NETWORK_PREFIX}.0/24, 0.0.0.0/0, ::/0"
        
        {
            echo "# Router $i for $CONFIG_NAME (LAN: ${ROUTER_LAN_SUBNETS[$i]})"
            echo "[Interface]"
            echo "PrivateKey = ${ROUTER_PRIVKEYS[$i]}"
            echo "Address = $ROUTER_WG_IP/24"
            if [ -n "$OBFUSCATION_SETTINGS" ]; then printf "%s\n" "$OBFUSCATION_SETTINGS"; fi
            
            echo ""
            echo "[Peer]"
            echo "PublicKey = $SERVER_PUBLIC"
            echo "PresharedKey = ${ROUTER_PSKS[$i]}"
            echo "Endpoint = $SERVER_IP:$LISTEN_PORT"
            echo "AllowedIPs = $router_file_allowed_ips"
            echo "PersistentKeepalive = 25"
        } | sudo tee "$CONFIG_DIR/$ROUTER_FILE_NAME" > /dev/null

        ip_counter=$((ip_counter + 1))
    done
    
    for i in $(seq 1 $CLIENT_COUNT); do
        local CLIENT_WG_IP="${WG_NETWORK_PREFIX}.$ip_counter"
        local CLIENT_FILE_NAME=$([ $i -eq 1 ] && echo "client.conf" || echo "client${i}.conf")
        
        {
            echo "# Client $i for $CONFIG_NAME"
            echo "[Interface]"
            echo "PrivateKey = ${CLIENT_PRIVKEYS[$i]}"
            echo "Address = $CLIENT_WG_IP/24"
            if [ -n "$DNS_SETTINGS" ]; then echo "$DNS_SETTINGS"; fi
            if [ -n "$OBFUSCATION_SETTINGS" ]; then printf "%s\n" "$OBFUSCATION_SETTINGS"; fi
            
            echo ""
            echo "[Peer]"
            echo "PublicKey = $SERVER_PUBLIC"
            echo "PresharedKey = ${CLIENT_PSKS[$i]}"
            echo "Endpoint = $SERVER_IP:$LISTEN_PORT"
            echo "AllowedIPs = 0.0.0.0/0, ::/0"
            echo "PersistentKeepalive = 25"
        } | sudo tee "$CONFIG_DIR/$CLIENT_FILE_NAME" > /dev/null

        ip_counter=$((ip_counter + 1))
    done
    
    sudo chmod 600 "$CONFIG_DIR"/*; sudo ln -sf "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" "/etc/wireguard/$SERVER_CONFIG_FILE_NAME"
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null; sudo systemctl enable --now "wg-quick@${WG_INTERFACE}"
    
    if verify_tunnel_activation "$WG_INTERFACE"; then
        clear
        show_summary_for_config "$CONFIG_NAME"
        export_configs "$CONFIG_NAME"
    fi
}

# --- ФУНКЦИЯ СОЗДАНИЯ: РЕЖИМ 3 ---
run_creation_flow_mode3() {
    local CONFIG_NAME=$1; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local WG_INTERFACE="wg-$CONFIG_NAME"
    
    if ip link show "$WG_INTERFACE" &>/dev/null; then echo "❌ Ошибка: Сетевой интерфейс '$WG_INTERFACE' уже существует."; return 1; fi
    
    SERVER_IP=$(get_server_public_ip)
    if [ "$SERVER_IP" == "error" ]; then echo "❌ Не удалось определить IP-адрес сервера."; return 1; fi
    
    local max_port=58799
    if [ -d "/etc/wireguard" ]; then
        for dir in /etc/wireguard/*/ ; do
            if [ -d "$dir" ] && [ "$dir" != "$CONFIG_DIR/" ]; then
                config_file=$(sudo find "$dir" -name "wg-*.conf" -print -quit 2>/dev/null); if [ -f "$config_file" ]; then
                    port=$(sudo grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$config_file" | head -n 1 || echo "0"); if [[ "$port" -gt "$max_port" ]]; then max_port=$port; fi
                fi
            fi
        done
    fi
    
    local LISTEN_PORT
    local SUGGESTED_PORT=$((max_port + 1))
    echo
    while true; do
        read -p "❓ Выберите внешний порт (нажмите Enter чтобы использовать '$SUGGESTED_PORT'): " user_port
        LISTEN_PORT=${user_port:-$SUGGESTED_PORT}
        if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1024 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
            echo "❌ Ошибка! Введите корректный номер порта (1024-65535)."; continue
        fi
        if sudo grep -qR --include='wg-*.conf' "^\s*ListenPort\s*=\s*$LISTEN_PORT\s*$" /etc/wireguard/ 2>/dev/null; then
            local conflicting_config=$(sudo grep -lR --include='wg-*.conf' "^\s*ListenPort\s*=\s*$LISTEN_PORT\s*$" /etc/wireguard/ | head -n 1 | xargs dirname | xargs basename)
            echo "❌ Ошибка! Порт $LISTEN_PORT уже используется конфигурацией '$conflicting_config'."; continue
        fi
        break
    done
    
    local WG_SUBNET_V4; get_wg_network WG_SUBNET_V4
    if [ -z "$WG_SUBNET_V4" ]; then echo "❌ Не удалось определить подсеть для WireGuard."; return 1; fi
    local WG_NETWORK_V4_PREFIX; WG_NETWORK_V4_PREFIX=$(echo "$WG_SUBNET_V4" | cut -d'.' -f1-3)

    local ROUTER_COUNT;
    echo
    while true; do read -p "❓ Сколько 📡 роутеров создать для '$CONFIG_NAME'? (0-253): " ROUTER_COUNT
        if [[ "$ROUTER_COUNT" =~ ^[0-9]+$ ]] && [ "$ROUTER_COUNT" -ge 0 ] && [ "$ROUTER_COUNT" -le 253 ]; then break; else echo "❌ Ошибка! Введите число от 0 до 253."; fi
    done
    
    declare -a ROUTER_LAN_SUBNETS
    local chosen_lan_subnets=()
    if [ "$ROUTER_COUNT" -gt 0 ]; then
        for i in $(seq 1 $ROUTER_COUNT); do
            local new_subnet
            get_router_lan_subnet new_subnet "$i" "$WG_SUBNET_V4" "${chosen_lan_subnets[@]}"
            if [ -z "$new_subnet" ]; then echo "❌ Создание отменено из-за ошибки выбора подсети."; return 1; fi
            ROUTER_LAN_SUBNETS[$i]="$new_subnet"
            chosen_lan_subnets+=("$new_subnet")
        done
    fi
    
    local CLIENT_COUNT
    echo
    while true; do read -p "❓ Сколько 📱 клиентов создать для '$CONFIG_NAME'? (0-253): " CLIENT_COUNT
        if [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] && [ "$CLIENT_COUNT" -ge 0 ] && [ "$CLIENT_COUNT" -le 253 ]; then break; else echo "❌ Ошибка! Введите число от 0 до 253."; fi
    done

    if [ $((ROUTER_COUNT + CLIENT_COUNT)) -gt 253 ] || [ $((ROUTER_COUNT + CLIENT_COUNT)) -eq 0 ]; then
        echo "❌ Ошибка! Общее количество роутеров и клиентов должно быть от 1 до 253."; return 1
    fi

    local DNS_SETTINGS; get_dns_settings DNS_SETTINGS "$SERVER_HAS_PUBLIC_IPV6"
    local OBFUSCATION_SETTINGS; get_obfuscation_settings OBFUSCATION_SETTINGS

    local client_allowed_ips
    client_allowed_ips=$(generate_client_allowed_ips_string "$WG_SUBNET_V4" "${ROUTER_LAN_SUBNETS[@]}")

    local SERVER_ADDRESS_LINE="Address = ${WG_NETWORK_V4_PREFIX}.1/24"
    
    local NEW_OCTET_3=$(echo $WG_NETWORK_V4_PREFIX | cut -d'.' -f3)
    local NEW_OCTET_2=$(echo $WG_NETWORK_V4_PREFIX | cut -d'.' -f2)
    local WG_NETWORK_V6=""
    if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
        WG_NETWORK_V6="fd42:42:$(printf '%x' $NEW_OCTET_2):$(printf '%x' $NEW_OCTET_3)::"
        SERVER_ADDRESS_LINE+=", ${WG_NETWORK_V6}1/64"
    fi
    
    echo -e "\n🚀 Запуск конфигурации '$CONFIG_NAME'..."
    
    sudo mkdir -p "$CONFIG_DIR"; sudo chmod 700 "$CONFIG_DIR"
    
    SERVER_PRIVATE=$(wg genkey); SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey)
    
    declare -a ROUTER_PRIVATE_KEYS; declare -a ROUTER_PUBLIC_KEYS; declare -a ROUTER_PSKS
    if [ "$ROUTER_COUNT" -gt 0 ]; then
      for i in $(seq 1 $ROUTER_COUNT); do ROUTER_PRIVATE_KEYS[$i]=$(wg genkey); ROUTER_PUBLIC_KEYS[$i]=$(echo "${ROUTER_PRIVATE_KEYS[$i]}" | wg pubkey); ROUTER_PSKS[$i]=$(wg genpsk); done
    fi

    declare -a CLIENT_PRIVATE_KEYS; declare -a CLIENT_PUBLIC_KEYS; declare -a CLIENT_PSKS
    if [ "$CLIENT_COUNT" -gt 0 ]; then
      for i in $(seq 1 $CLIENT_COUNT); do CLIENT_PRIVATE_KEYS[$i]=$(wg genkey); CLIENT_PUBLIC_KEYS[$i]=$(echo "${CLIENT_PRIVATE_KEYS[$i]}" | wg pubkey); CLIENT_PSKS[$i]=$(wg genpsk); done
    fi
    
    SERVER_CONFIG_FILE_NAME="${WG_INTERFACE}.conf"
    sudo tee "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF
# $CONFIG_NAME (Mode 3)
[Interface]
PrivateKey = $SERVER_PRIVATE
$SERVER_ADDRESS_LINE
ListenPort = $LISTEN_PORT
EOF
    
    local ip_counter=2
    if [ "$ROUTER_COUNT" -gt 0 ]; then
      for i in $(seq 1 $ROUTER_COUNT); do
          local ROUTER_IP_V4="${WG_NETWORK_V4_PREFIX}.$ip_counter"
          local PEER_ALLOWED_IPS="AllowedIPs = ${ROUTER_IP_V4}/32, ${ROUTER_LAN_SUBNETS[$i]}"
          if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
              PEER_ALLOWED_IPS+=", ${WG_NETWORK_V6}$ip_counter/128"
          fi

          sudo tee -a "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF

# Peer: Router $i (LAN: ${ROUTER_LAN_SUBNETS[$i]})
[Peer]
PublicKey = ${ROUTER_PUBLIC_KEYS[$i]}
PresharedKey = ${ROUTER_PSKS[$i]}
$PEER_ALLOWED_IPS
EOF
          ip_counter=$((ip_counter + 1))
      done
    fi
    
    if [ "$CLIENT_COUNT" -gt 0 ]; then
      for i in $(seq 1 $CLIENT_COUNT); do
          local CLIENT_IP_V4="${WG_NETWORK_V4_PREFIX}.$ip_counter"
          local PEER_ALLOWED_IPS="AllowedIPs = ${CLIENT_IP_V4}/32"
          if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
              PEER_ALLOWED_IPS+=", ${WG_NETWORK_V6}$ip_counter/128"
          fi

          sudo tee -a "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" > /dev/null << EOF

# Peer: Client $i
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEYS[$i]}
PresharedKey = ${CLIENT_PSKS[$i]}
$PEER_ALLOWED_IPS
EOF
          ip_counter=$((ip_counter + 1))
      done
    fi
    
    ip_counter=2
    if [ "$ROUTER_COUNT" -gt 0 ]; then
      for i in $(seq 1 $ROUTER_COUNT); do
          local ROUTER_IP_V4="${WG_NETWORK_V4_PREFIX}.$ip_counter"
          local PEER_ADDRESS_LINE="Address = ${ROUTER_IP_V4}/24"
          if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
              PEER_ADDRESS_LINE+=", ${WG_NETWORK_V6}$ip_counter/64"
          fi
          local ROUTER_FILE=$([ $i -eq 1 ] && echo "router.conf" || echo "router${i}.conf")
          # ИСПРАВЛЕНИЕ: AllowedIPs для роутера в режиме 3 теперь изолированы
          local individual_router_allowed_ips="${WG_NETWORK_V4_PREFIX}.0/24, ${ROUTER_LAN_SUBNETS[$i]}"

          {
              echo "# Router $i for $CONFIG_NAME (LAN)"
              echo "[Interface]"
              echo "PrivateKey = ${ROUTER_PRIVATE_KEYS[$i]}"
              echo "$PEER_ADDRESS_LINE"
              if [ -n "$OBFUSCATION_SETTINGS" ]; then printf "%s\n" "$OBFUSCATION_SETTINGS"; fi

              echo ""
              echo "[Peer]"
              echo "PublicKey = $SERVER_PUBLIC"
              echo "PresharedKey = ${ROUTER_PSKS[$i]}"
              echo "Endpoint = $SERVER_IP:$LISTEN_PORT"
              echo "AllowedIPs = $individual_router_allowed_ips"
              echo "PersistentKeepalive = 25"
          } | sudo tee "$CONFIG_DIR/$ROUTER_FILE" > /dev/null

          ip_counter=$((ip_counter + 1))
      done
    fi

    if [ "$CLIENT_COUNT" -gt 0 ]; then
      for i in $(seq 1 $CLIENT_COUNT); do
          local CLIENT_IP_V4="${WG_NETWORK_V4_PREFIX}.$ip_counter"
          local PEER_ADDRESS_LINE="Address = ${CLIENT_IP_V4}/24"
          if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
              PEER_ADDRESS_LINE+=", ${WG_NETWORK_V6}$ip_counter/64"
          fi
          
          local CLIENT_FILE_NAME
          if [ $i -eq 1 ]; then
              CLIENT_FILE_NAME="client.conf"
          else
              CLIENT_FILE_NAME="client${i}.conf"
          fi

          {
              echo "# Client $i for $CONFIG_NAME (LAN)"
              echo "[Interface]"
              echo "PrivateKey = ${CLIENT_PRIVATE_KEYS[$i]}"
              echo "$PEER_ADDRESS_LINE"
              if [ -n "$DNS_SETTINGS" ]; then echo "$DNS_SETTINGS"; fi
              if [ -n "$OBFUSCATION_SETTINGS" ]; then printf "%s\n" "$OBFUSCATION_SETTINGS"; fi
              
              echo ""
              echo "[Peer]"
              echo "PublicKey = $SERVER_PUBLIC"
              echo "PresharedKey = ${CLIENT_PSKS[$i]}"
              echo "Endpoint = $SERVER_IP:$LISTEN_PORT"
              echo "AllowedIPs = $client_allowed_ips"
              echo "PersistentKeepalive = 25"
          } | sudo tee "$CONFIG_DIR/$CLIENT_FILE_NAME" > /dev/null
          
          ip_counter=$((ip_counter + 1))
      done
    fi

    sudo chmod 600 "$CONFIG_DIR"/*; sudo ln -sf "$CONFIG_DIR/$SERVER_CONFIG_FILE_NAME" "/etc/wireguard/$SERVER_CONFIG_FILE_NAME"
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if [[ "$SERVER_HAS_PUBLIC_IPV6" == "true" ]]; then
        sudo sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    fi
    sudo systemctl enable --now "wg-quick@${WG_INTERFACE}"
    
    if verify_tunnel_activation "$WG_INTERFACE"; then
        clear
        show_summary_for_config "$CONFIG_NAME"
        export_configs "$CONFIG_NAME"
    fi
}

# --- ФУНКЦИЯ ДЛЯ СОЗДАНИЯ КОНФИГУРАЦИИ ---
create_config() {
    clear
    local choice
    
    while true; do
        echo "🔎 Выберите схему для новой конфигурации:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "1. 👥 Клиенты ⮂ ☁️  Сервер ⮂ 🌐 Интернет"
        echo "   Для выхода в интернет через сервер."
        echo
        echo "2. 👥 Клиенты ⮂ ☁️  Сервер ⮂ 📡 Роутер(ы) ⮂ 🌐 Интернет + 🏠 LAN"
        echo "   Для выхода в интернет через один роутер и доступу в локальные сети всех роутеров."
        echo
        echo "3. 👥 Клиенты ⮂ ☁️  Сервер ⮂ 📡 Роутер(ы) ⮂ 🏠 LAN"
        echo "   Для доступа в локальные сети всех роутеров."
        echo
        echo "4. Назад"
        echo
        read -p "-> " choice
        case $choice in
            1 | 2 | 3) break ;;
            4) echo; return ;;
            *) echo "❌ Неверный выбор"; echo;;
        esac
    done

    echo
    local CONFIG_NAME
    while true; do
        read -p "❓ Выберите имя для новой конфигурации (только английские буквы, цифры или символы): " CONFIG_NAME
        if [[ ! "$CONFIG_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then 
            echo "❌ Ошибка! Недопустимое имя... Пожалуйста, используйте только a-z, A-Z, 0-9, _ или -"
            continue
        fi
        if [ -d "/etc/wireguard/$CONFIG_NAME" ]; then 
            echo "❌ Ошибка: Конфигурация '$CONFIG_NAME' уже существует. Выберите другое имя."
            continue
        fi
        if [ -z "$CONFIG_NAME" ]; then
            echo "❌ Ошибка! Имя не может быть пустым."
            continue
        fi
        break
    done
    
    if [ "$choice" -eq 1 ]; then
        run_creation_flow_mode1 "$CONFIG_NAME"
    elif [ "$choice" -eq 2 ]; then
        run_creation_flow_mode2 "$CONFIG_NAME"
    else
        run_creation_flow_mode3 "$CONFIG_NAME"
    fi
}

# --- ОБЩАЯ ФУНКЦИЯ ДЛЯ ПРИМЕНЕНИЯ ОЧИСТКИ ---
apply_deep_clean() {
    local configs_to_process=("$@")
    if [ ${#configs_to_process[@]} -eq 0 ]; then return; fi

    for conf_name in "${configs_to_process[@]}"; do deep_clean_config "$conf_name"; done
    
    echo -e "\n🔄 Перезагрузка конфигурации systemd..."; sudo systemctl daemon-reload; sudo systemctl reset-failed
    echo "✅ Готово!"; pause_and_wait
}

# --- ФУНКЦИЯ ОСТАНОВКИ ОДНОЙ ИЛИ НЕСКОЛЬКИХ КОНФИГУРАЦИЙ ---
stop_specific_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
    local running_configs=(); for conf_name in "${all_configs[@]}"; do if is_config_truly_active "$conf_name"; then running_configs+=("$conf_name"); fi; done
    if [ ${#running_configs[@]} -eq 0 ]; then echo "⚙️  Нет работающих конфигураций для остановки."; pause_and_wait; return; fi

    echo "⚙️  Работающие конфигурации:"
    for i in "${!running_configs[@]}"; do 
        local conf_name="${running_configs[$i]}"
        echo "🟢 $((i+1)). $conf_name"
    done;
    echo;

    read -p "❓ Введите числа для остановки (через пробел, если несколько): " -a choices
    if [ ${#choices[@]} -eq 0 ]; then echo "⚙️  Не выбрано ни одной конфигурации."; return; fi

    echo "✅ Команды на остановку отправлены!";

    local configs_to_stop=()
    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#running_configs[@]}" ]; then
            configs_to_stop+=("${running_configs[$((choice-1))]}")
        else echo "⚠️  Предупреждение: Неверное число '$choice'."; fi
    done
    if [ ${#configs_to_stop[@]} -eq 0 ]; then echo "⚙️  Не выбрано корректных конфигураций."; return; fi

    echo "⚙️  Выбрано для остановки: ${configs_to_stop[*]}"
    for conf_name in "${configs_to_stop[@]}"; do
        sudo systemctl disable --now "wg-quick@wg-$conf_name" &>/dev/null || true
    done;
    pause_and_wait
}

# --- ФУНКЦИЯ ОСТАНОВКИ ВСЕХ КОНФИГУРАЦИЙ ---
stop_all_running_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true)
    local running_configs=(); for conf_name in "${all_configs[@]}"; do if is_config_truly_active "$conf_name"; then running_configs+=("$conf_name"); fi; done
    if [ ${#running_configs[@]} -eq 0 ]; then echo "⚙️  Нет работающих конфигураций для остановки."; pause_and_wait; return; fi

    for conf in "${running_configs[@]}"; do sudo systemctl disable --now "wg-quick@wg-$conf" &>/dev/null || true; done
    echo "✅ Команды на полную остановку отправлены.";
    pause_and_wait
}

# --- НАЧАЛО БЛОКА ФУНКЦИЙ ИЗМЕНЕНИЯ ---

# Функция получения Endpoint сервера (IP:Port) из конфигурационного файла WireGuard
get_server_endpoint() {
    local SERVER_CONFIG_PATH=$1
    local LISTEN_PORT
    LISTEN_PORT=$(sudo grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$SERVER_CONFIG_PATH" 2>/dev/null)
    if [ -z "$LISTEN_PORT" ]; then
        echo "error:no_port"
        return 1
    fi

    local SERVER_IP
    SERVER_IP=$(get_server_public_ip)
    if [ "$SERVER_IP" == "error" ]; then
        echo "error:no_ip"
        return 1
    fi

    echo "$SERVER_IP:$LISTEN_PORT"
    return 0
}

# Функция поиска следующей доступной подсети 192.168.X.0/24
get_next_available_subnet() {
    local SERVER_CONFIG_PATH=$1
    local used_octets

    mapfile -t used_octets < <(sudo grep -oP '192\.168\.\K[0-9]+(?=\.0/24)' "$SERVER_CONFIG_PATH" | sort -n)

    for i in {1..254}; do
        local found=false
        for octet in "${used_octets[@]}"; do
            if [[ "$i" -eq "$octet" ]]; then
                found=true
                break
            fi
        done
        if ! $found; then
            echo "192.168.${i}.0/24"
            return 0
        fi
    done

    echo ""
    return 1
}

# Вспомогательная функция для обработки блока peer при пересоздании ключей
process_recreate_peer_block_inline() {
    local peer_block="$1"
    local peer_pubkey="$2"
    local PEER_TYPE="$3"
    shift 3
    local all_peer_files=("$@")

    local matching_peer_file=""
    local current_peer_type="client"

    for peer_path in "${all_peer_files[@]}"; do
        local file_privkey
        file_privkey=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$peer_path" 2>/dev/null)
        if [[ -z "$file_privkey" ]]; then continue; fi

        local file_pubkey
        file_pubkey=$(echo "$file_privkey" | wg pubkey 2>/dev/null)

        if [[ "$file_pubkey" == "$peer_pubkey" ]]; then
            matching_peer_file="$peer_path"
            if [[ "$(basename "$peer_path")" == router* ]]; then
                current_peer_type="router"
            fi
            break
        fi
    done

    if [[ ("$current_peer_type" == "$PEER_TYPE" || "$PEER_TYPE" == "all") && -n "$matching_peer_file" ]]; then
        local OLD_PEER_CONFIG
        OLD_PEER_CONFIG=$(sudo cat "$matching_peer_file")

        local PEER_ADDRESS
        PEER_ADDRESS=$(echo "$OLD_PEER_CONFIG" | grep -oP 'Address\s*=\s*\K.*')
        local PEER_ALLOWED_IPS
        PEER_ALLOWED_IPS=$(echo "$OLD_PEER_CONFIG" | grep -oP 'AllowedIPs\s*=\s*\K.*')
        local PEER_DNS
        PEER_DNS=$(echo "$OLD_PEER_CONFIG" | grep -oP 'DNS\s*=\s*\K.*')
        local PEER_OBFS
        PEER_OBFS=$(echo "$OLD_PEER_CONFIG" | grep -E '^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)\s*=.*')


        local NEW_PEER_PRIVATE NEW_PEER_PUBLIC NEW_PSK
        NEW_PEER_PRIVATE=$(wg genkey)
        NEW_PEER_PUBLIC=$(echo "$NEW_PEER_PRIVATE" | wg pubkey)
        NEW_PSK=$(wg genpsk)

        local peer_comment
        peer_comment=$(echo "$OLD_PEER_CONFIG" | head -n 1)

        local config_name
        config_name=$(basename "$(dirname "$matching_peer_file")")
        local SERVER_CONFIG_PATH
        SERVER_CONFIG_PATH=$(sudo find "/etc/wireguard/$config_name" -name "wg-*.conf" -print -quit 2>/dev/null)
        local SERVER_PRIVATE_KEY
        SERVER_PRIVATE_KEY=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$SERVER_CONFIG_PATH")
        local SERVER_PUBLIC_KEY
        SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
        local ENDPOINT
        ENDPOINT=$(get_server_endpoint "$SERVER_CONFIG_PATH")

        {
            echo "$peer_comment"
            echo "[Interface]"
            echo "PrivateKey = $NEW_PEER_PRIVATE"
            echo "Address = $PEER_ADDRESS"
            # DNS добавляем только если это клиент
            if [[ -n "$PEER_DNS" && "$current_peer_type" == "client" ]]; then echo "DNS = $PEER_DNS"; fi
            if [ -n "$PEER_OBFS" ]; then echo "$PEER_OBFS"; fi
            echo ""
            echo "[Peer]"
            echo "PublicKey = $SERVER_PUBLIC_KEY"
            echo "PresharedKey = $NEW_PSK"
            echo "Endpoint = $ENDPOINT"
            echo "AllowedIPs = $PEER_ALLOWED_IPS"
            echo "PersistentKeepalive = 25"
        } | sudo tee "$matching_peer_file" > /dev/null


        echo "$peer_block" | while IFS= read -r line; do
            if [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]* ]]; then
                echo "PublicKey = $NEW_PEER_PUBLIC"
            elif [[ "$line" =~ ^PresharedKey[[:space:]]*=[[:space:]]* ]]; then
                echo "PresharedKey = $NEW_PSK"
            else
                echo "$line"
            fi
        done
    else
        echo "$peer_block"
    fi
}

# Основная функция пересоздания ключей для указанного типа пиров
recreate_peer_keys() {
    local CONFIG_NAME=$1
    local PEER_TYPE=$2
    local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"
    local WG_INTERFACE="wg-$CONFIG_NAME"
    local SERVER_CONFIG_PATH

    SERVER_CONFIG_PATH=$(sudo find "$CONFIG_DIR" -name "wg-*.conf" -print -quit 2>/dev/null)
    if [ -z "$SERVER_CONFIG_PATH" ]; then echo "❌ Ошибка: конфигурационный файл сервера не найден"; return 1; fi

    echo "🔧 Пересоздание ключей для ($PEER_TYPE)..."

    local was_active=false
    if sudo wg show "$WG_INTERFACE" &>/dev/null; then
        was_active=true; echo "   - Остановка сервиса ${WG_INTERFACE}..."; sudo wg-quick down "$WG_INTERFACE" &>/dev/null
    fi

    local SERVER_PRIVATE_KEY
    SERVER_PRIVATE_KEY=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$SERVER_CONFIG_PATH")
    local SERVER_PUBLIC_KEY
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

    local ENDPOINT
    ENDPOINT=$(get_server_endpoint "$SERVER_CONFIG_PATH")
    if [[ "$ENDPOINT" == error* ]]; then
        echo "❌ Ошибка получения Endpoint: $ENDPOINT"
        if $was_active; then sudo wg-quick up "$WG_INTERFACE" &>/dev/null; fi
        return 1
    fi

    local all_peer_files=()
    while IFS= read -r -d '' file; do all_peer_files+=("$file"); done < <(sudo find "$CONFIG_DIR" \( -name "client*.conf" -o -name "router*.conf" \) -type f -print0 2>/dev/null | sort -zV)

    local TEMP_FILE; TEMP_FILE=$(mktemp)

    local in_peer_block=false
    local current_peer_block=""
    local current_peer_pubkey=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\] ]]; then
            if [ "$in_peer_block" = true ] && [ -n "$current_peer_block" ]; then
                process_recreate_peer_block_inline "$current_peer_block" "$current_peer_pubkey" "$PEER_TYPE" "${all_peer_files[@]}" >> "$TEMP_FILE"
            fi
            in_peer_block=true; current_peer_block="$line"; current_peer_pubkey=""
        elif [[ "$line" =~ ^\[Interface\] ]]; then
            if [ "$in_peer_block" = true ] && [ -n "$current_peer_block" ]; then
                process_recreate_peer_block_inline "$current_peer_block" "$current_peer_pubkey" "$PEER_TYPE" "${all_peer_files[@]}" >> "$TEMP_FILE"; current_peer_block=""
            fi
            in_peer_block=false; echo "$line" >> "$TEMP_FILE"
        elif [ "$in_peer_block" = true ]; then
            current_peer_block+=$'\n'"$line"
            if [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]]; then current_peer_pubkey="${BASH_REMATCH[1]}"; fi
        else
            echo "$line" >> "$TEMP_FILE"
        fi
    done < <(sudo cat "$SERVER_CONFIG_PATH")

    if [ "$in_peer_block" = true ] && [ -n "$current_peer_block" ]; then
        process_recreate_peer_block_inline "$current_peer_block" "$current_peer_pubkey" "$PEER_TYPE" "${all_peer_files[@]}" >> "$TEMP_FILE"
    fi

    local CLEANED_CONFIG; CLEANED_CONFIG=$(mktemp)
    sudo awk 'NF > 0 {if (blanks) print ""; print; blanks=0; next} {blanks=1}' "$TEMP_FILE" > "$CLEANED_CONFIG"
    sudo cp "$CLEANED_CONFIG" "$SERVER_CONFIG_PATH"
    rm "$TEMP_FILE" "$CLEANED_CONFIG"

    if $was_active; then
        echo "   - Запуск сервиса ${WG_INTERFACE}...";
        if sudo wg-quick up "$WG_INTERFACE" &>/dev/null; then
            echo "   - Интерфейс успешно запущен"; verify_tunnel_activation "$WG_INTERFACE"
        else
            echo "⚠️  Предупреждение: не удалось запустить интерфейс"
        fi
    fi

    echo "✅ Ключи для ($PEER_TYPE) в '$CONFIG_NAME' были успешно пересозданы."; echo "⚠️  НЕ ЗАБУДЬТЕ обновить файлы конфигурации у всех соответствующих пиров!"
    if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 0
}

# Функция-обертка для пересоздания ключей с подтверждением
edit_recreate_keys_flow() {
    local CONFIG_NAME=$1; local PEER_TYPE=$2; local type_description=""
    case "$PEER_TYPE" in
        "all")    type_description="ВСЕ ключи для ВСЕХ пиров" ;;
        "router") type_description="ключи ТОЛЬКО для роутеров" ;;
        "client") type_description="ключи ТОЛЬКО для клиентов" ;;
        *) echo "❌ Внутренняя ошибка: неизвестный тип пира '$PEER_TYPE'"; return 1 ;;
    esac
    echo; echo "⚠️  ВНИМАНИЕ! Это действие пересоздаст $type_description."; echo
    read -p "❓ Продолжить? (1 - да, 2 - нет): " confirm
    if [[ "$confirm" != "1" ]]; then echo "⚙️  Отменено."; return 1; fi
    recreate_peer_keys "$CONFIG_NAME" "$PEER_TYPE"; return $?
}

# Функция смены роутера-шлюза для выхода в интернет
edit_change_gateway() {
    local CONFIG_NAME=$1; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local WG_INTERFACE="wg-$CONFIG_NAME"; local SERVER_CONFIG_PATH
    SERVER_CONFIG_PATH=$(sudo find "$CONFIG_DIR" -name "wg-*.conf" -print -quit 2>/dev/null)
    if [ -z "$SERVER_CONFIG_PATH" ]; then echo "❌ Ошибка: конфигурационный файл сервера не найден"; return 1; fi

    local current_gateway_pubkey; current_gateway_pubkey=$(sudo awk 'BEGIN{RS="\n\n"} /\[Peer\]/ && /0\.0\.0\.0\/0/ { match($0, /PublicKey = ([^\n]+)/, arr); if (arr[1]) print arr[1] }' "$SERVER_CONFIG_PATH" | head -1)

    local router_files=(); while IFS= read -r -d '' file; do router_files+=("$file"); done < <(sudo find "$CONFIG_DIR" -name "router*.conf" -type f -print0 2>/dev/null | sort -zV)
    if [ ${#router_files[@]} -lt 2 ]; then echo "⚙️  Нет других роутеров для выбора в качестве источника интернета."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 1; fi

    echo; echo "🔎 Выберите новый роутер в качестве источника интернета для '$CONFIG_NAME':"
    for i in "${!router_files[@]}"; do
        local router_path="${router_files[$i]}"; local router_privkey; router_privkey=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$router_path")
        local router_pubkey; router_pubkey=$(echo "$router_privkey" | wg pubkey 2>/dev/null); local router_name; router_name=$(basename "$router_path")
        if [[ "$router_pubkey" == "$current_gateway_pubkey" ]]; then echo "   $((i+1))) $router_name [🌐 текущий шлюз]"; else echo "   $((i+1))) $router_name"; fi
    done; echo

    local choice; read -p "-> " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#router_files[@]}" ]; then echo "❌ Неверный выбор."; return 1; fi

    local new_gateway_path="${router_files[$((choice-1))]}"; local new_gateway_privkey; new_gateway_privkey=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$new_gateway_path")
    if [ -z "$new_gateway_privkey" ]; then echo "❌ Ошибка: не найден приватный ключ роутера"; return 1; fi

    local new_gateway_pubkey; new_gateway_pubkey=$(echo "$new_gateway_privkey" | wg pubkey)
    if [[ "$new_gateway_pubkey" == "$current_gateway_pubkey" ]]; then echo "⚙️  Выбранный роутер уже является текущим шлюзом."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 0; fi

    echo "🔧 Смена роутера на $(basename "$new_gateway_path")..."

    local was_active=false
    if sudo wg show "$WG_INTERFACE" &>/dev/null; then was_active=true; echo "   - Остановка сервиса ${WG_INTERFACE}..."; sudo wg-quick down "$WG_INTERFACE" &>/dev/null; fi

    sudo sed -i 's/, 0\.0\.0\.0\/0, ::\/0//g; s/0\.0\.0\.0\/0, ::\/0, \?//g; s/, 0\.0\.0\.0\/0//g; s/, ::\/0//g' "$SERVER_CONFIG_PATH"

    local TEMP_FILE; TEMP_FILE=$(mktemp)
    local in_target_peer=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\] ]]; then in_target_peer=false;
        elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.+) ]] && [[ "${BASH_REMATCH[1]}" == "$new_gateway_pubkey" ]]; then in_target_peer=true;
        elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.+) ]] && [[ "$in_target_peer" == true ]]; then
            local allowed_ips="${BASH_REMATCH[1]}"; if [[ ! "$allowed_ips" =~ 0\.0\.0\.0/0 ]]; then line="AllowedIPs = $allowed_ips, 0.0.0.0/0, ::/0"; fi
        fi; echo "$line" >> "$TEMP_FILE"
    done < <(sudo cat "$SERVER_CONFIG_PATH")

    local CLEANED_CONFIG; CLEANED_CONFIG=$(mktemp)
    sudo awk 'NF > 0 {if (blanks) print ""; print; blanks=0; next} {blanks=1}' "$TEMP_FILE" > "$CLEANED_CONFIG"
    sudo cp "$CLEANED_CONFIG" "$SERVER_CONFIG_PATH"; rm "$TEMP_FILE" "$CLEANED_CONFIG"

    if $was_active; then
        echo "   - Запуск сервиса ${WG_INTERFACE}...";
        if sudo wg-quick up "$WG_INTERFACE" &>/dev/null; then echo "   - Интерфейс успешно запущен"; verify_tunnel_activation "$WG_INTERFACE";
        else echo "⚠️  Предупреждение: не удалось запустить интерфейс"; fi
    else echo "   - Конфигурация изменена. Сервис не был запущен, поэтому остается остановленным."; fi

    echo "✅ Шлюз для '$CONFIG_NAME' успешно изменен."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 0
}

# Функция добавления новых пиров указанного типа
edit_add_peers() {
    local CONFIG_NAME=$1; local PEER_TYPE=$2; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local SERVER_CONFIG_PATH
    SERVER_CONFIG_PATH=$(sudo find "$CONFIG_DIR" -name "wg-*.conf" -print -quit 2>/dev/null)
    if [ -z "$SERVER_CONFIG_PATH" ]; then echo "❌ Ошибка: конфигурационный файл сервера не найден"; return 1; fi
    
    local config_mode; config_mode=$(get_config_mode "$CONFIG_NAME")
    local has_ipv6="false"; if sudo grep -q "fd42:42:" "$SERVER_CONFIG_PATH"; then has_ipv6="true"; fi

    local all_peer_files=(); while IFS= read -r -d '' file; do all_peer_files+=("$file"); done < <(sudo find "$CONFIG_DIR" \( -name "client*.conf" -o -name "router*.conf" \) -type f -print0 2>/dev/null)
    local remaining_slots=$((253 - ${#all_peer_files[@]})); if [ "$remaining_slots" -le 0 ]; then echo "⚙️  Достигнут максимальный лимит пиров (253)."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 1; fi

    # Определяем русские названия для типов пиров
    local peer_type_russian
    local peer_type_genitive
    case "$PEER_TYPE" in
        "client")
            peer_type_russian="клиентов"
            peer_type_genitive="клиентов"
            ;;
        "router")
            peer_type_russian="роутеров"
            peer_type_genitive="роутеров"
            ;;
        *)
            peer_type_russian="${PEER_TYPE}ов"
            peer_type_genitive="${PEER_TYPE}ов"
            ;;
    esac

    local new_peer_count; while true; do read -p "❓ Сколько НОВЫХ $peer_type_genitive вы хотите добавить? (1-$remaining_slots, или Enter для отмены): " new_peer_count
        if [ -z "$new_peer_count" ]; then echo "⚙️  Отмена."; return 1; fi
        if [[ "$new_peer_count" =~ ^[0-9]+$ ]] && [ "$new_peer_count" -ge 1 ] && [ "$new_peer_count" -le "$remaining_slots" ]; then break; else echo "❌ Ошибка! Введите число от 1 до $remaining_slots."; fi; done
    
    local DNS_SETTINGS=""; if [[ "$PEER_TYPE" == "client" ]]; then get_dns_settings DNS_SETTINGS "$has_ipv6"; fi
    local OBFUSCATION_SETTINGS=""; get_obfuscation_settings OBFUSCATION_SETTINGS

    echo "🔧 Добавление..."; local WG_INTERFACE="wg-$CONFIG_NAME"
    local was_active=false; if sudo wg show "$WG_INTERFACE" &>/dev/null; then was_active=true; sudo wg-quick down "$WG_INTERFACE" &>/dev/null; fi

    local ENDPOINT; ENDPOINT=$(get_server_endpoint "$SERVER_CONFIG_PATH")
    if [[ "$ENDPOINT" == error* ]]; then echo "❌ Ошибка получения Endpoint: $ENDPOINT"; if $was_active; then sudo wg-quick up "$WG_INTERFACE" &>/dev/null; fi; return 1; fi

    local SERVER_PRIVATE_KEY; SERVER_PRIVATE_KEY=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$SERVER_CONFIG_PATH")
    local SERVER_PUBLIC_KEY; SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    local WG_SUBNET_V4; WG_SUBNET_V4=$(sudo grep -oP 'Address\s*=\s*\K[0-9]+\.[0-9]+\.[0-9]+\.1\/24' "$SERVER_CONFIG_PATH" | sed 's/\.1\/24$/.0\/24/')
    local WG_NETWORK_V4_PREFIX; WG_NETWORK_V4_PREFIX=$(echo "$WG_SUBNET_V4" | cut -d'.' -f1-3)
    local WG_NETWORK_V6_PREFIX; if $has_ipv6; then WG_NETWORK_V6_PREFIX=$(sudo grep -oP 'Address\s*=\s*\Kfd42:42:[0-9a-f:]+' "$SERVER_CONFIG_PATH" | head -1); fi

    mapfile -t used_ip_octets < <(sudo grep "AllowedIPs" "$SERVER_CONFIG_PATH" | grep -oP '\.([0-9]+)/' | tr -d './' | sort -n)
    mapfile -t existing_lan_subnets < <(sudo grep "LAN:" "$SERVER_CONFIG_PATH" | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/24')
    
    local new_peers_blocks=()
    local newly_added_lan_subnets=()

    for i in $(seq 1 $new_peer_count); do
        local next_peer_num; local peer_file_path
        if [ ! -f "$CONFIG_DIR/${PEER_TYPE}.conf" ]; then
            next_peer_num=1; peer_file_path="$CONFIG_DIR/${PEER_TYPE}.conf"
        else
            for num in {2..254}; do
                if [ ! -f "$CONFIG_DIR/${PEER_TYPE}${num}.conf" ]; then
                    next_peer_num=$num; peer_file_path="$CONFIG_DIR/${PEER_TYPE}${num}.conf"; break
                fi; done; fi
        if [ -z "$peer_file_path" ]; then echo "❌ Не удалось найти свободный номер/имя файла для нового пира."; break; fi

        local next_ip_octet; for octet in {2..254}; do local is_used=false; for used_octet in "${used_ip_octets[@]}"; do if [[ "$octet" == "$used_octet" ]]; then is_used=true; break; fi; done; if ! $is_used; then next_ip_octet=$octet; break; fi; done
        if [ -z "$next_ip_octet" ]; then echo "❌ Не удалось найти свободный IP-адрес для нового пира."; break; fi
        used_ip_octets+=("$next_ip_octet") 

        local PEER_IP_V4="${WG_NETWORK_V4_PREFIX}.${next_ip_octet}"
        local PEER_IP_V6=""; if $has_ipv6; then PEER_IP_V6="${WG_NETWORK_V6_PREFIX}${next_ip_octet}"; fi
        local PEER_PRIVKEY PEER_PUBKEY PEER_PSK; PEER_PRIVKEY=$(wg genkey); PEER_PUBKEY=$(echo "$PEER_PRIVKEY" | wg pubkey); PEER_PSK=$(wg genpsk)
        
        local PEER_ALLOWED_IPS_ON_SERVER="$PEER_IP_V4/32"; if [ -n "$PEER_IP_V6" ]; then PEER_ALLOWED_IPS_ON_SERVER+=", $PEER_IP_V6/128"; fi
        
        local peer_comment_for_file="# ${PEER_TYPE^} $next_peer_num for $CONFIG_NAME"
        local server_peer_comment="# Peer: ${PEER_TYPE^} $next_peer_num"
        local peer_address="$PEER_IP_V4/24"; if [ -n "$PEER_IP_V6" ]; then peer_address+=", $PEER_IP_V6/64"; fi
        local new_lan_subnet=""
        
        if [[ "$PEER_TYPE" == "router" ]] && [[ "$config_mode" != *"[Сервер]"* ]]; then
            get_router_lan_subnet new_lan_subnet "$next_peer_num" "$WG_SUBNET_V4" "${existing_lan_subnets[@]}" "${newly_added_lan_subnets[@]}"
            if [ -z "$new_lan_subnet" ]; then echo "❌ Создание отменено из-за ошибки выбора подсети."; break; fi
            newly_added_lan_subnets+=("$new_lan_subnet")
            PEER_ALLOWED_IPS_ON_SERVER+=", $new_lan_subnet"
            local lan_comment_part=" (LAN: $new_lan_subnet)"
            peer_comment_for_file+="$lan_comment_part"; server_peer_comment+="$lan_comment_part"
        fi
        
        {
            echo "$peer_comment_for_file"; echo "[Interface]"; echo "PrivateKey = $PEER_PRIVKEY"; echo "Address = $peer_address"
            if [[ "$PEER_TYPE" == "client" && -n "$DNS_SETTINGS" ]]; then echo "$DNS_SETTINGS"; fi
            if [ -n "$OBFUSCATION_SETTINGS" ]; then printf "%s\n" "$OBFUSCATION_SETTINGS"; fi
            echo ""; echo "[Peer]"; echo "PublicKey = $SERVER_PUBLIC_KEY"; echo "PresharedKey = $PEER_PSK"; echo "Endpoint = $ENDPOINT"
            
            local peer_file_allowed_ips
            if [[ "$PEER_TYPE" == "client" ]]; then
                if [[ "$config_mode" == *"[LAN]"* ]]; then # Режим 3
                    peer_file_allowed_ips=$(generate_client_allowed_ips_string "$WG_SUBNET_V4" "${existing_lan_subnets[@]}" "$new_lan_subnet")
                else # Режим 1 и 2
                    peer_file_allowed_ips="0.0.0.0/0, ::/0"
                fi
            else # Для роутеров
                if [[ "$config_mode" == *"[Роутер]"* ]]; then # Режим 2
                    peer_file_allowed_ips="$WG_SUBNET_V4, 0.0.0.0/0, ::/0"
                else # Режим 3
                    peer_file_allowed_ips="$WG_SUBNET_V4, $new_lan_subnet"
                fi
            fi
            echo "AllowedIPs = $peer_file_allowed_ips"
            echo "PersistentKeepalive = 25"
        } | sudo tee "$peer_file_path" > /dev/null

        local block; block=$(cat <<EOF
$server_peer_comment
[Peer]
PublicKey = $PEER_PUBKEY
PresharedKey = $PEER_PSK
AllowedIPs = $PEER_ALLOWED_IPS_ON_SERVER
PersistentKeepalive = 25
EOF
)
        new_peers_blocks+=("$block"); sudo chmod 600 "$peer_file_path"
    done

    if [ ${#new_peers_blocks[@]} -eq 0 ]; then echo "⚙️  Не было добавлено ни одного пира."; if $was_active; then sudo wg-quick up "$WG_INTERFACE" &>/dev/null; fi; return; fi

    local final_lan_subnets=("${existing_lan_subnets[@]}" "${newly_added_lan_subnets[@]}")
    if [[ "$config_mode" != *"[Сервер]"* ]] && [ ${#final_lan_subnets[@]} -gt 0 ]; then
        local client_final_allowed_ips=$(generate_client_allowed_ips_string "$WG_SUBNET_V4" "${final_lan_subnets[@]}")
        
        for peer_file in "$CONFIG_DIR"/{router,client}*.conf; do
            if [ ! -f "$peer_file" ]; then continue; fi
            
            if [[ "$(basename "$peer_file")" == client* ]]; then
                 if [[ "$config_mode" == *"[Роутер]"* ]]; then # Режим 2
                    sudo sed -i "s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::/0|" "$peer_file"
                 else # Режим 3
                    sudo sed -i "s|^AllowedIPs = .*|AllowedIPs = $client_final_allowed_ips|" "$peer_file"
                 fi
            elif [[ "$(basename "$peer_file")" == router* ]]; then
                local router_lan; router_lan=$(grep "# Router" "$peer_file" | grep -oP '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/24')
                local router_final_allowed_ips
                if [[ "$config_mode" == *"[Роутер]"* ]]; then # Режим 2
                    router_final_allowed_ips="$WG_SUBNET_V4, 0.0.0.0/0, ::/0"
                else # Режим 3
                    router_final_allowed_ips="$WG_SUBNET_V4, $router_lan"
                fi
                sudo sed -i "s|^AllowedIPs = .*|AllowedIPs = $router_final_allowed_ips|" "$peer_file"
            fi
        done
    fi

    local TEMP_CONFIG; TEMP_CONFIG=$(mktemp); sudo sed -n '1,/^$/p' "$SERVER_CONFIG_PATH" > "$TEMP_CONFIG"
    local router_blocks=(); local client_blocks=(); while IFS= read -r -d '' peer_block; do if [[ -z "$peer_block" || "$peer_block" == $'\n' ]]; then continue; fi; if [[ "$peer_block" =~ Peer:[[:space:]]+Router ]]; then router_blocks+=("$peer_block"); elif [[ "$peer_block" =~ Peer:[[:space:]]+Client ]]; then client_blocks+=("$peer_block"); fi; done < <(sudo awk 'BEGIN{RS="\n\n"; ORS="\0"} /^# Peer:/{print}' "$SERVER_CONFIG_PATH")
    
    if [[ "$PEER_TYPE" == "router" ]]; then
        router_blocks+=("${new_peers_blocks[@]}")
    else
        client_blocks+=("${new_peers_blocks[@]}")
    fi

    all_peer_blocks=("${router_blocks[@]}" "${client_blocks[@]}")
    for block in "${all_peer_blocks[@]}"; do printf "\n\n%s" "$block" >> "$TEMP_CONFIG"; done

    local CLEANED_CONFIG; CLEANED_CONFIG=$(mktemp)
    sudo awk 'NF > 0 {if (blanks) print ""; print; blanks=0; next} {blanks=1}' "$TEMP_CONFIG" > "$CLEANED_CONFIG"
    sudo cp "$CLEANED_CONFIG" "$SERVER_CONFIG_PATH"; rm "$TEMP_CONFIG" "$CLEANED_CONFIG"

    if $was_active; then sudo wg-quick up "$WG_INTERFACE" &>/dev/null; verify_tunnel_activation "$WG_INTERFACE"; fi
    echo "✅ Успешно добавлено $new_peer_count новых пиров типа '$PEER_TYPE'."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 0
}

# Функция удаления выбранных пиров указанного типа
edit_delete_peers() {
    local CONFIG_NAME=$1; local PEER_TYPE=$2; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local SERVER_CONFIG_PATH
    SERVER_CONFIG_PATH=$(sudo find "$CONFIG_DIR" -name "wg-*.conf" -print -quit 2>/dev/null)
    if [ -z "$SERVER_CONFIG_PATH" ]; then echo "❌ Ошибка: конфигурационный файл сервера не найден"; return 1; fi

    local deletable_peers=(); while IFS= read -r -d '' file; do deletable_peers+=("$file"); done < <(sudo find "$CONFIG_DIR" -name "${PEER_TYPE}*.conf" -type f -print0 2>/dev/null | sort -zV)
    if [ ${#deletable_peers[@]} -eq 0 ]; then echo "⚙️  Нет пиров типа '$PEER_TYPE' для удаления."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 1; fi
    
    local current_gateway_pubkey=""; if [[ "$PEER_TYPE" == "router" ]]; then current_gateway_pubkey=$(sudo awk 'BEGIN{RS="\n\n"} /\[Peer\]/ && /0\.0\.0\.0\/0/ {match($0, /PublicKey = ([^\n]+)/, arr); if (arr[1]) print arr[1]}' "$SERVER_CONFIG_PATH" | head -1); fi

    local peers_to_delete=(); local pubkeys_to_delete=()
    while true; do
        echo; echo "👥 Выберите, кого удалить из '$CONFIG_NAME':"
        for i in "${!deletable_peers[@]}"; do
            local peer_file_path="${deletable_peers[$i]}"; local display_name=$(basename "$peer_file_path"); local suffix=""
            if [[ "$PEER_TYPE" == "router" && -n "$current_gateway_pubkey" ]]; then
                local peer_privkey=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$peer_file_path" 2>/dev/null); if [ -n "$peer_privkey" ] && [[ "$(echo "$peer_privkey" | wg pubkey 2>/dev/null)" == "$current_gateway_pubkey" ]]; then suffix=" [🌐 текущий шлюз]"; fi
            fi; echo "   $((i+1))) $display_name$suffix"
        done; echo

        read -p "❓ Введите номера для удаления (через пробел, или Enter для отмены): " -a choices
        if [ ${#choices[@]} -eq 0 ]; then echo "⚙️  Отмена."; return 1; fi

        peers_to_delete=(); pubkeys_to_delete=(); local selection_is_valid=true
        for choice in "${choices[@]}"; do
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#deletable_peers[@]}" ]; then echo "⚠️  Предупреждение: Неверное число '$choice'."; selection_is_valid=false; break; fi
            local peer_file_path="${deletable_peers[$((choice-1))]}"; local peer_privkey=$(sudo grep -oP 'PrivateKey\s*=\s*\K.*' "$peer_file_path" 2>/dev/null); if [ -z "$peer_privkey" ]; then continue; fi
            local pubkey=$(echo "$peer_privkey" | wg pubkey 2>/dev/null); if [ -z "$pubkey" ]; then continue; fi
            if [[ "$PEER_TYPE" == "router" && "$pubkey" == "$current_gateway_pubkey" ]]; then echo "⚠️  Предупреждение: Нельзя удалить роутер $(basename "$peer_file_path"), так как он является текущим шлюзом."; selection_is_valid=false; break; fi
            peers_to_delete+=("$peer_file_path"); pubkeys_to_delete+=("$pubkey")
        done

        if ! $selection_is_valid; then echo "❌ Ваш выбор содержит ошибки. Пожалуйста, попробуйте снова."; continue; fi
        if [ ${#peers_to_delete[@]} -ge ${#deletable_peers[@]} ]; then echo "❌ Ошибка: Нельзя удалить всех пиров типа '$PEER_TYPE'."; echo "❌ Пожалуйста, попробуйте снова."; continue; fi
        if [ ${#peers_to_delete[@]} -gt 0 ]; then break; fi
    done
    
    read -p "❓ Вы уверены, что хотите удалить выбранных пиров? (1 - да, 2 - нет): " confirm
    if [[ "$confirm" != "1" ]]; then echo "⚙️  Отменено."; return 1; fi

    local WG_INTERFACE="wg-$CONFIG_NAME"; local was_active=false
    if sudo wg show "$WG_INTERFACE" &>/dev/null; then was_active=true; sudo wg-quick down "$WG_INTERFACE" &>/dev/null; fi

    local TEMP_CONFIG; TEMP_CONFIG=$(mktemp); sudo sed -n '1,/^$/p' "$SERVER_CONFIG_PATH" > "$TEMP_CONFIG"
    
    while IFS= read -r -d '' peer_block; do
        if [[ -z "$peer_block" || "$peer_block" == $'\n' ]]; then continue; fi
        local peer_pubkey; peer_pubkey=$(echo "$peer_block" | grep -oP 'PublicKey\s*=\s*\K.*'); local should_delete=false
        for del_pubkey in "${pubkeys_to_delete[@]}"; do if [[ -n "$peer_pubkey" && "$peer_pubkey" == "$del_pubkey" ]]; then should_delete=true; break; fi; done
        if ! $should_delete; then printf "\n\n%s" "$peer_block" >> "$TEMP_CONFIG"; fi
    done < <(sudo awk 'BEGIN{RS="\n\n"; ORS="\0"} /^# Peer:/{print}' "$SERVER_CONFIG_PATH")
    
    for peer_path in "${peers_to_delete[@]}"; do echo "   - Удаление файла конфигурации $(basename "$peer_path")..."; sudo rm "$peer_path"; done

    local CLEANED_CONFIG; CLEANED_CONFIG=$(mktemp)
    sudo awk 'NF > 0 {if (blanks) print ""; print; blanks=0; next} {blanks=1}' "$TEMP_CONFIG" > "$CLEANED_CONFIG"
    sudo cp "$CLEANED_CONFIG" "$SERVER_CONFIG_PATH"; rm "$TEMP_CONFIG" "$CLEANED_CONFIG"

    if $was_active; then sudo wg-quick up "$WG_INTERFACE" &>/dev/null; verify_tunnel_activation "$WG_INTERFACE"; fi
    
    echo "✅ Указанные пиры были успешно удалены."; if command -v pause_and_wait &>/dev/null; then pause_and_wait; fi; return 0
}

# Главная функция интерфейса изменения одной конфигурации
run_edit_flow_for_config() {
    local CONFIG_NAME=$1; local total_configs=$2; local current_config_index=$3
    while true; do
        clear; local mode; mode=$(get_config_mode "$CONFIG_NAME")
        local server_conf_path; server_conf_path=$(sudo find "/etc/wireguard/$CONFIG_NAME" -name "wg-*.conf" -print -quit 2>/dev/null)
        echo "⚙️  Изменение конфигурации '$CONFIG_NAME' $mode"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        local back_option_num=5
        
        if sudo grep -q "(Mode 2)" "$server_conf_path" 2>/dev/null; then
            echo "1. Сменить роутер для выхода в интернет"
            echo "2. Пересоздать ключи для всех"
            echo "3. Пересоздать ключи ТОЛЬКО для роутеров"
            echo "4. Пересоздать ключи ТОЛЬКО для клиентов"
            echo "5. Добавить роутеры"
            echo "6. Удалить роутеры"
            echo "7. Добавить клиентов"
            echo "8. Удалить клиентов"
            back_option_num=9
        elif sudo grep -q "(Mode 3)" "$server_conf_path" 2>/dev/null; then
            echo "1. Пересоздать ключи для всех"
            echo "2. Пересоздать ключи ТОЛЬКО для роутеров"
            echo "3. Пересоздать ключи ТОЛЬКО для клиентов"
            echo "4. Добавить роутеры"
            echo "5. Удалить роутеры"
            echo "6. Добавить клиентов"
            echo "7. Удалить клиентов"
            back_option_num=8
        else # Режим 1
            echo "1. Пересоздать ключи для всех"
            echo "2. Пересоздать ключи для клиентов"
            echo "3. Добавить клиентов"
            echo "4. Удалить клиентов"
        fi

        if [ "$total_configs" -gt 1 ] && [ "$current_config_index" -lt "$total_configs" ]; then
            echo "$back_option_num. Пропустить и перейти к следующей конфигурации"
            back_option_num=$((back_option_num + 1))
        fi
        echo "$back_option_num. Назад"; echo; read -p "-> " choice

        if sudo grep -q "(Mode 2)" "$server_conf_path" 2>/dev/null; then
            case $choice in
                1) edit_change_gateway "$CONFIG_NAME" && break ;; 2) edit_recreate_keys_flow "$CONFIG_NAME" "all" && break ;;
                3) edit_recreate_keys_flow "$CONFIG_NAME" "router" && break ;; 4) edit_recreate_keys_flow "$CONFIG_NAME" "client" && break ;;
                5) edit_add_peers "$CONFIG_NAME" "router" && break ;; 6) edit_delete_peers "$CONFIG_NAME" "router" && break ;;
                7) edit_add_peers "$CONFIG_NAME" "client" && break ;; 8) edit_delete_peers "$CONFIG_NAME" "client" && break ;;
                9) if [ "$back_option_num" -eq 10 ]; then break; else return 1; fi ;;
                10) return 1 ;; *) clear
            esac
        elif sudo grep -q "(Mode 3)" "$server_conf_path" 2>/dev/null; then
             case $choice in
                1) edit_recreate_keys_flow "$CONFIG_NAME" "all" && break ;;
                2) edit_recreate_keys_flow "$CONFIG_NAME" "router" && break ;; 3) edit_recreate_keys_flow "$CONFIG_NAME" "client" && break ;;
                4) edit_add_peers "$CONFIG_NAME" "router" && break ;; 5) edit_delete_peers "$CONFIG_NAME" "router" && break ;;
                6) edit_add_peers "$CONFIG_NAME" "client" && break ;; 7) edit_delete_peers "$CONFIG_NAME" "client" && break ;;
                8) if [ "$back_option_num" -eq 9 ]; then break; else return 1; fi ;;
                9) return 1 ;; *) clear
            esac
        else # Режим 1
            case $choice in
                1) edit_recreate_keys_flow "$CONFIG_NAME" "all" && break ;; 2) edit_recreate_keys_flow "$CONFIG_NAME" "client" && break ;;
                3) edit_add_peers "$CONFIG_NAME" "client" && break ;; 4) edit_delete_peers "$CONFIG_NAME" "client" && break ;;
                5) if [ "$back_option_num" -eq 6 ]; then break; else return 1; fi ;;
                6) return 1 ;; *) clear
            esac
        fi
    done
    return 0
}

# Главное меню для входа в режим изменения конфигураций
edit_configs_menu() {
    while true; do
        clear; echo "⚙️  Изменение конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1. Изменить одну или несколько конфигураций"; echo "2. Изменить ВСЕ конфигурации"; echo "3. Назад"
        read -p "-> " choice; echo; case $choice in 1 | 2) break ;; 3) return 0 ;; *) clear ;; esac
    done
    
    local all_configs=(); while IFS= read -r -d '' dir; do all_configs+=("$(basename "$dir")"); done < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
    if [ ${#all_configs[@]} -eq 0 ]; then echo -e "⚙️  Нет конфигураций для изменения.\n"; read -p "Нажмите Enter для возврата в главное меню..."; return 0; fi

    local configs_to_edit=()
    case $choice in
        1)
            echo "⚙️  Доступные конфигурации для изменения:"; echo
            for i in "${!all_configs[@]}"; do
                local conf_name="${all_configs[$i]}"; local icon="🔴"; if is_config_truly_active "$conf_name"; then icon="🟢"; fi
                local mode; mode=$(get_config_mode "$conf_name"); echo "$icon $((i+1)). $conf_name $mode"
            done; echo
            read -p "❓ Введите номера конфигураций (через пробел): " -a choices
            if [ ${#choices[@]} -eq 0 ]; then echo "⚙️  Не выбрано ни одной конфигурации."; return 0; fi
            for num in "${choices[@]}"; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#all_configs[@]}" ]; then configs_to_edit+=("${all_configs[$((num-1))]}"); else echo "⚠️  Предупреждение: Неверное число '$num'."; fi
            done ;;
        2) configs_to_edit=("${all_configs[@]}") ;;
    esac

    if [ ${#configs_to_edit[@]} -eq 0 ]; then echo "⚙️  Не выбрано корректных конфигураций."; read -p "Нажмите Enter для продолжения..."; return 0; fi

    local i=1
    for conf_name in "${configs_to_edit[@]}"; do if ! run_edit_flow_for_config "$conf_name" "${#configs_to_edit[@]}" "$i"; then break; fi; i=$((i+1)); done
}

# --- КОНЕЦ БЛОКА ФУНКЦИЙ ИЗМЕНЕНИЯ ---

# --- ФУНКЦИЯ УДАЛЕНИЯ ОДНОЙ ИЛИ НЕСКОЛЬКИХ КОНФИГУРАЦИЙ ---
delete_specific_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
    if [ ${#all_configs[@]} -eq 0 ]; then echo "⚙️  Нет конфигураций для удаления."; pause_and_wait; return; fi
    echo -e "⚙️  Существующие конфигурации:\n";
    for i in "${!all_configs[@]}"; do
        local conf_name="${all_configs[$i]}"; local icon="🔴"; if is_config_truly_active "$conf_name"; then icon="🟢"; fi; echo "$icon $((i+1)). $conf_name"
    done; echo
    read -p "❓ Введите числа для удаления (через пробел, если несколько): " -a choices
    if [ ${#choices[@]} -eq 0 ]; then echo "⚙️  Не выбрано ни одной конфигурации."; return; fi
    local valid_configs_to_delete=()
    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all_configs[@]}" ]; then
            valid_configs_to_delete+=("${all_configs[$((choice-1))]}")
        else echo "⚠️  Предупреждение: Неверное число '$choice'."; fi
    done
    if [ ${#valid_configs_to_delete[@]} -eq 0 ]; then echo "⚙️  Не выбрано корректных конфигураций."; return; fi
    
    echo -e "\n🔥 Будут удалены:\n"
    for conf in "${valid_configs_to_delete[@]}"; do
        if is_config_truly_active "$conf"; then
            echo "🟢 $conf"
        else
            echo "🔴 $conf"
        fi
    done
    echo
    
    read -p "❓ Продолжить? (1 - да, 2 - нет): " confirm
    if [[ "$confirm" != "1" ]]; then echo "⚙️  Удаление отменено."; return; fi
    
    apply_deep_clean "${valid_configs_to_delete[@]}"
}

# --- ФУНКЦИЯ УДАЛЕНИЯ ВСЕХ ВКЛЮЧЕННЫХ КОНФИГУРАЦИЙ ---
delete_all_running_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true)
    local running_configs=(); for conf_name in "${all_configs[@]}"; do if is_config_truly_active "$conf_name"; then running_configs+=("$conf_name"); fi; done
    if [ ${#running_configs[@]} -eq 0 ]; then echo "⚙️  Нет включенных конфигураций для удаления."; pause_and_wait; return; fi

    echo -e "🔥 Будут удалены ВКЛЮЧЕННЫЕ конфигурации:\n"; for conf in "${running_configs[@]}"; do echo "🟢 $conf"; done; echo
    read -p "❓ Продолжить? (1 - да, 2 - нет): " confirm
    if [[ "$confirm" != "1" ]]; then echo "⚙️  Удаление отменено."; return; fi

    apply_deep_clean "${running_configs[@]}"
}

# --- ФУНКЦИЯ: УДАЛЕНИЕ ВСЕХ ВЫКЛЮЧЕННЫХ КОНФИГУРАЦИЙ ---
delete_all_stopped_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true)
    local stopped_configs=(); for conf_name in "${all_configs[@]}"; do if ! is_config_truly_active "$conf_name"; then stopped_configs+=("$conf_name"); fi; done
    if [ ${#stopped_configs[@]} -eq 0 ]; then echo "⚙️  Нет выключенных конфигураций для удаления."; pause_and_wait; return; fi

    echo -e "🔥 Будут удалены ВЫКЛЮЧЕННЫЕ конфигурации:\n"; for conf in "${stopped_configs[@]}"; do echo "🔴 $conf"; done; echo
    read -p "❓ Продолжить? (1 - да, 2 - нет): " choice
    if [[ "$choice" != "1" ]]; then echo "⚙️  Удаление отменено."; return; fi

    apply_deep_clean "${stopped_configs[@]}"
}

# --- ФУНКЦИЯ: УДАЛЕНИЕ АБСОЛЮТНО ВСЕХ КОНФИГУРАЦИЙ ---
delete_all_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true)
    if [ ${#all_configs[@]} -eq 0 ]; then echo "⚙️  Нет конфигураций для удаления."; pause_and_wait; return; fi
    
    echo "🔥🔥🔥 ПРЕДУПРЕЖДЕНИЕ! 🔥🔥🔥"
    echo -e "Будут удалены ВСЕ конфигурации:\n"
    for conf in "${all_configs[@]}"; do
        if is_config_truly_active "$conf"; then
            echo "🟢 $conf"
        else
            echo "🔴 $conf"
        fi
    done
    echo
    
    read -p "❓ Продолжить? (1 - да, 2 - нет): " confirm
    if [[ "$confirm" != "1" ]]; then echo "⛔ Удаление отменено."; return; fi
    
    apply_deep_clean "${all_configs[@]}"
}

# --- ОБЩАЯ ФУНКЦИЯ ДЛЯ ЗАПУСКА КОНФИГУРАЦИЙ ---
run_activation_logic() {
    local configs_to_activate=("$@")
    if [ ${#configs_to_activate[@]} -eq 0 ]; then echo "⚙️  Нет конфигураций для активации."; return; fi
    
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true)
    local running_configs=(); for conf_name in "${all_configs[@]}"; do if is_config_truly_active "$conf_name"; then running_configs+=("$conf_name"); fi; done

    echo "🔎 Проверка на конфликты..."; declare -A running_params
    for r_conf in "${running_configs[@]}"; do
        r_path=$(sudo find "/etc/wireguard/$r_conf" -name "wg-*.conf" -print -quit 2>/dev/null); if [ -f "$r_path" ]; then
            port=$(sudo grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$r_path" | head -n 1 || echo ""); subnet=$(sudo grep -oP 'Address\s*=\s*10\.\K[0-9]+\.[0-9]+' "$r_path" | head -n 1 || echo "")
            if [ -n "$port" ]; then running_params["port:$port"]="$r_conf"; fi; if [ -n "$subnet" ]; then running_params["subnet:$subnet"]="$r_conf"; fi
        fi
    done

    local safe_to_activate=(); local conflicting_stopped_configs=(); declare -A conflicts_map
    for s_conf in "${configs_to_activate[@]}"; do
        s_path=$(sudo find "/etc/wireguard/$s_conf" -name "wg-*.conf" -print -quit 2>/dev/null); is_conflicting=false
        if [ ! -f "$s_path" ]; then echo "⚠️  В '$s_conf' не найден wg-*.conf. Пропускаю."; continue; fi
        port=$(sudo grep -oP 'ListenPort\s*=\s*\K[0-9]+' "$s_path" | head -n 1 || echo ""); subnet=$(sudo grep -oP 'Address\s*=\s*10\.\K[0-9]+\.[0-9]+' "$s_path" | head -n 1 || echo "")
        if [ -n "$port" ] && [ -n "${running_params["port:$port"]}" ]; then is_conflicting=true; conflicts_map["$s_conf"]="${running_params["port:$port"]}"; fi
        if [ -n "$subnet" ] && [ -n "${running_params["subnet:$subnet"]}" ]; then is_conflicting=true; conflicts_map["$s_conf"]="${running_params["subnet:$subnet"]}"; fi
        if $is_conflicting; then conflicting_stopped_configs+=("$s_conf"); else safe_to_activate+=("$s_conf"); fi
    done

    if [ ${#conflicting_stopped_configs[@]} -gt 0 ]; then
        echo; echo "⚠️  Обнаружены конфликты!"; declare -A conflicting_working_display
        for stopped_conf in "${conflicting_stopped_configs[@]}"; do conflicting_working_display["${conflicts_map[$stopped_conf]}"]=1; done
        echo "1. Активные конфигурации: ${!conflicting_working_display[*]}"; echo "2. Неактивные конфигурации (вызывающие конфликт): ${conflicting_stopped_configs[*]}"; echo
        echo "❓ Что сделать?"; echo; echo "1) Заменить работающие конфигурации на неактивные"; echo "2) Отменить замену"; echo
        read -p "❓ Выберите действие [1-2]: " conflict_choice
        case $conflict_choice in
            1) echo "Выбрано: Заменить."; apply_deep_clean "${!conflicting_working_display[@]}"; safe_to_activate+=("${conflicting_stopped_configs[@]}");;
            *) echo "⚙️  Конфликтующие конфигурации будут пропущены.";;
        esac
    fi
    
    if [ ${#safe_to_activate[@]} -eq 0 ]; then echo; echo "⚙️  Нет конфигураций для запуска."; return; fi
    
    echo; echo "🚀 Активация: ${safe_to_activate[*]}"
    for conf_name in "${safe_to_activate[@]}"; do
        local WG_INTERFACE="wg-$conf_name"; local CONFIG_DIR="/etc/wireguard/$conf_name"
        local SERVER_CONFIG_PATH=$(sudo find "$CONFIG_DIR" -name "wg-*.conf" -print -quit 2>/dev/null)
        if [ -z "$SERVER_CONFIG_PATH" ]; then echo "   - ⚠️  Не найден .conf для '$conf_name', пропускаю."; continue; fi
        sudo ln -sf "$SERVER_CONFIG_PATH" "/etc/wireguard/${WG_INTERFACE}.conf"
        echo "   - Запуск '$conf_name'..."; sudo systemctl enable --now "wg-quick@${WG_INTERFACE}"
        verify_tunnel_activation "$WG_INTERFACE"
    done
}

# --- ФУНКЦИЯ АКТИВАЦИИ ВСЕХ НЕАКТИВНЫХ КОНФИГУРАЦИЙ ---
activate_all_stopped_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
    local stopped_configs=(); for conf_name in "${all_configs[@]}"; do if ! is_config_truly_active "$conf_name"; then stopped_configs+=("$conf_name"); fi; done
    if [ ${#stopped_configs[@]} -eq 0 ]; then echo "⚙️  Нет выключенных конфигураций для активации."; pause_and_wait; return; fi
    echo "⚙️  Найдены неактивные конфигурации: ${stopped_configs[*]}"; echo "🚀 Запускаю ВСЕ неактивные конфигурации..."
    run_activation_logic "${stopped_configs[@]}"; pause_and_wait
}

# --- ФУНКЦИЯ АКТИВАЦИИ ОДНОЙ ИЛИ НЕСКОЛЬКИХ КОНФИГУРАЦИЙ ---
activate_specific_configs() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
    local stopped_configs=(); for conf_name in "${all_configs[@]}"; do if ! is_config_truly_active "$conf_name"; then stopped_configs+=("$conf_name"); fi; done
    if [ ${#stopped_configs[@]} -eq 0 ]; then echo "⚙️  Нет выключенных конфигураций для активации."; pause_and_wait; return; fi

    echo "⚙️  Выключенные конфигурации:";
    for i in "${!stopped_configs[@]}"; do echo "🔴 $((i+1)). ${stopped_configs[$i]}"; done; echo

    read -p "❓ Введите числа для активации (через пробел, если несколько): " -a choices
    if [ ${#choices[@]} -eq 0 ]; then echo "⚙️  Не выбрано ни одной конфигурации."; return; fi

    local configs_to_activate=()
    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#stopped_configs[@]}" ]; then
            configs_to_activate+=("${stopped_configs[$((choice-1))]}")
        else echo "⚠️  Неверное число '$choice'!"; fi
    done
    run_activation_logic "${configs_to_activate[@]}"; pause_and_wait
}

# --- НАЧАЛО БЛОКА НОВЫХ ФУНКЦИЙ ДЛЯ СВОДКИ И СОСТОЯНИЯ ---

# --- ФУНКЦИЯ ОТОБРАЖЕНИЯ СВОДКИ ДЛЯ ОДНОЙ КОНФИГУРАЦИИ ---
show_summary_for_config() {
    local CONFIG_NAME=$1; local CONFIG_DIR="/etc/wireguard/$CONFIG_NAME"; local SERVER_CONFIG_PATH
    SERVER_CONFIG_PATH=$(sudo find "$CONFIG_DIR" -name "wg-*.conf" -print -quit 2>/dev/null)
    if [ ! -f "$SERVER_CONFIG_PATH" ]; then echo "❌ Ошибка: не найден главный файл конфигурации для '$CONFIG_NAME'."; return; fi
    
    local SERVER_IP; SERVER_IP=$(get_server_public_ip)
    if [ "$SERVER_IP" == "error" ]; then SERVER_IP="<не удалось определить>"; fi

    echo "📋 ИНФОРМАЦИЯ ДЛЯ '$CONFIG_NAME':"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if sudo grep -q "(Mode 1)" "$SERVER_CONFIG_PATH"; then
        echo "👥 Клиенты ⮂ ☁️  Сервер ⮂ 🌐 Интернет"
    elif sudo grep -q "(Mode 2)" "$SERVER_CONFIG_PATH"; then
        echo "👥 Клиенты ⮂ ☁️  Сервер ⮂ 📡 Роутер(ы) ⮂ 🌐 Интернет + 🏠 LAN"
        local gateway_router_info; gateway_router_info=$(sudo grep "0.0.0.0/0" "$SERVER_CONFIG_PATH" -B 4 | grep "# Peer:" | head -n 1)
        if [ -n "$gateway_router_info" ]; then echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo -e "📡 ${gateway_router_info#\# Peer: } - текущий роутер для выхода в интернет.\n💡 Необходимо настроить NAT для WireGuard на роутере по инструкции:\n🔗 https://github.com/Internet-Helper/WireGuard-Auto-Setup-Script/wiki"; else echo "⚠️  Роутер для выхода в интернет не назначен!"; fi
    elif sudo grep -q "(Mode 3)" "$SERVER_CONFIG_PATH"; then
        echo "👥 Клиенты ⮂ ☁️  Сервер ⮂ 📡 Роутер(ы) ⮂ 🏠 LAN"
    else
        echo "Не удалось определить режим конфигурации для '$CONFIG_NAME'."
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# --- МЕНЮ ДЛЯ ОТОБРАЖЕНИЯ ИНФОРМАЦИИ И ЭКСПОРТА КОНФИГОВ ---
info_menu() {
    local choice
    while true; do
        clear; echo "📋 Информация про конфигурации"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1. Информация про одну или несколько конфигураций"; echo "2. Информация про все ВКЛЮЧЕННЫЕ конфигурации"
        echo "3. Информация про все ВЫКЛЮЧЕННЫЕ конфигурации"; echo "4. Информация про ВСЕ конфигурации"; echo "5. Назад"
        read -p "-> " choice; echo
        
        # Проверка на пустой ввод
        if [[ -z "$choice" ]]; then
            continue
        fi
        
        # Если выбран выход, сразу выходим
        if [[ "$choice" == "5" ]]; then
            break
        fi
        
        # Проверка на правильность выбора
        if [[ ! "$choice" =~ ^[1-4]$ ]]; then
            continue
        fi
        
        mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
        if [ ${#all_configs[@]} -eq 0 ]; then echo "⚙️  Конфигурации не найдены."; pause_and_wait; return; fi
        local configs_to_show=()
        case $choice in
            1)
                echo "⚙️  Существующие конфигурации:";
                for i in "${!all_configs[@]}"; do local conf_name="${all_configs[$i]}"; local icon="🔴"; if is_config_truly_active "$conf_name"; then icon="🟢"; fi; echo "$icon $((i+1)). $conf_name"; done; echo
                read -p "❓ Введите числа для просмотра (через пробел, если несколько): " -a choices_nums
                if [ ${#choices_nums[@]} -eq 0 ]; then echo "⚙️  Не выбрано ни одной конфигурации."; continue; fi
                for num in "${choices_nums[@]}"; do if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#all_configs[@]}" ]; then configs_to_show+=("${all_configs[$((num-1))]}"); else echo "⚠️  Предупреждение: Неверное число '$num'."; fi; done ;;
            2) for conf_name in "${all_configs[@]}"; do if is_config_truly_active "$conf_name"; then configs_to_show+=("$conf_name"); fi; done; if [ ${#configs_to_show[@]} -eq 0 ]; then echo "⚙️  Нет включенных конфигураций."; pause_and_wait; continue; fi ;;
            3) for conf_name in "${all_configs[@]}"; do if ! is_config_truly_active "$conf_name"; then configs_to_show+=("$conf_name"); fi; done; if [ ${#configs_to_show[@]} -eq 0 ]; then echo "⚙️  Нет выключенных конфигураций."; pause_and_wait; continue; fi ;;
            4) configs_to_show=("${all_configs[@]}") ;;
        esac
        if [ ${#configs_to_show[@]} -gt 0 ]; then
            clear
            for conf_name in "${configs_to_show[@]}"; do show_summary_for_config "$conf_name"; export_configs "$conf_name"; done
            pause_and_wait
        fi
        break 
    done
}

# --- ФУНКЦИЯ ДЛЯ ПРОСМОТРА СОСТОЯНИЯ (WG SHOW) ---
show_specific_configs_state() {
    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
    if [ ${#all_configs[@]} -eq 0 ]; then echo "⚙️  Конфигурации не найдены."; pause_and_wait; return; fi

    echo "⚙️  Существующие конфигурации:";
    for i in "${!all_configs[@]}"; do local conf_name="${all_configs[$i]}"; local icon="🔴"; if is_config_truly_active "$conf_name"; then icon="🟢"; fi; echo "$icon $((i+1)). $conf_name"; done; echo
    
    read -p "❓ Введите числа для просмотра состояния (через пробел, если несколько): " -a choices
    if [ ${#choices[@]} -eq 0 ]; then echo "⚙️  Не выбрано ни одной конфигурации."; return; fi

    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all_configs[@]}" ]; then
            local conf_name="${all_configs[$((choice-1))]}"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            if is_config_truly_active "$conf_name"; then sudo wg show "wg-$conf_name"; else echo "🔴 Конфигурация '$conf_name' выключена."; fi
        else echo "⚠️  Предупреждение: Неверное число '$choice'."; fi
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; pause_and_wait
}

show_all_configs_state() {
    if ! sudo wg show | grep -q 'interface:'; then echo "⚙️  Нет активных конфигураций."; else sudo wg show; fi; pause_and_wait
}

# --- МЕНЮ ДЛЯ ОТОБРАЖЕНИЯ СОСТОЯНИЯ ---
show_state_menu() {
    while true; do
       clear; echo "⚙️  Состояние конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
       echo "1. Состояние одной или нескольких конфигураций"; echo "2. Состояние всех РАБОТАЮЩИХ конфигураций"; echo "3. Назад"
       read -p "-> " choice; echo
       case $choice in 1) show_specific_configs_state; break ;; 2) show_all_configs_state; break ;; 3) break ;; *) clear ;; esac
    done
}

# --- КОНЕЦ БЛОКА НОВЫХ ФУНКЦИЙ ---

# --- ГЛАВНОЕ МЕНЮ ---
run_first_time_setup

while true; do
    clear
    printf "\033[38;2;0;210;106mWireGuard Easy Setup by Internet Helper\033[0m\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

    mapfile -t all_configs < <(find /etc/wireguard -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null || true | sort)
    running_configs=(); stopped_configs=()
    if [ ${#all_configs[@]} -gt 0 ]; then
        for conf_name in "${all_configs[@]}"; do if is_config_truly_active "$conf_name"; then running_configs+=("$conf_name"); else stopped_configs+=("$conf_name"); fi; done
    fi

    if [ ${#running_configs[@]} -gt 0 ]; then
        echo "⚙️  Включенные конфигурации:"
        for conf in "${running_configs[@]}"; do 
            mode_display=$(get_config_mode "$conf")
            printf "🟢 %s \033[38;5;242m%s\033[0m\n" "$conf" "$mode_display"
        done
        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    fi
    if [ ${#stopped_configs[@]} -gt 0 ]; then
        echo "⚙️  Выключенные конфигурации:"
        for conf in "${stopped_configs[@]}"; do 
            mode_display=$(get_config_mode "$conf")
            printf "🔴 %s \033[38;5;242m%s\033[0m\n" "$conf" "$mode_display"
        done
        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    fi
    if [ ${#all_configs[@]} -eq 0 ]; then 
        echo "⚙️  Конфигурации пока не созданы."
        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    fi

    printf "\033[38;2;0;210;106m0.\033[0m Выйти\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "\033[38;2;0;210;106m1.\033[0m Создать\n"
    printf "\033[38;2;0;210;106m2.\033[0m Активировать\n"
    printf "\033[38;2;0;210;106m3.\033[0m Остановить\n"
    printf "\033[38;2;0;210;106m4.\033[0m Изменить\n"
    printf "\033[38;2;0;210;106m5.\033[0m Удалить\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "\033[38;2;0;210;106m6.\033[0m Информация\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    printf "\033[38;2;0;210;106m7.\033[0m Состояние\n"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    read -p "Выберите действие [0-7]: " main_choice; echo

    case $main_choice in
        1) create_config ;;
        2)
           clear; echo "⚙️  Активация конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           while true; do
               echo "1. Активировать одну или несколько конфигураций"; echo "2. Активировать ВСЕ неактивные конфигурации"; echo "3. Назад"
               read -p "-> " choice; echo
               case $choice in 1) activate_specific_configs; break ;; 2) activate_all_stopped_configs; break ;; 3) break ;; *) clear; echo "⚙️  Активация конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" ;; esac
           done ;;
        3)
           clear; echo "⚙️  Остановка конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           while true; do
               echo "1. Остановить одну или несколько конфигураций"; echo "2. Остановить ВСЕ работающие конфигурации"; echo "3. Назад"
               read -p "-> " choice; echo
               case $choice in 1) stop_specific_configs; break ;; 2) stop_all_running_configs; break ;; 3) break ;; *) clear; echo "⚙️  Остановка конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" ;; esac
           done ;;
        4) edit_configs_menu ;;
        5)
           clear; echo "🗑️  Удаление конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           while true; do
               echo "1. Удалить одну или несколько конфигураций"; echo "2. Удалить все ВКЛЮЧЕННЫЕ конфигурации"
               echo "3. Удалить все ВЫКЛЮЧЕННЫЕ конфигурации"; echo "4. Удалить ВСЕ конфигурации"; echo "5. Назад"
               read -p "-> " choice; echo
               case $choice in 1) delete_specific_configs; break ;; 2) delete_all_running_configs; break ;; 3) delete_all_stopped_configs; break ;; 4) delete_all_configs; break ;; 5) break ;; *) clear; echo "🗑️  Удаление конфигураций"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" ;; esac
            done ;;
        6) info_menu ;;
        7) show_state_menu ;;
        0) exit 0 ;;
        *) esac
done