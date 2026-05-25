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
  if ! command -v whiptail &>/dev/null; then
    apt-get install -y whiptail 2>/dev/null || {
      err "whiptail is required. Install: apt-get install whiptail"
      return 1
    }
  fi

  local days_arr=() day selected display_days t12

  selected=$(whiptail --checklist --title "Deb SleepWithMe" \
    "Select shutdown days (\xE2\x86\x91\xE2\x86\x93 arrows to move, SPACE to toggle, ENTER to confirm):" \
    16 55 7 \
    "mon" "Monday"    OFF \
    "tue" "Tuesday"   OFF \
    "wed" "Wednesday" OFF \
    "thu" "Thursday"  OFF \
    "fri" "Friday"    OFF \
    "sat" "Saturday"  OFF \
    "sun" "Sunday"    OFF \
    3>&1 1>&2 2>&3) || return 1

  eval "days_arr=($selected)" 2>/dev/null
  if [[ ${#days_arr[@]} -eq 0 ]]; then
    err "No days selected."
    return 1
  fi

  SCHEDULE_DAYS=""
  for day in "${days_arr[@]}"; do
    [[ -n "$SCHEDULE_DAYS" ]] && SCHEDULE_DAYS+=","
    SCHEDULE_DAYS+="$day"
  done

  SCHEDULE_TIME=$(whiptail --inputbox --title "Deb SleepWithMe" \
    "Enter shutdown time (24h HH:MM)\n\n\
00-05 AM  midnight-5am    12-17 PM  noon-5pm\n\
06-11 AM  6am-11am        18-23 PM  6pm-11pm\n\n\
Example: 23:00 = 11:00 PM" \
    13 55 "23:00" 3>&1 1>&2 2>&3) || return 1

  if [[ ! "$SCHEDULE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    whiptail --msgbox --title "Invalid Time" \
      "Use HH:MM in 24h format.\nHours: 00-23, Minutes: 00-59" 8 40
    return 1
  fi

  local day_names_map
  day_names_map=([mon]="Monday" [tue]="Tuesday" [wed]="Wednesday" [thu]="Thursday" [fri]="Friday" [sat]="Saturday" [sun]="Sunday")
  display_days=""
  IFS=',' read -ra days <<< "$SCHEDULE_DAYS"
  for d in "${days[@]}"; do
    [[ -n "$display_days" ]] && display_days+=", "
    display_days+="${day_names_map[$d]:-$d}"
  done
  t12=$(format_12h "${SCHEDULE_TIME}")

  if whiptail --yesno --title "Confirm Schedule" \
    "Shutdown on: ${display_days}\nAt: ${SCHEDULE_TIME} (${t12})\n\nApply this schedule?" 10 55; then
    save_config
    update_timer_time "$SCHEDULE_TIME"
    enable_timer
    log "Schedule set: ${display_days} at ${SCHEDULE_TIME} (${t12})"
  else
    info "Schedule cancelled."
    return 1
  fi
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
