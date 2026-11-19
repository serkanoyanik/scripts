#!/usr/bin/env bash
# yazici-yonetimi.sh
# Debian 13 / Pardus 25 için basit yazıcı yönetim scripti
#
# İKİ KATMANLI MODEL:
#  1. katman: cupsd.conf (cupsctl) -> Browsing Off / protokoller none
#  2. katman: avahi-daemon.conf    -> use-ipv4=no + use-ipv6=no
# Menüdeki 6) Kapat önce 1. katmanı uygular; kalıntı keşif kalırsa
# onayınızla 2. katmanı da uygular.

set -uo pipefail

LOG_FILE="/var/log/yazici-yonetimi.log"
BACKUP_DIR="/var/lib/yazici-yonetimi/backups"
LOCK_FILE="/run/lock/yazici-yonetimi.lock"

CUPS_SERVICE="cups.service"
CUPSD_CONF="/etc/cups/cupsd.conf"
CUPS_BROWSED_SERVICE="cups-browsed.service"
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"
AVAHI_SERVICE="avahi-daemon.service"
POLKIT_RULE_DIR="/etc/polkit-1/rules.d"
POLKIT_RULE_FILE="${POLKIT_RULE_DIR}/10-printer-auth.rules"
POLKIT_SERVICE="polkit.service"

# ---------------------------------------------------------------
# Renkler (yalnızca terminal çıktısı; log dosyası düz metin kalır)
# ---------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  RESET=$'\e[0m'
  DIM=$'\e[2m'
  RED=$'\e[1;31m'
  GREEN=$'\e[32m'
  YELLOW=$'\e[33m'
  YELLOW_BOLD=$'\e[1;33m'
  CYAN=$'\e[36m'
else
  RESET="" DIM="" RED="" GREEN="" YELLOW="" YELLOW_BOLD="" CYAN=""
fi

baslik()     { printf '%s\n' "${YELLOW_BOLD}$*${RESET}"; }
altbaslik()  { printf '%s\n' "${CYAN}$*${RESET}"; }
bilginotu()  { printf '%s\n' "${DIM}$*${RESET}"; }

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() { log "INFO" "$*"; echo "$*"; }
warn() { log "WARN" "$*"; printf '%s\n' "${YELLOW}UYARI: $*${RESET}" >&2; }
error() { log "ERROR" "$*"; printf '%s\n' "${RED}HATA: $*${RESET}" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Bu script root yetkisiyle çalıştırılmalıdır."
    exit 1
  fi
}

require_root

if ! command -v systemctl >/dev/null 2>&1; then
  error "systemctl bulunamadı. Bu script systemd tabanlı bir sistem gerektirir."
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$BACKUP_DIR")" /run/lock 2>/dev/null || true

exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    error "Script zaten çalışıyor."
    exit 1
  fi
else
  warn "flock bulunamadı. Aynı anda çalıştırma kilidi kullanılamıyor."
fi

trap 'echo; info "Script sonlandırıldı."; exit 130' INT

service_exists() {
  systemctl cat "$1" >/dev/null 2>&1 || [[ -n "$(systemctl list-unit-files "$1" --no-legend 2>/dev/null)" ]]
}

if ! service_exists "$POLKIT_SERVICE" && service_exists "polkitd.service"; then
  POLKIT_SERVICE="polkitd.service"
fi

pause() {
  echo
  read -rp "${DIM}Devam etmek için Enter'a basın...${RESET}" _ || exit 0
}

confirm() {
  local prompt="$1" ans
  read -rp "$prompt [E/h]: " ans
  [[ "$ans" =~ ^([eE]|[eE][vV][eE][tT])$ ]]
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    mkdir -p "$BACKUP_DIR"
    local ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_DIR/$(basename "$file").$ts.bak"
    if cp -a "$file" "$backup" 2>/dev/null; then
      info "Yedek alındı: $backup"
    else
      warn "Yedek alınamadı: $file"
    fi
  fi
}

restore_latest_backup() {
  local file="$1" latest
  latest="$(ls -1t "$BACKUP_DIR"/"$(basename "$file")".*.bak 2>/dev/null | head -n1)"
  if [[ -n "$latest" ]]; then
    cp -a "$latest" "$file"
    info "Yedek geri yüklendi: $latest"
  else
    warn "Geri yüklenecek yedek bulunamadı: $file"
  fi
}

# ---------------------------------------------------------------
# cups-browsed
# ---------------------------------------------------------------

