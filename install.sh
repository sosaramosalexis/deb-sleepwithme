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

format_12h() {
  local h m ampm
  h="${1%%:*}"
  m="${1##*:}"
  if [[ "$h" -eq 0 ]]; then
    ampm="AM"; h=12
  elif [[ "$h" -lt 12 ]]; then
    ampm="AM"
  elif [[ "$h" -eq 12 ]]; then
    ampm="PM"
  else
    ampm="PM"; h=$((h-12))
  fi
  printf "%d:%02d %s" "$h" "$m" "$ampm"
}

show_schedule() {
  echo ""
  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "No schedule configured."
    return
  fi
  info "Current schedule:"
  local day_names_map
  day_names_map=([mon]="Monday" [tue]="Tuesday" [wed]="Wednesday" [thu]="Thursday" [fri]="Friday" [sat]="Saturday" [sun]="Sunday")
  local display_days=""
  IFS=',' read -ra days <<< "$SCHEDULE_DAYS"
  for d in "${days[@]}"; do
    [[ -n "$display_days" ]] && display_days+=", "
    display_days+="${day_names_map[$d]:-$d}"
  done
  echo "  Days: ${display_days:-none}"
  local t12
  t12=$(format_12h "${SCHEDULE_TIME}")
  echo "  Time: ${SCHEDULE_TIME}  (${t12})"
  if systemctl is-active --quiet "${SERVICE_NAME}.timer" 2>/dev/null; then
    echo "  Status: ${GREEN}active${NC}"
    echo "  Next run: $(systemctl show -p NextElapseUSecMonotonic "${SERVICE_NAME}.timer" 2>/dev/null | cut -d= -f2 || echo 'unknown')"
  else
    echo "  Status: ${RED}inactive${NC}"
  fi
}

configure_schedule() {
  echo ""

  local selected_days=()
  local day_names=("Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday")
  local toggle=("" "" "" "" "" "" "")

  info "Select shutdown days (type a number to toggle it, then 'd' when done):"
  echo ""
  while true; do
    for i in "${!DAYS_OF_WEEK[@]}"; do
      local mark=" "
      [[ -n "${toggle[$i]}" ]] && mark="X"
      printf "  [%s] %d) %-9s (%s)\n" "$mark" $((i+1)) "${DAYS_OF_WEEK[$i]}" "${day_names[$i]}"
    done
    echo ""
    read -rp "  Toggle day number (or 'd' when done): " inp
    case "$inp" in
      [Dd]) break ;;
      [1-7])
        local idx=$((inp-1))
        if [[ -n "${toggle[$idx]}" ]]; then
          toggle[$idx]=""
        else
          toggle[$idx]="X"
        fi
        echo ""
        ;;
      *) err "Enter 1-7 to toggle, or 'd' to finish."; echo "" ;;
    esac
  done

  for i in "${!toggle[@]}"; do
    [[ -n "${toggle[$i]}" ]] && selected_days+=("${DAYS_OF_WEEK[$i]}")
  done

  if [[ ${#selected_days[@]} -eq 0 ]]; then
    err "No days selected."
    return 1
  fi

  SCHEDULE_DAYS=""
  for day in "${selected_days[@]}"; do
    [[ -n "$SCHEDULE_DAYS" ]] && SCHEDULE_DAYS+=","
    SCHEDULE_DAYS+="$day"
  done

  echo ""
  info "Select shutdown time (24h format):"
  echo ""
  echo "  Reference:"
  echo "    00:00 = 12:00 AM  (midnight)"
  echo "    01:00 =  1:00 AM"
  echo "    02:00 =  2:00 AM"
  echo "    03:00 =  3:00 AM"
  echo "    04:00 =  4:00 AM"
  echo "    05:00 =  5:00 AM"
  echo "    06:00 =  6:00 AM"
  echo "    07:00 =  7:00 AM"
  echo "    08:00 =  8:00 AM"
  echo "    09:00 =  9:00 AM"
  echo "    10:00 = 10:00 AM"
  echo "    11:00 = 11:00 AM"
  echo "    12:00 = 12:00 PM  (noon)"
  echo "    13:00 =  1:00 PM"
  echo "    14:00 =  2:00 PM"
  echo "    15:00 =  3:00 PM"
  echo "    16:00 =  4:00 PM"
  echo "    17:00 =  5:00 PM"
  echo "    18:00 =  6:00 PM"
  echo "    19:00 =  7:00 PM"
  echo "    20:00 =  8:00 PM"
  echo "    21:00 =  9:00 PM"
  echo "    22:00 = 10:00 PM"
  echo "    23:00 = 11:00 PM"
  echo ""
  read -rp "  Time (HH:MM, e.g. 23:00 for 11:00 PM): " SCHEDULE_TIME

  if [[ ! "$SCHEDULE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    err "Invalid time. Use HH:MM in 24h format (00:00 - 23:59)."
    return 1
  fi

  save_config
  update_timer_time "$SCHEDULE_TIME"
  enable_timer
  local day_names_map
  day_names_map=([mon]="Monday" [tue]="Tuesday" [wed]="Wednesday" [thu]="Thursday" [fri]="Friday" [sat]="Saturday" [sun]="Sunday")
  local display_days=""
  IFS=',' read -ra days <<< "$SCHEDULE_DAYS"
  for d in "${days[@]}"; do
    [[ -n "$display_days" ]] && display_days+=", "
    display_days+="${day_names_map[$d]:-$d}"
  done
  local t12
  t12=$(format_12h "${SCHEDULE_TIME}")
  log "Schedule set: ${display_days} at ${SCHEDULE_TIME} (${t12})"
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
