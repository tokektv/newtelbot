#!/bin/sh

# Baca konfigurasi dari UCI
TOKEN=$(uci get telegram_bot.config.token 2>/dev/null)
CHAT_ID=$(uci get telegram_bot.config.chat_id 2>/dev/null)
ROUTER_ID=$(uci get telegram_bot.config.router_id 2>/dev/null)

# Validasi config
if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ] || [ -z "$ROUTER_ID" ]; then
    echo "$(date): ERROR - Missing config" >> /tmp/telegram_bot.log
    exit 1
fi

echo "$(date): Bot started - ROUTER_ID: $ROUTER_ID" >> /tmp/telegram_bot.log

# File untuk menyimpan ID update terakhir
LAST_UPDATE_ID_FILE="/root/last_update_id_${ROUTER_ID}.txt"
touch "$LAST_UPDATE_ID_FILE"

# File untuk menyimpan daftar router aktif
ACTIVE_ROUTERS_FILE="/tmp/active_routers.txt"
touch "$ACTIVE_ROUTERS_FILE"

# Fungsi logging
log() {
    echo "$(date): $1" >> /tmp/telegram_bot.log
}

# FUNGSI SEND_MESSAGE DENGAN UTF-8 FIX
send_message() {
    local message="$1"
    log "Sending message to Telegram..."
    
    # Encode message untuk UTF-8 dan escape special characters
    encoded_message=$(echo "$message" | iconv -f ASCII -t UTF-8//TRANSLIT 2>/dev/null || echo "$message")
    
    # Gunakan curl dengan header UTF-8
    response=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
        -d "chat_id=$CHAT_ID" \
        --data-urlencode "text=$encoded_message" \
        -w "\n%{http_code}")
    
    http_code=$(echo "$response" | tail -1)
    log "HTTP Response Code: $http_code"
    
    if [ "$http_code" != "200" ]; then
        log "Failed to send message. Response: $response"
        return 1
    else
        log "Message sent successfully"
        return 0
    fi
}

# Fungsi untuk mendapatkan update dari bot
get_updates() {
    local offset="$1"
    log "Get updates offset: $offset"
    
    response=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/getUpdates" \
        -d "offset=$offset" \
        -d "timeout=10" \
        -d "limit=1")
    
    echo "$response"
}

# FUNGSI HELP DENGAN FITUR BARU
show_help() {
    send_message "Bot Router Management

Format Perintah:
/command router_id parameter

Contoh:
/status ROUTER3
/online ROUTER3
/reboot ROUTER3
/ping ROUTER3 8.8.8.8

Daftar Perintah:
/status [router_id] - Status router
/online [router_id] - User online
/reboot [router_id] - Restart router
/restart_interface [router_id] [interface] - Restart interface
/restart_mwan3 [router_id] - Restart MWAN3
/clear_cache [router_id] - Clear cache
/ping [router_id] [ip] - Ping IP

=== FITUR BARU ===
/disable [router_id] [interface] - Disable interface
/enable [router_id] [interface] - Enable interface
/disable_all [interface] - Disable interface di SEMUA router
/enable_all [interface] - Enable interface di SEMUA router

/routers - Tampilkan semua router aktif
/help - Tampilkan ini"
}

# Fungsi untuk mendaftarkan router aktif
register_router() {
    local router_id="$1"
    local timestamp=$(date +%s)
    
    # Create temp file
    temp_file="/tmp/active_routers_temp.$$"
    
    # Remove existing entry and add new one
    if [ -f "$ACTIVE_ROUTERS_FILE" ]; then
        grep -v "^${router_id}," "$ACTIVE_ROUTERS_FILE" > "$temp_file" 2>/dev/null || true
    fi
    
    echo "${router_id},${timestamp}" >> "$temp_file"
    
    # Remove old entries (older than 10 minutes)
    local current_time=$(date +%s)
    while IFS=',' read -r id ts; do
        if [ $((current_time - ts)) -lt 600 ]; then  # 10 minutes
            echo "${id},${ts}"
        fi
    done < "$temp_file" > "$ACTIVE_ROUTERS_FILE"
    
    rm -f "$temp_file"
}