show_cups_browsed_status() {
  echo
  baslik "=== Ağ yazıcılarının otomatik eklenmesi ==="

  if ! service_exists "$CUPS_BROWSED_SERVICE"; then
    warn "$CUPS_BROWSED_SERVICE bulunamadı. cups-browsed paketi kurulu olmayabilir."
    return 0
  fi

  echo "Servis   : $CUPS_BROWSED_SERVICE"
  echo "Çalışma  : $(systemctl is-active "$CUPS_BROWSED_SERVICE" 2>/dev/null || true)"
  echo "Açılışta : $(systemctl is-enabled "$CUPS_BROWSED_SERVICE" 2>/dev/null || true)"
  echo
  systemctl --no-pager --lines=5 status "$CUPS_BROWSED_SERVICE" 2>/dev/null || true
}

stop_cups_browsed() {
  if ! service_exists "$CUPS_BROWSED_SERVICE"; then
    error "$CUPS_BROWSED_SERVICE bulunamadı."
    return 1
  fi

  info "cups-browsed durduruluyor ve açılışta devre dışı bırakılıyor..."
  systemctl stop "$CUPS_BROWSED_SERVICE" 2>/dev/null || warn "Servis durdurulamadı."
  systemctl disable "$CUPS_BROWSED_SERVICE" 2>/dev/null || warn "Servis devre dışı bırakılamadı."
  show_cups_browsed_status
}

start_cups_browsed() {
  if ! service_exists "$CUPS_BROWSED_SERVICE"; then
    error "$CUPS_BROWSED_SERVICE bulunamadı."
    return 1
  fi

  info "cups-browsed açılıyor ve açılışta etkinleştiriliyor..."
  systemctl enable "$CUPS_BROWSED_SERVICE" 2>/dev/null || warn "Servis etkinleştirilemedi."
  systemctl start "$CUPS_BROWSED_SERVICE" 2>/dev/null || warn "Servis başlatılamadı."
  show_cups_browsed_status
}

# ---------------------------------------------------------------
# CUPS keşfi (1. katman) + avahi (2. katman)
# ---------------------------------------------------------------

apply_cups_browsing() {
  local mode="$1"

  backup_file "$CUPSD_CONF"

  if command -v cupsctl >/dev/null 2>&1; then
    if [[ "$mode" == "off" ]]; then
      cupsctl Browsing=Off BrowseLocalProtocols=none BrowseRemoteProtocols=none \
        || warn "cupsctl ayarı uygulanamadı."
    else
      cupsctl Browsing=On BrowseLocalProtocols=dnssd BrowseRemoteProtocols=dnssd \
        || warn "cupsctl ayarı uygulanamadı."
    fi
    info "Ayarlar cupsctl ile yazıldı."
  else
    warn "cupsctl bulunamadı; cupsd.conf sed ile düzenleniyor."
    if [[ "$mode" == "off" ]]; then
      apply_cupsd_directive "Browsing" "Off"
      apply_cupsd_directive "BrowseLocalProtocols" "none"
      apply_cupsd_directive "BrowseRemoteProtocols" "none"
    else
      apply_cupsd_directive "Browsing" "On"
      apply_cupsd_directive "BrowseLocalProtocols" "dnssd"
      apply_cupsd_directive "BrowseRemoteProtocols" "dnssd"
    fi
    if command -v cupsd >/dev/null 2>&1; then
      if ! cupsd -t; then
        error "cupsd.conf sözdizimi hatası; geri alınıyor."
        restore_latest_backup "$CUPSD_CONF"
        return 1
      fi
    fi
  fi
}

apply_cupsd_directive() {
  local key="$1" value="$2"

  if grep -Eqi "^[#[:space:]]*${key}([[:space:]]|$)" "$CUPSD_CONF"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "$CUPSD_CONF"
  else
    printf '%s %s\n' "$key" "$value" >> "$CUPSD_CONF"
  fi
}

apply_avahi_key() {
  local key="$1" value="$2"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$AVAHI_CONF"; then
    sed -ri "s/^[#[:space:]]*${key}[[:space:]]*=.*/${key}=${value}/" "$AVAHI_CONF"
  else
    if grep -Eq '^[[:space:]]*\[server\]' "$AVAHI_CONF"; then
      sed -ri "/^[[:space:]]*\[server\]/a ${key}=${value}" "$AVAHI_CONF"
    else
      printf '[server]\n%s=%s\n' "$key" "$value" >> "$AVAHI_CONF"
    fi
  fi
}

