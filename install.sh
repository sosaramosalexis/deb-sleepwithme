#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="deb-sleepwithme"
CONFIG_DIR="/etc/${SERVICE_NAME}"
CONFIG_FILE="${CONFIG_DIR}/schedule.conf"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
SHUTDOWN_SCRIPT="/usr/local/bin/${SERVICE_NAME}-shutdown.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

DAYS_OF_WEEK=(mon tue wed thu fri sat sun)

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: su -; bash install.sh"
    exit 1
  fi
}

load_config() {
  SCHEDULE_DAYS=""
  SCHEDULE_TIME=""
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
SCHEDULE_DAYS="${SCHEDULE_DAYS}"
SCHEDULE_TIME="${SCHEDULE_TIME}"
EOF
  log "Schedule saved to $CONFIG_FILE"
}

install_systemd_units() {
  cat > "$SHUTDOWN_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
CONFIG_FILE="/etc/deb-sleepwithme/schedule.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  exit 0
fi
source "$CONFIG_FILE"
if [[ -z "${SCHEDULE_DAYS:-}" || -z "${SCHEDULE_TIME:-}" ]]; then
  exit 0
fi
TODAY=$(date +%a | tr '[:upper:]' '[:lower:]')
IFS=',' read -ra DAYS <<< "$SCHEDULE_DAYS"
for day in "${DAYS[@]}"; do
  if [[ "$(echo "$day" | xargs)" == "$TODAY" ]]; then
    /usr/sbin/shutdown -h now
    exit 0
  fi
done
SCRIPT
  chmod +x "$SHUTDOWN_SCRIPT"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Deb SleepWithMe - Scheduled Shutdown
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${SHUTDOWN_SCRIPT}
User=root
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Deb SleepWithMe - Daily Shutdown Timer

[Timer]
OnCalendar=daily
Persistent=false

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  log "Systemd units installed"
}

update_timer_time() {
  local time="$1"
  local hour minute
  hour="${time%%:*}"
  minute="${time##*:}"
  sed -i "s/^OnCalendar=.*/OnCalendar=*-*-* ${hour}:${minute}:00/" "$TIMER_FILE"
  systemctl daemon-reload
}

enable_timer() {
  systemctl enable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
}

disable_timer() {
  systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
}

show_schedule() {
  echo ""
  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "No schedule configured."
    return
  fi
  info "Current schedule:"
  echo "  Days: ${SCHEDULE_DAYS:-none}"
  echo "  Time: ${SCHEDULE_TIME:-none}"
  if systemctl is-active --quiet "${SERVICE_NAME}.timer" 2>/dev/null; then
    echo "  Status: ${GREEN}active${NC}"
    echo "  Next run: $(systemctl show -p NextElapseUSecMonotonic "${SERVICE_NAME}.timer" 2>/dev/null | cut -d= -f2 || echo 'unknown')"
  else
    echo "  Status: ${RED}inactive${NC}"
  fi
}

configure_schedule() {
  echo ""
  info "Select days to shut down (space-separated numbers, e.g. '1 3 5'):"
  for i in "${!DAYS_OF_WEEK[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${DAYS_OF_WEEK[$i]}"
  done
  read -rp "Days: " day_input

  local selected_days=()
  for num in $day_input; do
    if [[ "$num" =~ ^[1-7]$ ]]; then
      selected_days+=("${DAYS_OF_WEEK[$((num-1))]}")
    fi
  done

  if [[ ${#selected_days[@]} -eq 0 ]]; then
    err "No valid days selected."
    return 1
  fi

  SCHEDULE_DAYS=""
  for day in "${selected_days[@]}"; do
    if [[ -n "$SCHEDULE_DAYS" ]]; then
      SCHEDULE_DAYS+=","
    fi
    SCHEDULE_DAYS+="$day"
  done

  echo ""
  read -rp "Shutdown time (HH:MM, 24h format, e.g. 23:00): " SCHEDULE_TIME
  if [[ ! "$SCHEDULE_TIME" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    err "Invalid time format."
    return 1
  fi

  save_config
  update_timer_time "$SCHEDULE_TIME"
  enable_timer
  log "Schedule set: ${SCHEDULE_DAYS} at ${SCHEDULE_TIME}"
}

remove_schedule() {
  disable_timer
  rm -f "$CONFIG_FILE"
  rm -f "$SHUTDOWN_SCRIPT"
  rm -f "$SERVICE_FILE"
  rm -f "$TIMER_FILE"
  systemctl daemon-reload
  log "Schedule removed and systemd units cleaned up."
}

show_banner() {
  clear
  echo -e "${CYAN}"
  echo '  ╔══════════════════════════════════════╗'
  echo '  ║        Deb SleepWithMe               ║'
  echo '  ║   Scheduled Server Shutdown Tool     ║'
  echo '  ╚══════════════════════════════════════╝'
  echo -e "${NC}"
}

main() {
  require_root
  load_config

  while true; do
    show_banner
    echo ""
    info "1) Configure shutdown schedule"
    info "2) View current schedule"
    info "3) Remove schedule"
    info "4) Exit"
    echo ""
    read -rp "  Choice [1-4]: " choice

    case "$choice" in
      1) configure_schedule ;;
      2) show_schedule ;;
      3) remove_schedule ;;
      4) log "Goodbye."; exit 0 ;;
      *) err "Invalid choice." ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..."
  done
}

main