# Fungsi untuk menampilkan semua router aktif
show_active_routers() {
    if [ ! -f "$ACTIVE_ROUTERS_FILE" ] || [ ! -s "$ACTIVE_ROUTERS_FILE" ]; then
        echo "Daftar Router Aktif: Tidak ada router aktif yang terdeteksi"
        return
    fi
    
    local routers_list="Daftar Router Aktif:\n\n"
    local current_time=$(date +%s)
    local count=0
    
    while IFS=',' read -r router_id timestamp; do
        local age=$((current_time - timestamp))
        local age_text=""
        
        if [ $age -lt 60 ]; then
            age_text="${age} detik lalu"
        elif [ $age -lt 3600 ]; then
            age_text="$((age / 60)) menit lalu"
        else
            age_text="$((age / 3600)) jam lalu"
        fi
        
        routers_list="${routers_list}* ${router_id} (${age_text})\n"
        count=$((count + 1))
    done < "$ACTIVE_ROUTERS_FILE"
    
    routers_list="${routers_list}\nTotal: ${count} router aktif"
    echo -e "$routers_list"
}

# FUNGSI DISABLE INTERFACE
disable_interface() {
    local interface="$1"
    log "Disabling interface: $interface"
    
    if [ -z "$interface" ]; then
        echo "Interface tidak boleh kosong"
        return 1
    fi
    
    # Cek apakah interface ada
    if ! ifstatus "$interface" >/dev/null 2>&1; then
        echo "Interface $interface tidak ditemukan"
        return 1
    fi
    
    # Disable interface
    if ifdown "$interface"; then
        echo "Interface $interface berhasil di-disable"
        return 0
    else
        echo "Gagal disable interface $interface"
        return 1
    fi
}

# FUNGSI ENABLE INTERFACE
enable_interface() {
    local interface="$1"
    log "Enabling interface: $interface"
    
    if [ -z "$interface" ]; then
        echo "Interface tidak boleh kosong"
        return 1
    fi
    
    # Cek apakah interface ada
    if ! ifstatus "$interface" >/dev/null 2>&1; then
        echo "Interface $interface tidak ditemukan"
        return 1
    fi
    
    # Enable interface
    if ifup "$interface"; then
        echo "Interface $interface berhasil di-enable"
        return 0
    else
        echo "Gagal enable interface $interface"
        return 1
    fi
}

# FUNGSI MASS DISABLE (untuk perintah semua router)
mass_disable_interface() {
    local interface="$1"
    log "Mass disable interface: $interface"
    
    if [ -z "$interface" ]; then
        echo "Interface tidak boleh kosong"
        return 1
    fi
    
    # Kirim perintah disable ke router ini
    local result=$(disable_interface "$interface")
    echo "$result"
}

# FUNGSI MASS ENABLE (untuk perintah semua router)
mass_enable_interface() {
    local interface="$1"
    log "Mass enable interface: $interface"
    
    if [ -z "$interface" ]; then
        echo "Interface tidak boleh kosong"
        return 1
    fi
    
    # Kirim perintah enable ke router ini
    local result=$(enable_interface "$interface")
    echo "$result"
}

# Ambil status router
get_status() {
    local uptime=$(cat /proc/uptime | awk '{print $1}')
    local load=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    local memory=$(free -m | awk 'NR==2{print $3 "MB used / " $2 "MB total"}')
    local disk=$(df -h / | awk 'NR==2{print $3 " used / " $2 " total"}')
    local wan_ip=$(curl -s -m 5 ifconfig.me 2>/dev/null || echo "Tidak dapat mengambil IP")

    if [ -z "$uptime" ]; then
        uptime=0
    fi

    local hours=$(( ${uptime%.*} / 3600 ))
    local minutes=$(( (${uptime%.*} % 3600) / 60 ))
    local seconds=$(( ${uptime%.*} % 60 ))

    echo "Status $ROUTER_ID
Uptime: $(printf '%02d:%02d:%02d' $hours $minutes $seconds)
Load Average: $load
Memory: $memory
Disk: $disk
WAN IP: $wan_ip"
}