apply_avahi_discovery() {
  local value="$1"

  if [[ ! -f "$AVAHI_CONF" ]]; then
    error "$AVAHI_CONF bulunamadı."
    return 1
  fi

  backup_file "$AVAHI_CONF"
  apply_avahi_key "use-ipv4" "$value"
  apply_avahi_key "use-ipv6" "$value"
  info "Avahi ayarı güncellendi: use-ipv4=${value}, use-ipv6=${value}"
}

# lpstat -e (kutunun gördüğü) ile lpstat -v (yapılandırılmış) farkı = keşfedilenler
list_discovered_remaining() {
  comm -13 \
    <(lpstat -v 2>/dev/null | sed 's/^device for //; s/:.*//' | sort) \
    <(lpstat -e 2>/dev/null | sort) 2>/dev/null
}

restart_cups() {
  if service_exists "$CUPS_SERVICE"; then
    systemctl restart "$CUPS_SERVICE" 2>/dev/null || warn "$CUPS_SERVICE yeniden başlatılamadı."
  else
    warn "$CUPS_SERVICE bulunamadı."
  fi
}

show_cups_discovery_status() {
  echo
  baslik "=== Yazdır iletişim kutusunda ağ yazıcılarının gösterilmesi ==="

  altbaslik "Efektif CUPS ayarları (cupsctl):"
  if command -v cupsctl >/dev/null 2>&1; then
    cupsctl 2>/dev/null | grep -iE '^(Browsing|BrowseLocalProtocols|BrowseRemoteProtocols)' || echo "  (satır yok)"
  else
    echo "  cupsctl bulunamadı."
  fi

  echo
  altbaslik "cupsd.conf satırları:"
  if [[ -f "$CUPSD_CONF" ]]; then
    grep -Eni '^[#[:space:]]*(Browsing|BrowseLocalProtocols|BrowseRemoteProtocols)' "$CUPSD_CONF" || echo "  (satır yok)"
  else
    warn "$CUPSD_CONF bulunamadı."
  fi

  echo
  echo "CUPS servisi : $(systemctl is-active "$CUPS_SERVICE" 2>/dev/null || true)"
  echo "Avahi servisi: $(systemctl is-active "$AVAHI_SERVICE" 2>/dev/null || true)"

  echo
  altbaslik "Yapılandırılmış yazıcılar (lpstat -v):"
  lpstat -v 2>/dev/null || warn "lpstat çalıştırılamadı."

  echo
  altbaslik "Yazdırma kutusunun gördüğü hedefler (lpstat -e):"
  lpstat -e 2>/dev/null || warn "lpstat çalıştırılamadı."

  echo
  local remaining
  remaining="$(list_discovered_remaining)"
  if [[ -n "$remaining" ]]; then
    warn "Hâlâ keşfedilen yazıcılar:"
    echo "$remaining"
  else
    printf '%s\n' "${GREEN}Keşfedilen yazıcı yok (liste temiz).${RESET}"
  fi
}

set_cups_discovery() {
  local mode="$1"

  apply_cups_browsing "$mode" || return 1
  restart_cups

  if [[ "$mode" == "off" ]]; then
    local remaining
    remaining="$(list_discovered_remaining)"
    if [[ -n "$remaining" ]]; then
      warn "CUPS katmanına rağmen keşfedilen yazıcılar kaldı:"
      echo "$remaining"
      if confirm "Avahi IPv4/IPv6 keşfi de kapatılsın mı? (ağ tarayıcıları ve elle ekleme sihirbazının keşfi de etkilenir)"; then
        apply_avahi_discovery no || return 1
        if service_exists "$AVAHI_SERVICE"; then
          systemctl restart "$AVAHI_SERVICE" 2>/dev/null || warn "$AVAHI_SERVICE yeniden başlatılamadı."
        fi
        restart_cups
      fi
    else
      printf '%s\n' "${GREEN}Keşif listesi temiz.${RESET}"
    fi
  else
    # Aç modunda avahi daha önce kapatılmışsa geri aç
    if [[ -f "$AVAHI_CONF" ]] && grep -Eq '^[[:space:]]*use-ipv4[[:space:]]*=[[:space:]]*no' "$AVAHI_CONF"; then
      if confirm "Avahi IPv4/IPv6 keşfi tekrar açılsın mı?"; then
        apply_avahi_discovery yes || return 1
        if service_exists "$AVAHI_SERVICE"; then
          systemctl restart "$AVAHI_SERVICE" 2>/dev/null || warn "$AVAHI_SERVICE yeniden başlatılamadı."
        fi
        restart_cups
      fi
    fi
  fi

  show_cups_discovery_status
}

