#!/usr/bin/env bash
# simes-pcsc-fix — SiMES Pardus 25 PC/SC uyumluluk + sürüm yükseltme aracı.
# v3.2.0-9: YALNIZCA Pardus 25. İki katman (kullanıcı/sistem).
#   SimesIstemci yoksa KURAR; eski sürümse güvenli YÜKSELTİR; varsa yamalar.
#   Tüm kullanıcı çıktıları Türkçe karakterlidir.
set -u
umask 022
VERSION="3.2.0-9"
MARKER="# simes-pcsc-fix: Pardus 25 libpcsclite.so.1 uyumlulugu - kaldirmak icin: simes-pcsc-fix --revert"
STAMP_NAME=".simes-pcsc-fix-version"
PROP_PREFIX="-Dsun.security.smartcardio.library="
PROP_KEY="sun.security.smartcardio.library"
PROP_RE='^-Dsun[.]security[.]smartcardio[.]library='
AGENT_LIB_PREFIX="-Dsimes.pcsc.lib="
AGENT_ARG_PREFIX="-javaagent:"
AGENT_JAR_NAME="simes-pcsc-agent.jar"
AGENT_ARG="-javaagent:${AGENT_JAR_NAME}"
EMBED_BEGIN="#@@EMBED-AGENT-BEGIN@@"
EMBED_END="#@@EMBED-AGENT-END@@"
BARE_OVERRIDE="libpcsclite.so.1.0.0"
SIMES_PAGE="https://www.hmb.gov.tr/simes-kurulum-dosyalari"
DEFAULT_SIMES_URL="https://ms.hmb.gov.tr/uploads/2026/10/simes-desktop-agent-3.2.0-42-8dbea2f9dcb73a61.zip"
UA="Mozilla/5.0 (X11; Linux x86_64) simes-pcsc-fix/$VERSION"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
QUIET=0
MODE="repair"
TARGET_DIR=""
ALL=0
BOOTSTRAP=0
NO_UPGRADE=0
FORCE_REINSTALL=0
SYSTEM_LAYER_DONE=0
SYSTEM_MISSING=""
SYSTEM_HINT_SHOWN=0
SYSTEM_STRICT="${SIMES_REQUIRE_SYSTEM:-0}"
PROGRESS_MODE="${SIMES_PROGRESS:-dots}"
PROGRESS_STEP="${SIMES_PROGRESS_STEP:-5}"
PROGRESS_WIDTH=40
CREDIT="serkanoyanik"
SIMES_URL=""
SIMES_ZIP=""
SIMES_DL=""
SIMES_USER=""
log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }
show_completion() {
    printf '\n'
    printf 'Simes E-İmza Pardus 25 yama işlemleri tamamlanmıştır...\n'
}
usage() {
local n="${0##*/}"
cat <<EOF
Kullanım: $n [SEÇENEK]
(seçenek yok)     SimesIstemci yoksa KURAR; eski sürümse YÜKSELTİR; varsa yamalar
--system-setup    SİSTEM katmanı (root, makine başına BİR KEZ)
--check           Durum raporu (yazmaz, kurmaz, silmez)
--revert          Eklenen satırları, ajanı ve sürüm damgasını kaldır
--verify          SiMES'in kendi kodu okuyucuyu görüyor mu (teşhis)
--install         Kurulumu açıkça tetikle
--force-reinstall Sürüm ne olursa olsun kaldırıp yeniden kur
--no-upgrade      Sürüm yükseltme adımını atla (yalnızca yamala)
--dir YOL         Yalnızca bu kurulum dizinini işle
--all             Tüm kullanıcıları işle (root)
--no-deps         akia/pcscd denetimini atla
--progress=KİP    dots | simple | bar | none (varsayılan: dots)
--simple-progress Yalnızca yüzde + rakam
--bar-progress    Tek satır blok çubuk (gerçek terminal)
--no-progress     İlerleme gösterme
--quiet           Yalnızca hata bas
--version         Sürüm
--help            Bu metin

Ortam değişkenleri:
  SIMES_REQUIRE_SYSTEM=1  Sistem katmanı eksikse durdur (katı kip)
  SIMES_AUTH_TRIES=60     Portal bekleme deneme sayısı (x5 sn)
  SIMES_PROGRESS_STEP=5   simple kipinde yüzde adımı
  SIMES_DEBUG=1           URL/sayfa tanılama çıktısı

Çıkış kodları: 0 başarılı, 1 eksik katman/onarım gerekli, 2 hata.
Yalnızca Pardus 25.x'te çalışır.
EOF
}
while [ $# -gt 0 ]; do
case "$1" in
--check)           MODE="check" ;;
--revert)          MODE="revert" ;;
--verify)          MODE="verify" ;;
--system-setup)    MODE="system" ;;
--install)         BOOTSTRAP=1 ;;
--force-reinstall) FORCE_REINSTALL=1 ;;
--no-upgrade)      NO_UPGRADE=1 ;;
--all)             ALL=1 ;;
--no-deps)         NO_DEPS=1 ;;
--quiet)           QUIET=1 ;;
--progress=*)      PROGRESS_MODE="${1#*=}" ;;
--simple-progress) PROGRESS_MODE="simple" ;;
--bar-progress)    PROGRESS_MODE="bar" ;;
--no-progress)     PROGRESS_MODE="none" ;;
--version) printf '%s %s\n' "${0##*/}" "$VERSION"; exit 0 ;;
--help|-h) usage; exit 0 ;;
--dir)
[ $# -ge 2 ] || { err "--dir bir yol ister"; exit 2; }
TARGET_DIR="$2"; shift ;;
*) err "Bilinmeyen argüman: $1"; usage >&2; exit 2 ;;
esac
shift
done
: "${NO_DEPS:=0}"
# --------------------------------------------------------------------------
# İşletim sistemi kilidi
# --------------------------------------------------------------------------
check_os() {
local id ver ad
[ -r /etc/os-release ] || { err "/etc/os-release okunamadı."; exit 2; }
. /etc/os-release
id="${ID:-}"; ver="${VERSION_ID:-}"; ad="${PRETTY_NAME:-$id}"
case "$id" in
pardus) ;;
*) case "$ad" in *[Pp]ardus*) ;; *)
     err "Bu betik yalnızca Pardus 25 içindir. Tespit edilen: ${ad:-bilinmiyor}"
     err "İşlem durduruldu; hiçbir dosya değiştirilmedi."; exit 2 ;;
   esac ;;
