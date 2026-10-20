#!/usr/bin/env bash
# Pardus 25 / Debian 13 - kisitsiz, kalici, promptsuz yazici yonetimi (noninteractive)
set -Eeuo pipefail

### AYARLAR ##############################################################
ENSURE_PACKAGES=1     # 1 => eksik cups bilesenlerini kurar
MASK_CUPSBROWSED=1    # 1 => kuyruk silen cups-browsed devre disi (kalicilik)
OPEN_CUPS_CLI=1       # 1 => cupsd.conf admin limitleri AuthType None (sadece localhost)
##########################################################################

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die(){ log "HATA: $*"; exit 1; }
[[ $(id -u) -eq 0 ]] || die "root olarak calistirin: sudo $0"

BAK="/root/printer-fullfix-backup-$(date +%Y%m%d%H%M%S)"
install -d -m 0700 "$BAK"

### 0) Eksik paketler (varsa dokunulmaz) #################################
if [[ "$ENSURE_PACKAGES" == "1" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq cups cups-client cups-pk-helper cups-udev system-config-printer >/dev/null
    log "Paket kontrolu tamam"
fi

### 1) Polkit kurali: TUM kullanıcılara kosulsuz yetki (guide.txt) #######
RULE_FILE="/etc/polkit-1/rules.d/10-printer-auth.rules"
install -d -m 0755 /etc/polkit-1/rules.d
[[ -f "$RULE_FILE" ]] && cp -a "$RULE_FILE" "$BAK/" || true
cat > "$RULE_FILE" <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.opensuse.cupspkhelper.mechanism.") === 0) {
        return polkit.Result.YES;
    }
});
EOF
chown root:root "$RULE_FILE"; chmod 0644 "$RULE_FILE"
log "Polkit kurali yazildi (kosulsuz YES): $RULE_FILE"

### 2) cupsd.conf: admin limitlerinde parola/kisit kaldir (localhost) ####
CUPSD_CONF="/etc/cups/cupsd.conf"
if [[ "$OPEN_CUPS_CLI" == "1" && -f "$CUPSD_CONF" ]]; then
    cp -a "$CUPSD_CONF" "$BAK/"
    awk '
      BEGIN{ ADDR="  Order deny,allow\n  Deny from all\n  Allow from 127.0.0.1\n  Allow from localhost\n" }
      function isadmin(s){ return (s ~ /CUPS-Add-Modify-Printer/ || s ~ /CUPS-Delete-Printer/ ||
                                   s ~ /CUPS-Add-Modify-Class/  || s ~ /CUPS-Delete-Class/ ||
                                   s ~ /CUPS-Set-Default/) }
      /^[[:space:]]*<Limit/   { inlim = isadmin($0); addr=0; skip=0; print; next }
      /^[[:space:]]*<\/Limit>/ { if (inlim && !addr) printf "%s", ADDR; inlim=0; print; next }
      inlim && /^[[:space:]]*AuthType/            { print "  AuthType None"; next }
      inlim && /^[[:space:]]*Require[[:space:]]+user/ { print "  # Require user kaldirildi (kurum politikasi: kisitsiz)"; next }
      inlim && /^[[:space:]]*Order/               { if(!addr){ printf "%s", ADDR; addr=1 } skip=1; next }
      inlim && skip && /^[[:space:]]*(Allow|Deny)/ { next }
      { print }
    ' "$CUPSD_CONF" > "${CUPSD_CONF}.new" && mv "${CUPSD_CONF}.new" "$CUPSD_CONF"
    command -v cupsd >/dev/null && cupsd -t && log "cupsd.conf sozdimi OK"
    log "cupsd.conf admin limitleri: AuthType None + localhost"
fi

### 3) Kalicilik: cups-browsed maskele, cups enable ######################
if [[ "$MASK_CUPSBROWSED" == "1" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^cups-browsed\.service'; then
    systemctl mask --now cups-browsed.service >/dev/null 2>&1 || true
    log "cups-browsed maskelendi (kuyruk silme engellendi)"
fi
systemctl enable cups cups.socket cups.path >/dev/null 2>&1 || true

### 4) Servisleri uygula ##################################################
systemctl restart polkit    2>/dev/null || systemctl restart polkitd 2>/dev/null || true
systemctl restart cups
log "polkit + cups yeniden baslatildi"

### 5) Dogrulama ##########################################################
log "--- Dogrulama ---"
ls -l "$RULE_FILE"
lpstat -v 2>/dev/null || true
systemctl is-active cups polkit 2>/dev/null || true
log "Yedekler: $BAK"
log "TAMAMLANDI: tum kullaniciar icin promptsuz, kalici yazici ekleme/kaldirma aktif."