# Fungsi untuk menampilkan pengguna online
get_online_users() {
    local online_users=""
    local DHCP_LEASES_FILE="/tmp/dhcp.leases"

    if [ ! -f "$DHCP_LEASES_FILE" ]; then
        echo "Tidak ada data DHCP leases"
        return
    fi

    while read -r line; do
        ip_address=$(echo "$line" | awk '{print $3}')
        hostname=$(echo "$line" | awk '{print $4}')
        if [ "$hostname" != "*" ] && [ -n "$hostname" ]; then
            online_users="${online_users}* $hostname ($ip_address)\n"
        fi
    done < "$DHCP_LEASES_FILE"

    if [ -z "$online_users" ]; then
        echo "Tidak ada perangkat online"
    else
        echo -e "$online_users"
    fi
}

# Fungsi untuk membersihkan cache
clear_cache() {
    echo "Membersihkan cache..."
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo "Cache cleared"
}

# Fungsi untuk melakukan ping
ping_ip() {
    local ip="$1"
    if [ -z "$ip" ]; then
        echo "IP tidak boleh kosong."
        return
    fi
    ping -c 2 -W 3 "$ip" 2>/dev/null || echo "Ping gagal atau timeout"
}

# Fungsi utama untuk memproses perintah
process_command() {
    local update="$1"
    
    # Extract data using jq
    local message=$(echo "$update" | jq -r '.result[0].message.text // empty' 2>/dev/null)
    local chat_id=$(echo "$update" | jq -r '.result[0].message.chat.id // empty' 2>/dev/null)
    local update_id=$(echo "$update" | jq -r '.result[0].update_id // empty' 2>/dev/null)

    log "Process command: '$message' from chat $chat_id, update_id: $update_id"

    if [ -z "$message" ] || [ -z "$chat_id" ] || [ -z "$update_id" ]; then
        log "Invalid update data"
        return
    fi

    # Save last update ID
    echo "$update_id" > "$LAST_UPDATE_ID_FILE"

    if [ "$chat_id" != "$CHAT_ID" ]; then
        log "Unauthorized access from chat ID: $chat_id"
        send_message "Akses ditolak. Chat ID tidak dikenali."
        return
    fi

    local command=$(echo "$message" | awk '{print $1}')
    local target_router=$(echo "$message" | awk '{print $2}')

    # Perintah global (tidak butuh router_id)
    case "$command" in
        "/routers")
            log "Processing /routers command"
            routers_list=$(show_active_routers)
            send_message "$routers_list"
            return
            ;;
        "/start"|"/help")
            log "Processing help command"
            show_help
            return
            ;;
        "/reset")
            log "Resetting update ID"
            echo "0" > "$LAST_UPDATE_ID_FILE"
            send_message "Update ID telah direset"
            return
            ;;
        "/test")
            send_message "Test message dari ROUTER3 - Bot berfungsi normal!"
            return
            ;;
        "/disable_all")
            log "Processing mass disable command"
            interface=$(echo "$message" | awk '{print $2}')
            if [ -z "$interface" ]; then
                send_message "Format: /disable_all [interface]\nContoh: /disable_all wan\n       /disable_all lan"
                return
            fi
            result=$(mass_disable_interface "$interface")
            send_message "Mass Disable Result [$ROUTER_ID]:\n$result"
            return
            ;;
        "/enable_all")
            log "Processing mass enable command"
            interface=$(echo "$message" | awk '{print $2}')
            if [ -z "$interface" ]; then
                send_message "Format: /enable_all [interface]\nContoh: /enable_all wan\n       /enable_all lan"
                return
            fi
            result=$(mass_enable_interface "$interface")
            send_message "Mass Enable Result [$ROUTER_ID]:\n$result"
            return
            ;;
    esac

    # Jika command tidak mengandung router_id, abaikan
    if [ -z "$target_router" ]; then
        log "No target router specified in: $message"
        send_message "Format salah. Gunakan: /command router_id"
        return
    fi

    # Abaikan jika perintah tidak untuk router ini
    if [ "$target_router" != "$ROUTER_ID" ]; then
        log "Command not for this router. Target: $target_router, Current: $ROUTER_ID"
        return
    fi

    log "Executing command: $command for router: $target_router"

    case "$command" in
        "/reboot")
            send_message "Memulai reboot ROUTER3..."
            log "Rebooting router"
            reboot
            ;;
        "/status")
            status=$(get_status)
            send_message "$status"
            ;;
        "/restart_interface")
            interface=$(echo "$message" | awk '{print $3}')
            if [ -z "$interface" ]; then
                send_message "Format: /restart_interface ROUTER3 [interface]"
                return
            fi
            send_message "Restarting interface $interface..."
            if ifdown "$interface" && ifup "$interface"; then
                send_message "Interface $interface berhasil di-restart"
            else
                send_message "Gagal restart interface $interface"
            fi
            ;;
        "/restart_mwan3")
            if [ ! -f "/etc/init.d/mwan3" ]; then
                send_message "MWAN3 tidak terinstall"
                return
            fi
            send_message "Restarting MWAN3..."
            if /etc/init.d/mwan3 restart; then
                send_message "MWAN3 berhasil di-restart"
            else
                send_message "Gagal restart MWAN3"
            fi
            ;;
        "/online")
            online_users=$(get_online_users)
            send_message "Pengguna Online:\n$online_users"
            ;;
        "/clear_cache")
            clear_cache
            send_message "Cache berhasil dibersihkan"
            ;;
        "/ping")
            ip=$(echo "$message" | awk '{print $3}')
            if [ -z "$ip" ]; then
                send_message "Format: /ping ROUTER3 [IP]"
                return
            fi
            ping_result=$(ping_ip "$ip")
            send_message "Ping ke $ip:\n$ping_result"
            ;;
        "/disable")
            interface=$(echo "$message" | awk '{print $3}')
            if [ -z "$interface" ]; then
                send_message "Format: /disable ROUTER3 [interface]\nContoh: /disable ROUTER3 wan\n       /disable ROUTER3 lan"
                return
            fi
            result=$(disable_interface "$interface")
            send_message "Disable Interface [$ROUTER_ID]:\n$result"
            ;;
        "/enable")
            interface=$(echo "$message" | awk '{print $3}')
            if [ -z "$interface" ]; then
                send_message "Format: /enable ROUTER3 [interface]\nContoh: /enable ROUTER3 wan\n       /enable ROUTER3 lan"
                return
            fi
            result=$(enable_interface "$interface")
            send_message "Enable Interface [$ROUTER3]:\n$result"
            ;;
        *)
            send_message "Perintah tidak dikenali: $command"
            ;;
    esac
}

# Reset update ID jika terlalu tinggi
current_last_id=$(cat "$LAST_UPDATE_ID_FILE" 2>/dev/null || echo "0")
if [ "$current_last_id" -gt 1000000 ]; then
    log "Reset update ID from $current_last_id to 0"
    echo "0" > "$LAST_UPDATE_ID_FILE"
fi

log "Starting main loop with last update ID: $(cat "$LAST_UPDATE_ID_FILE")"

# Loop utama
while true; do
    # Daftarkan router aktif setiap loop
    register_router "$ROUTER_ID"
    
    LAST_UPDATE_ID=$(cat "$LAST_UPDATE_ID_FILE" 2>/dev/null || echo "0")
    updates=$(get_updates "$((LAST_UPDATE_ID + 1))")
    
    # Check if updates are valid and not empty
    if [ -n "$updates" ] && [ "$updates" != "null" ]; then
        update_count=$(echo "$updates" | jq -r '.result | length' 2>/dev/null || echo "0")
        if [ "$update_count" -gt 0 ]; then
            log "Found $update_count new updates"
            process_command "$updates"
        fi
    fi

    sleep 5
done