esac
case "$ver" in
25|25.*) log "İşletim sistemi: ${ad:-Pardus $ver}" ;;
*)
err "Bu betik yalnızca Pardus 25.x için tasarlanmıştır."
err "Tespit edilen sürüm: ${ver:-bilinmiyor} (${ad:-bilinmiyor})"
err "Pardus 23'te PC/SC paketleri zaten uyumludur."
err "İşlem durduruldu; hiçbir dosya değiştirilmedi."
exit 2 ;;
esac
}
check_os
# --------------------------------------------------------------------------
# Tekil sistem mesajları
# --------------------------------------------------------------------------
sys_missing_add() {
case ",${SYSTEM_MISSING// /}," in
*",$1,"*) return 0 ;;
esac
SYSTEM_MISSING="${SYSTEM_MISSING:+$SYSTEM_MISSING, }$1"
return 0
}
system_hint() {
[ "$SYSTEM_HINT_SHOWN" -eq 1 ] && return 0
SYSTEM_HINT_SHOWN=1
warn "Yönetici bu makinede BİR KEZ: sudo $0 --system-setup"
return 0
}
# --------------------------------------------------------------------------
# PC/SC kütüphanesi ve ajan
# --------------------------------------------------------------------------
multiarch_dir() {
local a
if command -v dpkg-architecture >/dev/null 2>&1; then
a="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)"
[ -n "$a" ] && { printf '%s\n' "$a"; return 0; }
fi
case "$(uname -m)" in
x86_64) printf '%s\n' "x86_64-linux-gnu" ;;
aarch64) printf '%s\n' "aarch64-linux-gnu" ;;
armv7l|armv8l) printf '%s\n' "arm-linux-gnueabihf" ;;
i686|i586) printf '%s\n' "i386-linux-gnu" ;;
riscv64) printf '%s\n' "riscv64-linux-gnu" ;;
*) printf '%s-%s\n' "$(uname -m)" "linux-gnu" ;;
esac
}
lib_path() {
local ma cand
if [ -n "${SIMES_PCSC_FIX_LIB:-}" ]; then
if [ -e "$SIMES_PCSC_FIX_LIB" ]; then printf '%s\n' "$SIMES_PCSC_FIX_LIB"; return 0; fi
err "libpcsclite.so.1 bulunamadı: $SIMES_PCSC_FIX_LIB"; return 2
fi
ma="$(multiarch_dir)"
for cand in "/usr/lib/$ma/libpcsclite.so.1" "/lib/$ma/libpcsclite.so.1" "/usr/lib64/libpcsclite.so.1" "/usr/lib/libpcsclite.so.1"; do
if [ -e "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
done
err "libpcsclite.so.1 bulunamadı (pcsc sürücüleri kurulu mu?)"
return 2
}
AGENT_SRC=""
AGENT_TMP=""
cleanup_agent_tmp() { [ -n "$AGENT_TMP" ] && rm -f -- "$AGENT_TMP"; return 0; }
trap cleanup_agent_tmp EXIT
extract_embedded_agent() {
local tmp
command -v base64 >/dev/null 2>&1 || { err "base64 bulunamadı"; return 1; }
tmp="$(mktemp "${TMPDIR:-/tmp}/simes-pcsc-agent.XXXXXX")" || { err "Geçici dosya açılamadı"; return 1; }
if ! awk -v b="$EMBED_BEGIN" -v e="$EMBED_END" '$0==b{on=1;next}$0==e{on=0}on{sub(/^#/,"");print}' "$SELF" | base64 -d > "$tmp" 2>/dev/null; then
rm -f -- "$tmp"; err "Gömülü ajan çıkarılamadı"; return 1
fi
if [ "$(head -c2 -- "$tmp" 2>/dev/null)" != "PK" ]; then rm -f -- "$tmp"; err "Gömülü ajan geçersiz"; return 1; fi
chmod 0644 "$tmp" 2>/dev/null || true
AGENT_TMP="$tmp"; AGENT_SRC="$tmp"; return 0
}
resolve_agent_jar() {
local cand
AGENT_SRC=""
if [ -n "${SIMES_PCSC_FIX_EMBEDDED_ONLY:-}" ]; then extract_embedded_agent; return $?; fi
if [ -n "${SIMES_PCSC_FIX_AGENT_JAR:-}" ]; then
[ -f "$SIMES_PCSC_FIX_AGENT_JAR" ] && { AGENT_SRC="$SIMES_PCSC_FIX_AGENT_JAR"; return 0; }
return 1
fi
for cand in "$(dirname "$SELF")/agent/$AGENT_JAR_NAME" "$(dirname "$SELF")/$AGENT_JAR_NAME" "/usr/share/simes-pcsc-fix/$AGENT_JAR_NAME"; do
[ -f "$cand" ] && { AGENT_SRC="$cand"; return 0; }
done
extract_embedded_agent
}
# --------------------------------------------------------------------------
# Sistem katmanı
# --------------------------------------------------------------------------
AKIA_PKG="akia"
AKIA_LIB="/usr/lib/libakisp11.so"
AKIA_LIB_CHECK="${SIMES_PCSC_FIX_AKIA_LIB:-$AKIA_LIB}"
akia_installed() { dpkg-query -W -f='${Status}' "$AKIA_PKG" 2>/dev/null | grep -qx 'install ok installed'; }
akia_lib_ok() {
[ -f "$AKIA_LIB_CHECK" ] && [ -r "$AKIA_LIB_CHECK" ] || return 1
[ "$(head -c4 -- "$AKIA_LIB_CHECK" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}
akia_state() {
if ! akia_installed; then printf 'missing\n'
elif akia_lib_ok; then printf 'ok\n'
else printf 'broken\n'; fi
}
akia_state_text() {
case "$1" in
ok) printf 'kurulu ve sağlam\n' ;;
missing) printf 'kurulu değil\n' ;;
broken) printf 'kurulu ama %s eksik/bozuk\n' "$AKIA_LIB" ;;
*) printf 'bilinmiyor\n' ;;
esac
}
apt_run() {
if [ "$(id -u)" -eq 0 ]; then "$@"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo -n "$@"
else return 127; fi
}
apt_hint() {
if [ "$1" = "reinstall" ]; then err "Elle: sudo apt update && sudo apt install --reinstall $AKIA_PKG"
else err "Elle: sudo apt update && sudo apt install $AKIA_PKG"; fi
}
apt_fix_akia() {
local mode="$1" rc
local -a args=(install -y)
[ "$mode" = "reinstall" ] && args+=(--reinstall)
args+=("$AKIA_PKG")
DEBIAN_FRONTEND=noninteractive apt_run apt-get "${args[@]}" </dev/null >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && return 0
if [ "$rc" -eq 127 ]; then
err "akia: root yetkisi gerekiyor (parolasız sudo yok)"
apt_hint "$mode"; return 2
fi
log "akia: apt update..."
DEBIAN_FRONTEND=noninteractive apt_run apt-get update </dev/null >/dev/null 2>&1 || err "akia: apt update başarısız"
DEBIAN_FRONTEND=noninteractive apt_run apt-get "${args[@]}" </dev/null >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && return 0
if [ "$rc" -eq 127 ]; then
err "akia: root yetkisi gerekiyor (parolasız sudo yok)"
apt_hint "$mode"; return 2
fi
err "akia: kurulum başarısız (apt-get çıkış $rc)"
apt_hint "$mode"; return 1
}
ensure_akia() {
local st
st="$(akia_state)"
case "$st" in
ok) log "akia: kurulu ve sağlam"; return 0 ;;
missing) log "akia: kuruluyor..."; apt_fix_akia install || return $? ;;
broken) log "akia: yeniden kuruluyor..."; apt_fix_akia reinstall || return $? ;;
esac
st="$(akia_state)"
[ "$st" != "ok" ] && { err "akia: kurulum sonrası: $(akia_state_text "$st")"; return 1; }
akia_installed && log "akia: kuruldu ($(dpkg-query -W -f='${Version}' "$AKIA_PKG" 2>/dev/null))"
return 0
}
ensure_pcscd() {
if systemctl is-active --quiet pcscd.service 2>/dev/null || systemctl is-active --quiet pcscd.socket 2>/dev/null; then return 0; fi
if [ "$(id -u)" -eq 0 ]; then
systemctl start pcscd.socket 2>/dev/null || systemctl start pcscd.service 2>/dev/null || true
fi
return 0
}
ensure_system_layer() {
[ "$SYSTEM_LAYER_DONE" -eq 1 ] && return 0
SYSTEM_LAYER_DONE=1
if [ "$NO_DEPS" -eq 0 ]; then
if ! ensure_akia; then
sys_missing_add akia
[ "$SYSTEM_STRICT" -eq 1 ] && return 2
warn "akia: kurulu değil (sistem katmanı gerekli)"
fi
fi
ensure_pcscd
return 0
}
system_setup() {
local rc=0
if [ "$(id -u)" -ne 0 ]; then
err "--system-setup root yetkisi gerektirir."
err "Yönetici olarak: sudo $0 --system-setup"
return 2
fi
log "Sistem katmanı hazırlanıyor (akia, unzip, indirici, pcscd)..."
ensure_akia || rc=2
if command -v unzip >/dev/null 2>&1; then log "unzip: kurulu"
else
log "unzip kuruluyor..."
DEBIAN_FRONTEND=noninteractive apt-get install -y unzip </dev/null >/dev/null 2>&1 || { err "unzip kurulamadı"; rc=2; }
fi
if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then log "indirici: kurulu"
else
log "wget/curl kuruluyor..."
DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl ca-certificates </dev/null >/dev/null 2>&1 || { err "indirici kurulamadı"; rc=2; }
fi
ensure_pcscd
if [ "$rc" -eq 0 ]; then log "Sistem katmanı hazır. Artık her kullanıcı sudo'suz çalıştırabilir."
else err "Sistem katmanı tamamlanamadı (çıkış $rc)."; fi
return "$rc"
}
# --------------------------------------------------------------------------
# Kurulum tespiti ve sürüm
# --------------------------------------------------------------------------
calling_home() {
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6
else
printf '%s\n' "${HOME:-}"
fi
}
list_human_homes() {
{
getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3!=65534 && $7!~/nologin|false/ {print $6}'
printf '%s\n' /root "${HOME:-}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6
fi
} | sort -u
}
install_owner() { stat -c '%U' "$1" 2>/dev/null; }
launcher_name() {
local d="$1" n
for n in SimesAgent simes-desktop-agent SimesDesktopAgent simes-agent; do
[ -e "$d/$n" ] && { printf '%s\n' "$n"; return 0; }
done
printf 'SimesAgent\n'
}
vmo_path() { printf '%s/%s.vmoptions\n' "$1" "$(launcher_name "$1")"; }
is_install() {
local d="$1"
[ -d "$d" ] || return 1
[ -f "$d/simes-desktop-agent.jar" ] || [ -x "$d/SimesAgent" ] || [ -x "$d/simes-desktop-agent" ]
}
desktop_entry_dir() {
local home="${1:-${HOME:-/nonexistent}}" f line d
for f in "$home"/.local/share/applications/install4j_*-SimesAgent.desktop; do
[ -f "$f" ] || continue
while IFS= read -r line; do
case "$line" in
Exec=*)
d="${line#Exec=}"; d="${d#\"}"
case "$d" in *"/SimesAgent"*) d="${d%%/SimesAgent*}" ;; *) continue ;; esac
printf '%s\n' "$d"; return 0 ;;
esac
done < "$f"
done
return 1
}
find_installs() {
local root="${1:-}"
local d h found=0 list rc
local -a seen=() homes=()
add_candidate() {
local c="$1" s
[ -n "$c" ] || return 0
is_install "$c" || return 0
for s in ${seen[@]+"${seen[@]}"}; do [ "$s" = "$c" ] && return 0; done
seen+=("$c"); printf '%s\n' "$c"; found=1
}
if [ -n "$root" ]; then homes=("$root")
else
while IFS= read -r h; do [ -n "$h" ] && homes+=("$h"); done < <(list_human_homes)
fi
list="$(mktemp "${TMPDIR:-/tmp}/simes-find.XXXXXX")" || return 3
for h in ${homes[@]+"${homes[@]}"}; do
[ -d "$h" ] || continue
d="$(desktop_entry_dir "$h" || true)"; [ -n "$d" ] && add_candidate "$d"
add_candidate "$h/SimesIstemci"; add_candidate "$h/Simes/SimesIstemci"
add_candidate "$h/Simes"; add_candidate "$h/simes-desktop-agent"
: > "$list"
if command -v timeout >/dev/null 2>&1; then
timeout "${SIMES_PCSC_FIX_FIND_TIMEOUT:-10}" find "$h" -maxdepth 3 -name simes-desktop-agent.jar -printf '%h\n' > "$list" 2>/dev/null
rc=$?
else
find "$h" -maxdepth 3 -name simes-desktop-agent.jar -printf '%h\n' > "$list" 2>/dev/null
rc=$?
fi
[ "$rc" -eq 124 ] && { rm -f "$list"; return 3; }
while IFS= read -r d; do [ -n "$d" ] && add_candidate "$d"; done < "$list"
done
rm -f "$list"
[ "$found" -eq 1 ]
}
version_from_url() {
local n="${1##*/}"
case "$n" in
SimesIstemci_unix_*) printf '%s' "$n" | grep -oE '[0-9]+_[0-9]+_[0-9]+' | head -n1 | tr '_' '.' ;;
*) printf '%s' "$n" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
esac
}
installed_version() {
local d="$1" v=""
if [ -r "$d/$STAMP_NAME" ]; then
v="$(head -n1 "$d/$STAMP_NAME" 2>/dev/null | tr -d ' \r\n')"
if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
fi
if [ -f "$d/simes-desktop-agent.jar" ] && command -v unzip >/dev/null 2>&1; then
v="$(unzip -p "$d/simes-desktop-agent.jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' \
| grep -E '^(Implementation-Version|Specification-Version|Bundle-Version):' | head -n1 | cut -d' ' -f2)"
case "$v" in *[0-9].[0-9].[0-9]*) ;; *) v="" ;; esac
fi
if [ -z "$v" ] && [ -d "$d/.install4j" ]; then
v="$(grep -rhoE '[0-9]+\.[0-9]+\.[0-9]+' "$d/.install4j" 2>/dev/null | grep -v '^17\.' | head -n1)"
fi
if [ -z "$v" ] && [ -d "$d/config" ]; then
v="$(grep -rhoE '[0-9]+\.[0-9]+\.[0-9]+' "$d/config" 2>/dev/null | head -n1)"
fi
printf '%s' "$v"
}
stamp_version() {
local d="$1" v="$2"
[ -n "$v" ] || return 0
printf '%s\n' "$v" > "$d/$STAMP_NAME" 2>/dev/null || true
[ "$(id -u)" -eq 0 ] && chown --reference="$d" "$d/$STAMP_NAME" 2>/dev/null || true
return 0
}
ver_lt() {
[ "$1" != "$2" ] || return 1
[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}
# --------------------------------------------------------------------------
# Onarım
# --------------------------------------------------------------------------
prop_value() {
local vmo="$1" line
line="$(grep -m1 -E -- "$PROP_RE" "$vmo" 2>/dev/null)" || return 1
[ -n "$line" ] || return 1
line="${line#"$PROP_PREFIX"}"
printf '%s\n' "${line%$'\r'}"
}
prop_is_ours() {
local vmo="$1" n prev
n="$(grep -n -m1 -E -- "$PROP_RE" "$vmo" 2>/dev/null | cut -d: -f1)"
[ -n "$n" ] || return 1
[ "$n" -gt 1 ] || return 1
prev="$(sed -n "$((n-1))p" "$vmo")"; prev="${prev%$'\r'}"
[ "$prev" = "$MARKER" ]
}
agent_ok() {
local d="$1" vmo; vmo="$(vmo_path "$d")"
[ -f "$d/$AGENT_JAR_NAME" ] || return 1
awk -v arg="$AGENT_ARG" '{sub(/\r$/,"")} $0==arg{f=1;exit} END{exit(f?0:1)}' "$vmo"
}
set_eol() { if grep -q $'\r$' "$1" 2>/dev/null; then EOL=$'\r\n'; else EOL=$'\n'; fi; }
prop_state() {
local vmo="$1" cur lib
lib="$(lib_path)" || return 2
if ! cur="$(prop_value "$vmo")"; then printf 'none\n'; return 0; fi
if [ "$cur" = "$lib" ]; then printf 'ok\n'
elif prop_is_ours "$vmo"; then printf 'ours-bad\n'
elif [ -e "$cur" ]; then printf 'ok\n'
else printf 'vendor-bad\n'; fi
}
full_state() {
local d="$1" ps
ps="$(prop_state "$(vmo_path "$d")")" || return 2
case "$ps" in
vendor-bad) printf 'vendor-bad\n'; return 0 ;;
ok) if agent_ok "$d"; then printf 'ok\n'; else printf 'ours-bad\n'; fi; return 0 ;;
*) printf '%s\n' "$ps"; return 0 ;;
esac
}
do_check() {
local d="$1" state astate iv
if [ "$NO_DEPS" -eq 0 ]; then
astate="$(akia_state)"
[ "$astate" = "ok" ] && log "akia: kurulu ve sağlam" || log "akia: $(akia_state_text "$astate") -> sistem katmanı gerekli"
fi
iv="$(installed_version "$d")"
log "$d: kurulu sürüm ${iv:-bilinmiyor}"
state="$(full_state "$d")" || return 2
case "$state" in
ok) log "$d: onarılı"; { [ "$NO_DEPS" -eq 1 ] || [ "$astate" = "ok" ]; } || return 1; return 0 ;;
vendor-bad) err "Satıcı ${PROP_KEY} satırı var ama dosya yok: $(vmo_path "$d")"; return 1 ;;
none|ours-bad) log "$d: onarım-gerekli"; return 1 ;;
esac
return 2
}
install_agent() {
local d="$1" vmo src dst tmp
vmo="$(vmo_path "$d")"; dst="$d/$AGENT_JAR_NAME"
resolve_agent_jar || { err "simes-pcsc-agent.jar bulunamadı"; return 2; }
src="$AGENT_SRC"
[ -f "$dst" ] && cmp -s -- "$src" "$dst" && return 0
tmp="$(mktemp "$d/.simes-pcsc-agent.XXXXXX")" || { err "Ajan yazılamadı: $d"; return 2; }
cp -- "$src" "$tmp" || { rm -f "$tmp"; err "Ajan yazılamadı: $d"; return 2; }
chmod 0644 "$tmp" 2>/dev/null || true
chown --reference="$vmo" "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$dst" || { rm -f "$tmp"; err "Ajan yazılamadı: $d"; return 2; }
[ "$(id -u)" -eq 0 ] && chown --reference="$d" "$dst" 2>/dev/null || true
return 0
}
strip_our_block() {
local vmo="$1" out="$2" eol="$3" line skip=0
: > "$out"
[ -f "$vmo" ] || return 0
while IFS= read -r line || [ -n "$line" ]; do
line="${line%$'\r'}"
if [ "$skip" -eq 1 ]; then
case "$line" in "$PROP_PREFIX"*|"$AGENT_LIB_PREFIX"*|"$AGENT_ARG_PREFIX"*) continue ;; esac
skip=0
fi
[ "$line" = "$MARKER" ] && { skip=1; continue; }
printf '%s%s' "$line" "$eol" >> "$out"
done < "$vmo"
}
do_repair() {
local d="$1" vmo lib state tmp eol
vmo="$(vmo_path "$d")"
lib="$(lib_path)" || return 2
state="$(full_state "$d")" || return 2
ensure_system_layer || return 2
case "$state" in
ok) log "$d: zaten onarılı"; return 0 ;;
vendor-bad) err "Satıcı ${PROP_KEY} satırı bulundu, dokunulmadı: $vmo"; return 0 ;;
esac
[ -f "$vmo" ] && [ ! -w "$vmo" ] && { err "vmoptions yazılamadı: $vmo"; return 2; }
[ ! -w "$d" ] && { err "Kurulum dizinine yazılamadı: $d"; return 2; }
install_agent "$d" || return 2
tmp="$(mktemp "$(dirname "$vmo")/.simes-pcsc-fix.XXXXXX")" || { err "vmoptions yazılamadı: $vmo"; return 2; }
set_eol "$vmo"; eol="$EOL"
strip_our_block "$vmo" "$tmp" "$eol"
if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then printf '%s' "$eol" >> "$tmp"; fi
printf '%s%s' "$MARKER" "$eol" >> "$tmp"
printf '%s%s%s' "$PROP_PREFIX" "$lib" "$eol" >> "$tmp"
printf '%s%s%s' "$AGENT_LIB_PREFIX" "$lib" "$eol" >> "$tmp"
printf '%s%s' "$AGENT_ARG" "$eol" >> "$tmp"
chmod --reference="$vmo" "$tmp" 2>/dev/null || chmod 0644 "$tmp" 2>/dev/null || true
chown --reference="$vmo" "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$vmo" || { rm -f "$tmp"; err "vmoptions yazılamadı: $vmo"; return 2; }
[ "$(id -u)" -eq 0 ] && chown --reference="$d" "$vmo" 2>/dev/null || true
log "$d: onarıldı (sahibi: $(install_owner "$d"))"
log "  SiMES çalışıyorsa kapatıp yeniden açın."
return 0
}
has_marker() { awk -v m="$MARKER" '{sub(/\r$/,"")} $0==m{f=1;exit} END{exit(f?0:1)}' "$1"; }
do_revert() {
local d="$1" vmo tmp eol had_marker=0
vmo="$(vmo_path "$d")"
[ -f "$vmo" ] && has_marker "$vmo" && had_marker=1
[ "$had_marker" -eq 0 ] && [ ! -f "$d/$AGENT_JAR_NAME" ] && { log "$d: kaldırılacak satır yok"; return 0; }
[ -f "$vmo" ] && [ ! -w "$vmo" ] && { err "vmoptions yazılamadı: $vmo"; return 2; }
if [ "$had_marker" -eq 1 ]; then
tmp="$(mktemp "$(dirname "$vmo")/.simes-pcsc-fix.XXXXXX")" || { err "vmoptions yazılamadı"; return 2; }
set_eol "$vmo"; eol="$EOL"
strip_our_block "$vmo" "$tmp" "$eol"
chmod --reference="$vmo" "$tmp" 2>/dev/null || chmod 0600 "$tmp" 2>/dev/null || true
chown --reference="$vmo" "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$vmo" || { rm -f "$tmp"; err "vmoptions yazılamadı"; return 2; }
[ "$(id -u)" -eq 0 ] && chown --reference="$d" "$vmo" 2>/dev/null || true
[ ! -s "$vmo" ] && rm -f -- "$vmo" || true
fi
if [ -f "$d/$AGENT_JAR_NAME" ]; then rm -f -- "$d/$AGENT_JAR_NAME" || { err "Ajan kaldırılamadı"; return 2; }; fi
rm -f -- "$d/$STAMP_NAME" 2>/dev/null || true
log "$d: satırlar kaldırıldı"
return 0
}
verify_classes() {
if [ -n "${SIMES_PCSC_FIX_VERIFY_CLASSES:-}" ]; then printf '%s\n' "$SIMES_PCSC_FIX_VERIFY_CLASSES"; return 0; fi
[ -d "$(dirname "$SELF")/verify" ] && { printf '%s\n' "$(dirname "$SELF")/verify"; return 0; }
printf '%s\n' "/usr/share/simes-pcsc-fix"
}
do_verify() {
local d="$1" out rc classes prop errout errfile
local -a jvm_args=()
[ -x "$d/jre/bin/java" ] || { err "java yok: $d/jre/bin/java"; return 2; }
[ -f "$d/simes-desktop-agent.jar" ] || { err "jar yok: $d/simes-desktop-agent.jar"; return 2; }
if [ "$NO_DEPS" -eq 0 ] && [ "$(akia_state)" != "ok" ]; then err "Uyarı: akia $(akia_state_text "$(akia_state)")"; fi
classes="$(verify_classes)"
if agent_ok "$d"; then
jvm_args+=("$AGENT_ARG"); jvm_args+=("-Dsun.security.smartcardio.library=$BARE_OVERRIDE")
elif prop="$(prop_value "$(vmo_path "$d")")" && [ -n "$prop" ]; then
jvm_args+=("-Dsun.security.smartcardio.library=$prop")
fi
errfile="$(mktemp "${TMPDIR:-/tmp}/simes-verify-err.XXXXXX")" || { err "Geçici dosya açılamadı"; return 2; }
out="$(cd "$d" && "$d/jre/bin/java" ${jvm_args[@]+"${jvm_args[@]}"} -cp "$classes:$d/simes-desktop-agent.jar" VerifyReaders 2>"$errfile")"
rc=$?
errout="$(cat -- "$errfile" 2>/dev/null)"; rm -f "$errfile"
if [ "$rc" -eq 0 ]; then [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }; return 1; fi
err "Doğrulama çalıştırılamadı (java çıkış $rc)${errout:+: $errout}"
case "$errout" in *CardException*) err "İpucu: systemctl status pcscd.socket; pcsc_scan" ;; esac
return 2
}
# --------------------------------------------------------------------------
# İndirme göstergesi (sabit genişlik + rastgele tek harf)
# --------------------------------------------------------------------------
progress_init() {
case "$PROGRESS_MODE" in dots|simple|bar|none) ;; *) PROGRESS_MODE="dots" ;; esac
if [ "$PROGRESS_MODE" = "bar" ]; then
if [ ! -t 1 ]; then PROGRESS_MODE="dots"
else case "${TERM:-}" in dumb|unknown|"") PROGRESS_MODE="dots" ;; esac
fi
fi
return 0
}
dots_bar() {
local pct="$1" ch="$2" filled i pos out
filled=$(( pct * PROGRESS_WIDTH / 100 ))
[ "$filled" -gt "$PROGRESS_WIDTH" ] && filled="$PROGRESS_WIDTH"
[ "$filled" -lt 0 ] && filled=0
pos=$(( (RANDOM % PROGRESS_WIDTH) + 1 ))
out=""; i=1
while [ "$i" -le "$PROGRESS_WIDTH" ]; do
if [ "$i" -eq "$pos" ] && [ -n "$ch" ]; then
out="${out}${ch}"
elif [ "$i" -le "$filled" ]; then
out="${out}:"
else
out="${out}."
fi
i=$((i+1))
done
printf '%s' "$out"
}
credit_line_all() {
local i n out ch
out=""; i=1; n=0
while [ "$i" -le "$PROGRESS_WIDTH" ]; do
if [ $(( i % 3 )) -eq 0 ] && [ "$n" -lt 12 ]; then
ch="${CREDIT:$n:1}"; n=$((n+1)); out="${out}${ch}"
else
out="${out}:"
fi
i=$((i+1))
done
printf '%s' "$out"
}
# --------------------------------------------------------------------------
# Sayfa / URL çözümü (dayanıklı)
# --------------------------------------------------------------------------
fetch_page() {
local url="$1" out=""
if command -v curl >/dev/null 2>&1; then
out="$(curl -sL --connect-timeout 10 --max-time 20 --retry 2 -A "$UA" "$url" 2>/dev/null || true)"
if [ -z "$out" ]; then
out="$(curl -skL --connect-timeout 10 --max-time 20 -A "$UA" "$url" 2>/dev/null || true)"
fi
fi
if [ -z "$out" ] && command -v wget >/dev/null 2>&1; then
out="$(wget -qO- --timeout=20 --tries=2 --user-agent="$UA" "$url" 2>/dev/null || true)"
fi
printf '%s' "$out"
}
detect_simes_url() {
local page url rel
page="$(fetch_page "$SIMES_PAGE")"
[ "${SIMES_DEBUG:-0}" = "1" ] && err "Tanılama: sayfa bayt sayısı = ${#page}"
page="$(printf '%s' "$page" | sed -e 's/&#0*38;/\&/g' -e 's/&amp;/\&/g' -e 's|\\/|/|g')"
url="$(printf '%s' "$page" | grep -oiE "https?://[^\"'<>[:space:]]+\.zip" | grep -i 'simes' | head -n1)"
if [ -z "$url" ]; then
rel="$(printf '%s' "$page" | grep -oiE "/uploads/[^\"'<>[:space:]]+\.zip" | grep -i 'simes' | head -n1)"
[ -n "$rel" ] && url="https://ms.hmb.gov.tr$rel"
fi
[ "${SIMES_DEBUG:-0}" = "1" ] && err "Tanılama: bulunan URL = ${url:-yok}"
printf '%s' "$url"
}
run_as_user() {
local u="$1"; shift
if [ "$(id -u)" -eq 0 ] && [ "$u" != "root" ]; then
if command -v runuser >/dev/null 2>&1; then runuser -u "$u" -- "$@"; else sudo -u "$u" "$@"; fi
else "$@"; fi
}
file_magic() { head -c4 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
is_zip_file() { [ "$(file_magic "$1")" = "504b0304" ]; }
is_sh_file()  { [ "$(head -c2 -- "$1" 2>/dev/null)" = "#!" ]; }
zip_ok()      { is_zip_file "$1" && unzip -tq -- "$1" >/dev/null 2>&1; }
ensure_unzip() {
local rc
command -v unzip >/dev/null 2>&1 && return 0
log "unzip kuruluyor..."
DEBIAN_FRONTEND=noninteractive apt_run apt-get install -y unzip </dev/null >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && command -v unzip >/dev/null 2>&1 && return 0
sys_missing_add unzip
err "unzip: kurulu değil (sistem katmanı gerekli)"
return 2
}
ensure_downloader() {
local rc
if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then return 0; fi
log "wget/curl kuruluyor..."
DEBIAN_FRONTEND=noninteractive apt_run apt-get install -y wget curl ca-certificates </dev/null >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && { command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; }; then return 0; fi
sys_missing_add indirici
err "İndirici: kurulu değil (sistem katmanı gerekli)"
return 2
}
# 0=hazır, 1=portal(HTML), 2=bağlantı yok
net_ready() {
local url="$1" hdr ct rc
if command -v curl >/dev/null 2>&1; then
hdr="$(curl -sIL --connect-timeout 5 --max-time 10 -A "$UA" "$url" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then
hdr="$(curl -skIL --connect-timeout 5 --max-time 10 -A "$UA" "$url" 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && return 2
fi
else
hdr="$(wget --spider -S --timeout=10 --tries=1 --user-agent="$UA" "$url" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && return 2
fi
ct="$(printf '%s' "$hdr" | awk 'tolower($1)=="content-type:"{v=$2} END{gsub(/\r/,"",v); print v}')"
case "$ct" in ""|*text/html*) return 1 ;; *) return 0 ;; esac
}
wait_for_auth() {
local url="$1" i=0 max="${SIMES_AUTH_TRIES:-60}" netfail=0 rc
while :; do
net_ready "$url"; rc=$?
[ "$rc" -eq 0 ] && return 0
if [ "$rc" -eq 2 ]; then
netfail=$((netfail+1))
if [ "$netfail" -ge 3 ]; then
err "Ağ erişimi yok veya sunucuya ulaşılamıyor. Bağlantınızı denetleyin."
return 3
fi
warn "Ağ erişimi deneniyor ($netfail/3)..."
sleep 3
continue
fi
i=$((i+1))
if [ "$i" -gt "$max" ]; then
err "Ağ kimlik doğrulaması zaman aşımı. Tarayıcıda oturum açıp yeniden çalıştırın."
return 2
fi
warn "Kurumsal ağ kimlik doğrulaması bekleniyor (deneme $i/$max). Tarayıcıda oturum açın..."
sleep 5
done
}
fetch_simes_archive() {
local u uh url dl zip fsize rc total cur pct speed bar filled i
local t0 t1 b0 b1 dt dpid hc ht hs hf cols barw resume DL_LOG poll last_rep next_idx next_pct th ch
local -a TH=(8 17 25 33 42 50 58 67 75 83 92 100)
u="$(id -un)"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then u="$SUDO_USER"; fi
uh="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"; [ -z "$uh" ] && uh="$HOME"
url="$(detect_simes_url)"; [ -z "$url" ] && url="$DEFAULT_SIMES_URL"
SIMES_URL="$url"; SIMES_USER="$u"; SIMES_DL="$uh/SimesKurulum"
log "Simes e-imza: hedef sürüm $url"
run_as_user "$u" mkdir -p "$SIMES_DL" || { err "Klasör oluşturulamadı: $SIMES_DL"; return 2; }
zip="$SIMES_DL/$(basename "$url")"; SIMES_ZIP="$zip"
ensure_unzip || return 2
ensure_downloader || return 2
wait_for_auth "$url"; rc=$?
[ "$rc" -ne 0 ] && return "$rc"
resume=0
if [ -s "$zip" ]; then
if zip_ok "$zip"; then log "Simes e-imza: mevcut sağlam arşiv kullanılacak: $zip"; resume=2
elif is_zip_file "$zip"; then warn "Simes e-imza: yarım kalmış arşiv; kaldığı yerden devam edilecek."; resume=1
else warn "Simes e-imza: bozuk/HTML arşiv siliniyor."; rm -f -- "$zip"; resume=0
fi
fi
if [ "$resume" != "2" ]; then
if command -v curl >/dev/null 2>&1; then
total="$(curl -sIL --connect-timeout 10 --max-time 15 -A "$UA" "$url" 2>/dev/null | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v+0}')"
else
total="$(wget --spider -S --timeout=15 --user-agent="$UA" "$url" 2>&1 | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v+0}')"
fi
[ -z "$total" ] && total=0
DL_LOG="$(mktemp "${TMPDIR:-/tmp}/simes-dl.XXXXXX")" || DL_LOG=/tmp/simes-dl.log
progress_init
log "Simes e-imza: indiriliyor..."
if command -v wget >/dev/null 2>&1; then
run_as_user "$u" wget -c --tries=2 --timeout=30 --read-timeout=120 -O "$zip" "$url" >"$DL_LOG" 2>&1 &
else
run_as_user "$u" curl -C - -fL --connect-timeout 10 --retry 2 -o "$zip" "$url" >"$DL_LOG" 2>&1 &
fi
dpid=$!
cols=$(tput cols 2>/dev/null || echo 80)
case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
[ "$cols" -lt 40 ] && cols=40
barw=$(( cols - 46 )); [ "$barw" -lt 8 ] && barw=8; [ "$barw" -gt 40 ] && barw=40
poll=0.2; [ "$PROGRESS_MODE" != "bar" ] && poll=1
next_idx=1; next_pct=0; last_rep=$(date +%s)
t0=$(date +%s); b0=$(stat -c %s "$zip" 2>/dev/null || echo 0)
while kill -0 "$dpid" 2>/dev/null; do
sleep "$poll"
cur=$(stat -c %s "$zip" 2>/dev/null || echo 0)
t1=$(date +%s); b1=$cur
dt=$((t1 - t0)); [ "$dt" -le 0 ] && dt=1
speed=$(( (b1 - b0) / dt ))
hc=$(numfmt --to=iec "$cur" 2>/dev/null || echo "${cur}B")
hs=$(numfmt --to=iec "$speed" 2>/dev/null || echo "${speed}B")
if [ "$total" -gt 0 ]; then
pct=$(( cur * 100 / total )); [ "$pct" -gt 100 ] && pct=100
ht=$(numfmt --to=iec "$total" 2>/dev/null || echo "${total}B")
case "$PROGRESS_MODE" in
dots)
while [ "$next_idx" -le 12 ]; do
th="${TH[$((next_idx-1))]}"
[ "$pct" -ge "$th" ] || break
ch="${CREDIT:$((next_idx-1)):1}"
printf 'Simes e-imza: %3d%% |%s| %s/%s\n' "$th" "$(dots_bar "$th" "$ch")" "$hc" "$ht"
next_idx=$((next_idx+1))
done ;;
simple)
if [ "$pct" -ge "$next_pct" ]; then
printf 'Simes e-imza: %3d%% - %s/%s\n' "$pct" "$hc" "$ht"
next_pct=$(( pct + PROGRESS_STEP ))
fi ;;
bar)
filled=$(( pct * barw / 100 )); bar=""; i=0
while [ "$i" -lt "$barw" ]; do
if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar} "; fi
i=$((i+1))
done
printf '\rSimes e-imza: %3d%%|%s| %s/%s %s/s\033[K' "$pct" "$bar" "$hc" "$ht" "$hs" ;;
none) : ;;
esac
else
if [ $(( t1 - last_rep )) -ge 5 ]; then
case "$PROGRESS_MODE" in
dots|simple) printf 'Simes e-imza: %s indirildi\n' "$hc" ;;
bar) printf '\rSimes e-imza: indiriliyor... %s %s/s\033[K' "$hc" "$hs" ;;
none) : ;;
esac
last_rep=$t1
fi
fi
t0=$t1; b0=$b1
done
wait "$dpid"; rc=$?
[ "$PROGRESS_MODE" = "bar" ] && printf '\n'
fsize=$(stat -c %s "$zip" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ] || ! zip_ok "$zip"; then
err "Simes e-imza: indirme başarısız/eksik ($fsize bayt, rc=$rc)."
err "--- indirme günlüğü (son 15 satır) ---"
tail -n 15 "$DL_LOG" >&2 || true
err "Çözüm: zip'i tarayıcıdan indirip şu yola kopyalayın: $zip"
rm -f "$DL_LOG"; return 2
fi
rm -f "$DL_LOG"
hf=$(numfmt --to=iec "$fsize" 2>/dev/null || echo "${fsize}B")
if [ "$total" -gt 0 ]; then
ht=$(numfmt --to=iec "$total" 2>/dev/null || echo "${total}B")
case "$PROGRESS_MODE" in
dots)
while [ "$next_idx" -le 12 ]; do
th="${TH[$((next_idx-1))]}"
ch="${CREDIT:$((next_idx-1)):1}"
printf 'Simes e-imza: %3d%% |%s| %s/%s\n' "$th" "$(dots_bar "$th" "$ch")" "$ht" "$ht"
next_idx=$((next_idx+1))
done ;;
simple) printf 'Simes e-imza: 100%% - %s/%s\n' "$ht" "$ht" ;;
esac
else
case "$PROGRESS_MODE" in
dots) printf 'Simes e-imza: 100%% |%s| %s/%s\n' "$(credit_line_all)" "$hf" "$hf" ;;
simple) printf 'Simes e-imza: 100%% - %s\n' "$hf" ;;
esac
fi
log "Simes e-imza: indirme tamamlandı ($hf)."
fi
zip_ok "$zip" || is_sh_file "$zip" || { err "Arşiv doğrulanamadı"; return 2; }
return 0
}