# ---------------------------------------------------------------
# polkit
# ---------------------------------------------------------------

restart_polkit() {
  if service_exists "$POLKIT_SERVICE"; then
    systemctl restart "$POLKIT_SERVICE" 2>/dev/null || warn "$POLKIT_SERVICE yeniden başlatılamadı. Oturumu kapatıp açmanız gerekebilir."
  else
    warn "Polkit servisi bulunamadı. Oturumu kapatıp açmanız gerekebilir."
  fi
}

add_polkit_rule() {
  mkdir -p "$POLKIT_RULE_DIR" 2>/dev/null || true
  backup_file "$POLKIT_RULE_FILE"

  cat > "$POLKIT_RULE_FILE" <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.opensuse.cupspkhelper.mechanism.") === 0) {
        return polkit.Result.YES;
    }
});
EOF

  chown root:root "$POLKIT_RULE_FILE" 2>/dev/null || warn "Dosya sahipliği ayarlanamadı."
  chmod 644 "$POLKIT_RULE_FILE" 2>/dev/null || warn "Dosya izni ayarlanamadı."

  info "Şifresiz yazıcı ekleme/kaldırma kuralı tüm kullanıcılar için eklendi."
  restart_polkit
}

remove_polkit_rule() {
  if [[ ! -f "$POLKIT_RULE_FILE" ]]; then
    warn "Polkit kuralı zaten yok."
    return 0
  fi

  backup_file "$POLKIT_RULE_FILE"
  rm -f "$POLKIT_RULE_FILE"

  info "Şifresiz yazıcı ekleme/kaldırma kuralı kaldırıldı."
  restart_polkit
}

# ---------------------------------------------------------------
# system-config-printer
# ---------------------------------------------------------------

install_system_config_printer() {
  info "apt update çalıştırılıyor..."
  if ! apt update; then
    warn "apt update sırasında hata oluştu."
  fi

  info "system-config-printer kuruluyor..."
  if DEBIAN_FRONTEND=noninteractive apt install -y system-config-printer; then
    info "system-config-printer kurulumu tamamlandı."
  else
    error "system-config-printer kurulumu başarısız oldu."
    return 1
  fi

  if command -v system-config-printer >/dev/null 2>&1; then
    info "Komut kullanılabilir: $(command -v system-config-printer)"
  else
    warn "Paket kuruldu ancak komut bulunamadı; dpkg durumunu kontrol edin."
  fi
}

# ---------------------------------------------------------------
# Menü
# ---------------------------------------------------------------

main_menu() {
  while true; do
    clear

    cat <<EOF
${YELLOW_BOLD}==================================================${RESET}
${YELLOW_BOLD} Yazıcı Yönetimi${RESET}
${YELLOW_BOLD}==================================================${RESET}

${YELLOW}Ağ yazıcılarının otomatik eklenmesi${RESET}
1) Servis durumunu göster
2) Servisi kapat (durdur)
3) Servisi aç (başlat)

${YELLOW}Yazdır iletişim kutusunda ağ yazıcılarının gösterilmesi${RESET}
${DIM}(Bilgi: Önce CUPS keşfini kapatır; gerekirse avahi katmanını sorar.)
${DIM}(Önemli: Kapatıldığında yeni ağ yazıcısı ekleme etkilenir.)${RESET}
4) Durum kontrolü
5) Aç (Ağ yazıcılarını göster)
6) Kapat (Ağ yazıcılarını gösterme)

${YELLOW}Yazıcı Ekleme/Kaldırma Yetkisi${RESET}
7) Şifresiz yazıcı ekleme/kaldırma kuralı ekle
8) Kuralı kaldır

${YELLOW}Yazıcı Yönetim Aracı${RESET}
9) system-config-printer paketini yükle

${CYAN}0) Çıkış${RESET}
${YELLOW_BOLD}==================================================${RESET}
EOF

    if ! read -rp "${CYAN}Seçim:${RESET} " choice; then
      echo
      break
    fi

    case "$choice" in
      1) show_cups_browsed_status ;;
      2) stop_cups_browsed ;;
      3) start_cups_browsed ;;
      4) show_cups_discovery_status ;;
      5) set_cups_discovery on ;;
      6) set_cups_discovery off ;;
      7) add_polkit_rule ;;
      8) remove_polkit_rule ;;
      9) install_system_config_printer ;;
      0) info "Çıkış yapılıyor."; exit 0 ;;
      *) warn "Geçersiz seçim." ;;
    esac

    pause
  done
}

main_menu