stop_simes_processes() {
    local target_class="install4j.tr.gov.tubitak.bilgem.simes.agent.SimesClientApplication"
    if pgrep -f "$target_class" >/dev/null 2>&1 || pgrep -f "SimesAgent" >/dev/null 2>&1; then
        log "Arka planda çalışan SİMES süreçleri tespit edildi, sonlandırılıyor..."
        pkill -TERM -f "$target_class" 2>/dev/null || true
        pkill -TERM -f "SimesAgent" 2>/dev/null || true
        sleep 2
        
        if pgrep -f "$target_class" >/dev/null 2>&1 || pgrep -f "SimesAgent" >/dev/null 2>&1; then
            warn "Bazı Simes süreçleri inatçı, zorla kapatılıyor (SIGKILL)..."
            pkill -9 -f "$target_class" 2>/dev/null || true
            pkill -9 -f "SimesAgent" 2>/dev/null || true
            sleep 1
        fi
        log "Simes süreçleri tamamen temizlendi."
    fi
}

install_from_archive() {
local u="$SIMES_USER" dl="$SIMES_DL" zip="$SIMES_ZIP" inst
if zip_ok "$zip"; then
run_as_user "$u" bash -c "cd '$dl' && unzip -o -q '$(basename "$zip")'" || { err "Çıkarma başarısız"; return 2; }
inst="$(find "$dl" -maxdepth 2 -type f -name '*.sh' 2>/dev/null | head -n1)"
elif is_sh_file "$zip"; then inst="$zip"
else err "Arşiv geçersiz"; return 2; fi
[ -z "$inst" ] && { err "Kurulum betiği bulunamadı"; return 2; }
chmod +x "$inst"; chown "$u:$u" "$inst" 2>/dev/null || true
log "Simes e-imza: otomatik kurulum $u olarak..."
run_as_user "$u" bash -c "cd '$(dirname "$inst")' && './$(basename "$inst")' -q" || warn "Kurulum hata kodu döndürdü"

# Kurulum sihirbazının (-q modda) otomatik başlattığı Simes sürecini tespit edip temizleyelim
stop_simes_processes

return 0
}

remove_old_install() {
local d="$1" owner rc
owner="$(install_owner "$d")"; [ -n "$owner" ] || owner="$(id -un)"

stop_simes_processes

if [ -x "$d/uninstall" ]; then
log "Eski sürüm kaldırılıyor: $d/uninstall -q ($owner)"
if command -v timeout >/dev/null 2>&1; then
timeout 180 run_as_user "$owner" bash -c "cd '$d' && ./uninstall -q" >/dev/null 2>&1
rc=$?
else
run_as_user "$owner" bash -c "cd '$d' && ./uninstall -q" >/dev/null 2>&1
rc=$?
fi
[ "$rc" -eq 0 ] && log "Kaldırma programı tamamlandı." || warn "Kaldırma programı $rc kodu döndürdü; dizin temizlenecek."
else
warn "uninstall bulunamadı; dizin doğrudan kaldırılacak."
fi
if [ -d "$d" ]; then
log "Kalan dizin kaldırılıyor (yama dosyaları dahil): $d"
rm -rf -- "$d" 2>/dev/null || run_as_user "$owner" rm -rf -- "$d" 2>/dev/null || true
fi
[ -d "$d" ] && { err "Dizin kaldırılamadı: $d"; return 2; }
log "Eski sürüm tamamen kaldırıldı."
return 0
}
install_simes_bootstrap() {
local d rc
fetch_simes_archive; rc=$?
[ "$rc" -ne 0 ] && return "$rc"
install_from_archive || return 2
d="$(find_installs "$(calling_home)" 2>/dev/null | head -n1)"
[ -n "$d" ] && stamp_version "$d" "$(version_from_url "$SIMES_URL")"
return 0
}
upgrade_simes() {
local d="$1" latest="$2" rc
fetch_simes_archive; rc=$?
if [ "$rc" -eq 3 ]; then
warn "Ağ erişilemiyor; yükseltme atlanıyor, mevcut kurulum yamalanacak."
return 0
fi
[ "$rc" -ne 0 ] && return 2
log "Yeni sürüm arşivi hazır ve doğrulandı; eski sürüm şimdi kaldırılıyor."
remove_old_install "$d" || return 2
install_from_archive || return 2
stamp_version "$d" "$latest"
log "Sürüm yükseltildi: $latest"
return 0
}
# --------------------------------------------------------------------------
# Root turu
# --------------------------------------------------------------------------
mode_status() {
case "$MODE" in
check) case "$1" in 0) printf 'onarılı\n' ;; 1) printf 'onarım-gerekli\n' ;; *) printf 'erişilemedi\n' ;; esac ;;
verify) case "$1" in 0) printf 'okuyucu-var\n' ;; 1) printf 'okuyucu-yok\n' ;; *) printf 'erişilemedi\n' ;; esac ;;
*) [ "$1" -eq 0 ] && printf 'uygulandı\n' || printf 'erişilemedi\n' ;;
esac
}
do_all() {
local getent user uid home shell d st mode_arg discovered dst status worst=0
getent="${SIMES_PCSC_FIX_GETENT:-getent}"
[ "$(id -u)" -ne 0 ] && { err "--all yalnızca root"; return 2; }
command -v "$getent" >/dev/null 2>&1 || { err "getent yok"; return 2; }
if [ "$NO_DEPS" -eq 0 ] && [ "$MODE" != "revert" ]; then
if [ "$MODE" = "check" ]; then
local astate; astate="$(akia_state)"
[ "$astate" = "ok" ] && printf 'akia: kurulu ve sağlam\n' || { printf 'akia: %s -> sistem katmanı gerekli\n' "$(akia_state_text "$astate")"; worst=1; }
else ensure_system_layer || worst=2; fi
fi
while IFS=: read -r user _ uid _ _ home shell; do
case "$uid" in ''|*[!0-9]*) continue ;; esac
case "$shell" in */nologin|*/false|'') continue ;; esac
[ "$uid" -ne 0 ] && [ "$uid" -lt 1000 ] && continue
[ -n "$home" ] || continue
if command -v timeout >/dev/null 2>&1; then timeout 5 test -d "$home"; else test -d "$home"; fi
[ $? -ne 0 ] && { printf '%s: erişilemedi\n' "$user"; worst=2; continue; }
discovered="$(HOME="$home" find_installs "$home" 2>/dev/null)"; dst=$?
[ "$dst" -eq 3 ] && { printf '%s: erişilemedi\n' "$user"; worst=2; continue; }
[ -z "$discovered" ] && { printf '%s: kurulum-yok\n' "$user"; continue; }
while IFS= read -r d; do
[ -n "$d" ] || continue
mode_arg=""
case "$MODE" in check) mode_arg="--check" ;; revert) mode_arg="--revert" ;; verify) mode_arg="--verify" ;; esac
if command -v runuser >/dev/null 2>&1; then
timeout 10 runuser -u "$user" -- "$SELF" --dir "$d" ${mode_arg:+"$mode_arg"} --no-upgrade --no-deps --quiet >/dev/null 2>&1
else
timeout 10 su -s /bin/sh -c "$(printf '%q --dir %q %s --no-upgrade --no-deps --quiet' "$SELF" "$d" "$mode_arg")" "$user" >/dev/null 2>&1
fi
st=$?; status="$(mode_status "$st")"
printf '%s: %s\n' "$user" "$status"
[ "$st" -eq 2 ] && worst=2
[ "$st" -eq 1 ] && [ "$worst" -lt 1 ] && worst=1
done <<< "$discovered"
done < <("$getent" passwd)
if [ -n "$SYSTEM_MISSING" ]; then
warn "Sistem katmanı eksik: $SYSTEM_MISSING"
system_hint
[ "$worst" -eq 0 ] && worst=1
fi
return "$worst"
}
# --------------------------------------------------------------------------
# Ana akış
# --------------------------------------------------------------------------
run_for() {
local d="$1"
case "$MODE" in
check) do_check "$d" ;;
repair) do_repair "$d" ;;
revert) do_revert "$d" ;;
verify) do_verify "$d" ;;
esac
}
if [ "$MODE" = "system" ]; then system_setup; exit $?; fi
if [ "$ALL" -eq 1 ]; then do_all; exit $?; fi
if [ -n "$TARGET_DIR" ]; then
is_install "$TARGET_DIR" || { err "SiMES kurulumu bulunamadı: $TARGET_DIR"; exit 2; }
run_for "$TARGET_DIR"; exit $?
fi
if [ "$MODE" = "repair" ]; then
CHOME="$(calling_home)"
D="$CHOME/SimesIstemci"
if [ ! -d "$D" ]; then
log "Simes e-imza: $D bulunamadı; varsayılan kurulum başlatılıyor."
install_simes_bootstrap || exit 2
elif [ "$FORCE_REINSTALL" -eq 1 ]; then
LURL="$(detect_simes_url)"; [ -z "$LURL" ] && LURL="$DEFAULT_SIMES_URL"
warn "Zorlu yeniden kurulum istendi."
upgrade_simes "$D" "$(version_from_url "$LURL")" || exit 2
elif [ "$NO_UPGRADE" -eq 0 ]; then
LURL="$(detect_simes_url)"
if [ -z "$LURL" ]; then
warn "Güncel sürüm sayfası çözümlenemedi; varsayılan güncel sürüm deneniyor."
LURL="$DEFAULT_SIMES_URL"
fi
LVER="$(version_from_url "$LURL")"
IVER="$(installed_version "$D")"
if [ -z "$IVER" ]; then
warn "Kurulu sürüm belirlenemedi; güvenli yükseltme yapılacak (hedef $LVER)."
upgrade_simes "$D" "$LVER" || exit 2
elif [ "$IVER" = "$LVER" ]; then
log "Kurulu sürüm güncel: $IVER"
stamp_version "$D" "$IVER"
elif ver_lt "$IVER" "$LVER"; then
warn "Eski sürüm tespit edildi: $IVER -> güncel $LVER"
upgrade_simes "$D" "$LVER" || exit 2
else
log "Kurulu sürüm ($IVER) sitedeki sürümden ($LVER) yeni; dokunulmuyor."
stamp_version "$D" "$IVER"
fi
fi
fi
discovered="$(find_installs)"; dst=$?
[ "$dst" -eq 3 ] && { err "Arama zaman aşımı"; exit 2; }
if [ "$dst" -ne 0 ] || [ -z "$discovered" ]; then
if [ "$BOOTSTRAP" -eq 1 ] || [ "$MODE" = "repair" ]; then
install_simes_bootstrap || exit 2
discovered="$(find_installs)"; dst=$?
fi
if [ "$dst" -ne 0 ] || [ -z "$discovered" ]; then
err "Simes e-imza kurulumu bulunamadı."
err "Kurmak için: $0 --install"
exit 2
fi
fi
ensure_system_layer || exit 2
mapfile -t INSTALLS <<< "$discovered"
rc=0
for d in "${INSTALLS[@]}"; do
owner="$(install_owner "$d")"
if [ "$(id -u)" -ne 0 ] && [ "$owner" != "$(id -un)" ] && { [ "$MODE" = "repair" ] || [ "$MODE" = "revert" ]; }; then
log "$d: sahibi $owner - root ile çalıştırın (atlandı)"
rc=1; continue
fi
run_for "$d"; st=$?
[ "$st" -eq 2 ] && exit 2
[ "$st" -eq 1 ] && rc=1
done
if [ -n "$SYSTEM_MISSING" ]; then
warn "Sistem katmanı eksik: $SYSTEM_MISSING"
system_hint
[ "$rc" -eq 0 ] && rc=1
fi
if [ "$MODE" = "repair" ] && [ "$rc" -eq 0 ]; then
show_completion
fi
exit "$rc"
#@@EMBED-AGENT-BEGIN@@
#UEsDBBQACAgIAKpEZV0AAAAAAAAAAAAAAAAJAAQATUVUQS1JTkYv/soAAAMAUEsHCAAAAAACAAAA
#AAAAAFBLAwQUAAgICACqRGVdAAAAAAAAAAAAAAAAFAAAAE1FVEEtSU5GL01BTklGRVNULk1GdY6x
#CsIwFEX3QP4how4pLTiUbpq5WBRc5ZHeSCBN5L0s/r1RZ6c7nAPnzpRjgFR7A0sseTJD12u1MDaK
#2bpEIpO5xg2yePHHB3LV6jv/oKNsL1gRYsbPQbMCJUGDDKpY7en1KY1dfz+Mg9mdmXyCcYWfham2
#I3uttHoDUEsHCCVEtG17AAAAngAAAFBLAwQUAAgICACqRGVdAAAAAAAAAAAAAAAAFAAAAFNpbWVz
#UGNzY0FnZW50LmNsYXNzjZXfVxNXEMe/14TsZlk0LlgrWAEB5UdJRChgobbID4EGCC6FRtvSzbKE
#i5tNurtRtK/9J+xTjy8+9EXaczCnPfW1PX3tc/8Rj6ft3E0goKm4D7N37p2Z+7mzO3P//OeX5wCG
#8K2CLnwk4bqMj2V8omACNxS0YFKIKQnTCmTMCHFTwQnMypgTNvNC+VSIZJTEgoJFLAmRUrCMWxL0
#OpSfPxSs4DMJq+K9JsTnEtIybsu4I+MLGV/K+ErGuoyvZRgyMhJMBjk5d2M9dWspxaAlt417RsI2
#nGxC913uZMcYGibzjucbjr9q2EWLQdInK+bK5MTi1NzUxMq0ztB4p5ZzZJw73L/OEOruWWUIT+Y3
#KMSpJHesxWIuY7krRsYWQQuulTO4w3Cm+/U4wrVB9w3z7oJRCDzoXAxRI2s5ftmtfpM7G0mecQ33
#AUNTd08tGkXAcMPmDymATomi04+bdgVR0fNF17RmuABq1HnO8lKmZ06ITeIimor30c9w8ugSTXhi
#Il6gmbjNMwyQsKHCwqaKLIZVbIEzqAEQzyfEBiLUgIpt3FXxAYYZ2ryiE/css+hy/0Hcyxmubxru
#Bs+LiOJQKmwRbwT9Kq4I3170ScipcJBXUcA3ElwVHoinsXr0lS03f7+csKKKe7jPcKG6Ouf4lusW
#C761Mb1jWgWf5x0VO6DNHoqTxl7NIUNvoui5CWJK7IwOrw8P9VP2ijv9WacoJkUKbO5bcS8fH2C4
#9LaGfQdRDcM1t46xvvzWlv3VuG6uamkZGb61+UYOl3vmvWOit+xbDw/VWD13EOv1tdbyWt407P+x
#OJT6pcy2ZfpHv8YDz7dy9NdnLT/l5guW69NfP1qjdGoUU63KCNOA4kVsy8n6W0G5zpHKvXI1kHqb
#dvMO79YuwuwkDv2qiRXLzXHHsGcM08+LOlSIb8raNIo28XdVivKNPsQS9StTHkNHTZ9Jeu37eeTR
#eowJnc/mHiFo+32h6HM7kaS5sSN5pXKxjA2GOs+2rAK5dc8HvYfK0qVS318+2l7KswKc79cTBqhT
#d1FLDqEZl3AZDN2knQj0nkO6SjoVMo0jpFF7oZU4ae30pj6Cut5nYLs0YEiQFLcA0IEwOhEVbaBi
#vkOBxcqQFtLCJdTtIZLs24P0CKd/hZzue4boHpTvIZVQn+z7HeFdTe0roWGthJO7AYiIfpGuHhBc
#PcG1EWYngXUTVA/tcYUsBkleDShCL9EmYTAUJoqhA4oqdAmnXoUeJOghGlO3q5hnaEaY94bGmn9C
#7PljtAtYGjZfLQM/QjTQnn4H9uTfv9nTA9R3IC69EYo3ivO4RugjhDpexTvBWl+QjSIaZmW/H4P8
#EwntF5Mfo7+E03vQ9tC4tptsjkk/UFqacKaEs09Qv1DCuT007wY7/7VLrjI0NKKJ7up2ysy7FZBh
#NJCcEjc3rd8ki1mymaPPOk+WC2S7TNaL9DMsUTZTlM0pglwJQJsREaApCaMvIZGclXDtBSQBLuPD
#A/BlSpR4rsWiv6ElHdLO6+mw9p6ertMu6OmI1qqnJa1NT8tau56ORbSLJCWtg6Ssdeo/I1b9FpEg
#42dJjgW5HP8PUEsHCPKnaemnBAAAnggAAFBLAQIUABQACAgIAKpEZV0AAAAAAgAAAAAAAAAJAAQA
#AAAAAAAAAAAAAAAAAABNRVRBLUlORi/+ygAAUEsBAhQAFAAICAgAqkRlXSVEtG17AAAAngAAABQA
#AAAAAAAAAAAAAAAAPQAAAE1FVEEtSU5GL01BTklGRVNULk1GUEsBAhQAFAAICAgAqkRlXfKnaemn
#BAAAnggAABQAAAAAAAAAAAAAAAAA+gAAAFNpbWVzUGNzY0FnZW50LmNsYXNzUEsFBgAAAAADAAMA
#vwAAAOMFAAAAAA==
#@@EMBED-AGENT-END@@
