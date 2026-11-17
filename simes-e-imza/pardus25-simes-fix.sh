#!/usr/bin/env bash
set -u
umask 022
VERSION="2.6.7-6"
MARKER="# simes-pcsc-fix: Pardus 25 libpcsclite.so.1 uyumlulugu - kaldirmak icin: simes-pcsc-fix --revert"
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
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
QUIET=0
MODE="repair"
TARGET_DIR=""
ALL=0
log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
usage() {
local n="${0##*/}"
cat <<EOF
Kullanim: $n [SECENEK]
(secenek yok)     Bulunan SiMES kurulumlarini onar (akia dahil)
--check           Onarim gerekip gerekmedigini soyle (yazmaz)
--revert          Eklenen satirlari ve ajani kaldir
--verify          SiMES'in kendi kodu okuyucuyu goruyor mu (teshis)
--dir YOL         Yalnizca bu kurulum dizinini isle
--all             Tum kullanicilari isle (root)
--no-deps         akia kontrolunu/kurulumunu atla
--quiet           Yalnizca hata bas
--version         Surum
--help            Bu metin
Cikis kodlari: 0 basarili, 1 onarim gerekli/okuyucu yok, 2 hata.
EOF
}
while [ $# -gt 0 ]; do
case "$1" in
--check)   MODE="check" ;;
--revert)  MODE="revert" ;;
--verify)  MODE="verify" ;;
--all)     ALL=1 ;;
--no-deps) NO_DEPS=1 ;;
--quiet)   QUIET=1 ;;
--version) printf '%s %s\n' "${0##*/}" "$VERSION"; exit 0 ;;
--help|-h) usage; exit 0 ;;
--dir)
[ $# -ge 2 ] || { err "--dir bir yol ister"; exit 2; }
TARGET_DIR="$2"; shift ;;
*)
err "Bilinmeyen arguman: $1"; usage >&2; exit 2 ;;
esac
shift
done
# --------------------------------------------------------------------------
# PC/SC kutuphanesi ve ajan dosyasi
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
if [ -e "$SIMES_PCSC_FIX_LIB" ]; then
printf '%s\n' "$SIMES_PCSC_FIX_LIB"
return 0
fi
err "libpcsclite.so.1 bulunamadi: $SIMES_PCSC_FIX_LIB"
return 2
fi
ma="$(multiarch_dir)"
for cand in \
"/usr/lib/$ma/libpcsclite.so.1" \
"/lib/$ma/libpcsclite.so.1" \
"/usr/lib64/libpcsclite.so.1" \
"/usr/lib/libpcsclite.so.1"; do
if [ -e "$cand" ]; then
printf '%s\n' "$cand"
return 0
fi
done
err "libpcsclite.so.1 bulunamadi (pcsc suruculeri kurulu mu?)"
return 2
}
AGENT_SRC=""
AGENT_TMP=""
cleanup_agent_tmp() {
[ -n "$AGENT_TMP" ] && rm -f -- "$AGENT_TMP"
return 0
}
trap cleanup_agent_tmp EXIT
extract_embedded_agent() {
local tmp
if ! command -v base64 >/dev/null 2>&1; then
err "base64 bulunamadi (coreutils paketi gerekli)"
return 1
fi
tmp="$(mktemp "${TMPDIR:-/tmp}/simes-pcsc-agent.XXXXXX")" || {
err "gomulu ajan icin gecici dosya acilamadi"
return 1
}
if ! awk -v b="$EMBED_BEGIN" -v e="$EMBED_END" '
$0 == b { on = 1; next }
$0 == e { on = 0 }
on { sub(/^#/, ""); print }
' "$SELF" | base64 -d > "$tmp" 2>/dev/null; then
rm -f -- "$tmp"
err "gomulu ajan cikarilamadi (betik bozuk olabilir)"
return 1
fi
if [ "$(head -c2 -- "$tmp" 2>/dev/null)" != "PK" ]; then
rm -f -- "$tmp"
err "gomulu ajan gecersiz (PK imzasi yok)"
return 1
fi
chmod 0644 "$tmp" 2>/dev/null || true
AGENT_TMP="$tmp"
AGENT_SRC="$tmp"
return 0
}
resolve_agent_jar() {
local cand
AGENT_SRC=""
if [ -n "${SIMES_PCSC_FIX_EMBEDDED_ONLY:-}" ]; then
extract_embedded_agent
return $?
fi
if [ -n "${SIMES_PCSC_FIX_AGENT_JAR:-}" ]; then
if [ -f "$SIMES_PCSC_FIX_AGENT_JAR" ]; then
AGENT_SRC="$SIMES_PCSC_FIX_AGENT_JAR"
return 0
fi
return 1
fi
for cand in \
"$(dirname "$SELF")/agent/$AGENT_JAR_NAME" \
"$(dirname "$SELF")/$AGENT_JAR_NAME" \
"/usr/share/simes-pcsc-fix/$AGENT_JAR_NAME"; do
if [ -f "$cand" ]; then
AGENT_SRC="$cand"
return 0
fi
done
extract_embedded_agent
}
# --------------------------------------------------------------------------
# akia surucu paketi (/usr/lib/libakisp11.so)
# --------------------------------------------------------------------------
AKIA_PKG="akia"
AKIA_LIB="/usr/lib/libakisp11.so"
AKIA_LIB_CHECK="${SIMES_PCSC_FIX_AKIA_LIB:-$AKIA_LIB}"
: "${NO_DEPS:=0}"
akia_installed() {
dpkg-query -W -f='${Status}' "$AKIA_PKG" 2>/dev/null | grep -qx 'install ok installed'
}
akia_lib_ok() {
[ -f "$AKIA_LIB_CHECK" ] && [ -r "$AKIA_LIB_CHECK" ] || return 1
[ "$(head -c4 -- "$AKIA_LIB_CHECK" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}
akia_state() {
if ! akia_installed; then
printf 'missing\n'
elif akia_lib_ok; then
printf 'ok\n'
else
printf 'broken\n'
fi
}
akia_state_text() {
case "$1" in
ok) printf 'kurulu ve saglam\n' ;;
missing) printf 'kurulu degil\n' ;;
broken) printf 'kurulu ama %s eksik/bozuk\n' "$AKIA_LIB" ;;
*) printf 'bilinmiyor\n' ;;
esac
}
apt_run() {
if [ "$(id -u)" -eq 0 ]; then
"$@"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
sudo -n "$@"
else
return 127
fi
}
apt_hint() {
local mode="$1"
if [ "$mode" = "reinstall" ]; then
err "Elle calistirin: sudo apt update && sudo apt install --reinstall $AKIA_PKG"
else
err "Elle calistirin: sudo apt update && sudo apt install $AKIA_PKG"
fi
}
apt_fix_akia() {
local mode="$1" rc
local -a args=(install -y)
[ "$mode" = "reinstall" ] && args+=(--reinstall)
args+=("$AKIA_PKG")
if DEBIAN_FRONTEND=noninteractive apt_run apt-get "${args[@]}" </dev/null >/dev/null 2>&1; then
return 0
fi
rc=$?
if [ "$rc" -eq 127 ]; then
err "akia: kurmak icin root yetkisi gerekiyor (parolasiz sudo yok)"
apt_hint "$mode"
return 2
fi
log "akia: paket listesi guncelleniyor (apt update)"
DEBIAN_FRONTEND=noninteractive apt_run apt-get update </dev/null >/dev/null 2>&1 || \
err "akia: apt update basarisiz, kurulum yine denenecek"
if DEBIAN_FRONTEND=noninteractive apt_run apt-get "${args[@]}" </dev/null >/dev/null 2>&1; then
return 0
fi
rc=$?
if [ "$rc" -eq 127 ]; then
err "akia: kurmak icin root yetkisi gerekiyor (parolasiz sudo yok)"
apt_hint "$mode"
return 2
fi
err "akia: kurulum basarisiz (apt-get cikis $rc)"
apt_hint "$mode"
return 1
}
ensure_akia() {
local st
st="$(akia_state)"
case "$st" in
ok)
log "akia: kurulu ve saglam ($AKIA_LIB_CHECK)"
return 0 ;;
missing)
log "akia: kurulu degil, kuruluyor..."
apt_fix_akia install || return $? ;;
broken)
log "akia: kurulu ama $AKIA_LIB eksik/bozuk, yeniden kuruluyor..."
apt_fix_akia reinstall || return $? ;;
esac
st="$(akia_state)"
if [ "$st" != "ok" ]; then
err "akia: kurulumdan sonra durum: $(akia_state_text "$st")"
return 1
fi
if akia_installed; then
log "akia: kuruldu ($(dpkg-query -W -f='${Version}' "$AKIA_PKG" 2>/dev/null))"
fi
return 0
}
# --------------------------------------------------------------------------
# Kurulum tespiti
# --------------------------------------------------------------------------
is_install() {
local d="$1"
[ -d "$d" ] && [ -f "$d/SimesAgent" ] && [ -f "$d/simes-desktop-agent.jar" ]
}
# sudo ile calisilirsa SUDO_USER'in ev dizini; degilse $HOME.
effective_home() {
local h
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
if [ -n "$h" ]; then
printf '%s\n' "$h"
return 0
fi
fi
printf '%s\n' "${HOME:-}"
}
desktop_entry_dir() {
local home="${1:-${HOME:-/nonexistent}}" f line d
for f in "$home"/.local/share/applications/install4j_*-SimesAgent.desktop; do
[ -f "$f" ] || continue
while IFS= read -r line; do
case "$line" in
Exec=*)
d="${line#Exec=}"
d="${d#\"}"
case "$d" in
*"/SimesAgent"*) d="${d%%/SimesAgent*}" ;;
*) continue ;;
esac
printf '%s\n' "$d"
return 0 ;;
esac
done < "$f"
done
return 1
}
# find_installs [KOK] [FALLBACK]
#   FALLBACK=1 ve root ise, bulunamazsa /home ve /root taranir.
#   do_all kullanici bazli cagirirken 0 gecer (capraz eslesmeyi onler).
find_installs() {
local root="${1:-$(effective_home)}"
local allow_fallback="${2:-1}"
local d found=0 list rc
local -a seen=()
add_candidate() {
local c="$1" s
[ -n "$c" ] || return 0
is_install "$c" || return 0
for s in "${seen[@]:-}"; do
[ "$s" = "$c" ] && return 0
done
seen+=("$c")
printf '%s\n' "$c"
found=1
}
d="$(desktop_entry_dir "$root" || true)"
[ -n "$d" ] && add_candidate "$d"
add_candidate "$root/SimesIstemci"
add_candidate "$root/Simes/SimesIstemci"
list="$(mktemp "${TMPDIR:-/tmp}/simes-find.XXXXXX")" || return 3
if command -v timeout >/dev/null 2>&1; then
timeout "${SIMES_PCSC_FIX_FIND_TIMEOUT:-10}" \
find "$root" -maxdepth 3 -name simes-desktop-agent.jar -printf '%h\n' > "$list" 2>/dev/null
rc=$?
else
find "$root" -maxdepth 3 -name simes-desktop-agent.jar -printf '%h\n' > "$list" 2>/dev/null
rc=$?
fi
if [ "$rc" -eq 124 ]; then
rm -f "$list"
return 3
fi
while IFS= read -r d; do
[ -n "$d" ] && add_candidate "$d"
done < "$list"
if [ "$found" -eq 0 ] && [ "$allow_fallback" -eq 1 ] && [ "$(id -u)" -eq 0 ]; then
: > "$list"
if command -v timeout >/dev/null 2>&1; then
timeout "${SIMES_PCSC_FIX_FIND_TIMEOUT:-10}" \
find /home /root -maxdepth 4 -name simes-desktop-agent.jar -printf '%h\n' > "$list" 2>/dev/null
else
find /home /root -maxdepth 4 -name simes-desktop-agent.jar -printf '%h\n' > "$list" 2>/dev/null
fi
while IFS= read -r d; do
[ -n "$d" ] && add_candidate "$d"
done < "$list"
fi
rm -f "$list"
[ "$found" -eq 1 ]
}
# --------------------------------------------------------------------------
# Onarim
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
prev="$(sed -n "$((n - 1))p" "$vmo")"
prev="${prev%$'\r'}"
[ "$prev" = "$MARKER" ]
}
agent_ok() {
local d="$1" vmo="$d/SimesAgent.vmoptions"
[ -f "$d/$AGENT_JAR_NAME" ] || return 1
awk -v arg="$AGENT_ARG" '{ sub(/\r$/, "") } $0 == arg { found = 1; exit } END { exit(found ? 0 : 1) }' "$vmo"
}
set_eol() {
if grep -q $'\r$' "$1" 2>/dev/null; then
EOL=$'\r\n'
else
EOL=$'\n'
fi
}
prop_state() {
local vmo="$1" cur lib
lib="$(lib_path)" || return 2
if ! cur="$(prop_value "$vmo")"; then
printf 'none\n'
return 0
fi
if [ "$cur" = "$lib" ]; then
printf 'ok\n'
elif prop_is_ours "$vmo"; then
printf 'ours-bad\n'
elif [ -e "$cur" ]; then
printf 'ok\n'
else
printf 'vendor-bad\n'
fi
}
full_state() {
local d="$1" ps
ps="$(prop_state "$d/SimesAgent.vmoptions")" || return 2
case "$ps" in
vendor-bad) printf 'vendor-bad\n'; return 0 ;;
ok)
if agent_ok "$d"; then printf 'ok\n'; else printf 'ours-bad\n'; fi
return 0 ;;
*) printf '%s\n' "$ps"; return 0 ;;
esac
}
do_check() {
local d="$1" state astate
if [ "$NO_DEPS" -eq 0 ]; then
astate="$(akia_state)"
if [ "$astate" = "ok" ]; then
log "akia: kurulu ve saglam"
else
log "akia: $(akia_state_text "$astate") -> onarim gerekli"
fi
fi
state="$(full_state "$d")" || return 2
case "$state" in
ok)
log "$d: onarili"
[ "$NO_DEPS" -eq 1 ] || [ "$astate" = "ok" ] || return 1
return 0 ;;
vendor-bad)
err "Satici tarafindan tanimli ${PROP_KEY} satiri var ama dosya yok: $d/SimesAgent.vmoptions"
return 1 ;;
none|ours-bad)
log "$d: onarim-gerekli"
return 1 ;;
esac
return 2
}
install_agent() {
local d="$1" vmo="$d/SimesAgent.vmoptions" src dst tmp
dst="$d/$AGENT_JAR_NAME"
if ! resolve_agent_jar; then
err "simes-pcsc-agent.jar bulunamadi (paket bozuk olabilir)"
return 2
fi
src="$AGENT_SRC"
if [ -f "$dst" ] && cmp -s -- "$src" "$dst"; then
return 0
fi
tmp="$(mktemp "$d/.simes-pcsc-agent.XXXXXX")" || {
err "ajan kurulum dizinine yazilamadi: $d"
return 2
}
if ! cp -- "$src" "$tmp"; then
rm -f "$tmp"
err "ajan kurulum dizinine yazilamadi: $d"
return 2
fi
chmod 0644 "$tmp" 2>/dev/null || true
chown --reference="$vmo" "$tmp" 2>/dev/null || true
if ! mv -f -- "$tmp" "$dst"; then
rm -f "$tmp"
err "ajan kurulum dizinine yazilamadi: $d"
return 2
fi
if [ "$(id -u)" -eq 0 ]; then
chown --reference="$d" "$dst" 2>/dev/null || true
fi
return 0
}
strip_our_block() {
local vmo="$1" out="$2" eol="$3" line skip=0
: > "$out"
[ -f "$vmo" ] || return 0
while IFS= read -r line || [ -n "$line" ]; do
line="${line%$'\r'}"
if [ "$skip" -eq 1 ]; then
case "$line" in
"$PROP_PREFIX"*|"$AGENT_LIB_PREFIX"*|"$AGENT_ARG_PREFIX"*) continue ;;
esac
skip=0
fi
if [ "$line" = "$MARKER" ]; then
skip=1
continue
fi
printf '%s%s' "$line" "$eol" >> "$out"
done < "$vmo"
}
do_repair() {
local d="$1" vmo="$d/SimesAgent.vmoptions" lib state tmp eol
lib="$(lib_path)" || return 2
state="$(full_state "$d")" || return 2
if [ "$NO_DEPS" -eq 0 ]; then
ensure_akia || return 2
fi
case "$state" in
ok)
log "$d: zaten onarili"
return 0 ;;
vendor-bad)
err "Satici tarafindan tanimli ${PROP_KEY} satiri bulundu, dokunulmadi: $vmo"
return 0 ;;
esac
if [ -f "$vmo" ] && [ ! -w "$vmo" ]; then
err "SimesAgent.vmoptions yazilamadi: $vmo"
return 2
fi
if [ ! -w "$d" ]; then
err "SiMES kurulum dizinine yazilamadi: $d"
return 2
fi
install_agent "$d" || return 2
tmp="$(mktemp "$(dirname "$vmo")/.simes-pcsc-fix.XXXXXX")" || {
err "SimesAgent.vmoptions yazilamadi: $vmo"
return 2
}
set_eol "$vmo"
eol="$EOL"
strip_our_block "$vmo" "$tmp" "$eol"
if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
printf '%s' "$eol" >> "$tmp"
fi
printf '%s%s' "$MARKER" "$eol" >> "$tmp"
printf '%s%s%s' "$PROP_PREFIX" "$lib" "$eol" >> "$tmp"
printf '%s%s%s' "$AGENT_LIB_PREFIX" "$lib" "$eol" >> "$tmp"
printf '%s%s' "$AGENT_ARG" "$eol" >> "$tmp"
if ! chmod --reference="$vmo" "$tmp" 2>/dev/null; then
chmod 0644 "$tmp" 2>/dev/null || true
fi
chown --reference="$vmo" "$tmp" 2>/dev/null || true
if ! mv -f -- "$tmp" "$vmo"; then
rm -f "$tmp"
err "SimesAgent.vmoptions yazilamadi: $vmo"
return 2
fi
if [ "$(id -u)" -eq 0 ]; then
chown --reference="$d" "$vmo" 2>/dev/null || true
fi
log "$d: onarildi"
log "  SiMES çalısıyorsa kapatıp yeniden açın; değişiklikler yeni açılışta devreye girer."
return 0
}
has_marker() {
awk -v m="$MARKER" '{ sub(/\r$/, "") } $0 == m { found = 1; exit } END { exit(found ? 0 : 1) }' "$1"
}
# --------------------------------------------------------------------------
# Geri alma
# --------------------------------------------------------------------------
do_revert() {
local d="$1" vmo="$d/SimesAgent.vmoptions" tmp eol
local had_marker=0
if [ -f "$vmo" ] && has_marker "$vmo"; then
had_marker=1
fi
if [ "$had_marker" -eq 0 ] && [ ! -f "$d/$AGENT_JAR_NAME" ]; then
log "$d: kaldirilacak satir yok"
return 0
fi
if [ -f "$vmo" ] && [ ! -w "$vmo" ]; then
err "SimesAgent.vmoptions yazilamadi: $vmo"
return 2
fi
if [ "$had_marker" -eq 1 ]; then
tmp="$(mktemp "$(dirname "$vmo")/.simes-pcsc-fix.XXXXXX")" || {
err "SimesAgent.vmoptions yazilamadi: $vmo"
return 2
}
set_eol "$vmo"
eol="$EOL"
strip_our_block "$vmo" "$tmp" "$eol"
if ! chmod --reference="$vmo" "$tmp" 2>/dev/null; then
chmod 0600 "$tmp" 2>/dev/null || true
fi
chown --reference="$vmo" "$tmp" 2>/dev/null || true
if ! mv -f -- "$tmp" "$vmo"; then
rm -f "$tmp"
err "SimesAgent.vmoptions yazilamadi: $vmo"
return 2
fi
if [ "$(id -u)" -eq 0 ]; then
chown --reference="$d" "$vmo" 2>/dev/null || true
fi
if [ ! -s "$vmo" ]; then
rm -f -- "$vmo" || true
fi
fi
if [ -f "$d/$AGENT_JAR_NAME" ]; then
rm -f -- "$d/$AGENT_JAR_NAME" || {
err "ajan dosyasi kaldirilamadi: $d/$AGENT_JAR_NAME"
return 2
}
fi
log "$d: satirlar kaldirildi"
return 0
}
# --------------------------------------------------------------------------
# Teshis
# --------------------------------------------------------------------------
verify_classes() {
if [ -n "${SIMES_PCSC_FIX_VERIFY_CLASSES:-}" ]; then
printf '%s\n' "$SIMES_PCSC_FIX_VERIFY_CLASSES"
return 0
fi
if [ -d "$(dirname "$SELF")/verify" ]; then
printf '%s\n' "$(dirname "$SELF")/verify"
return 0
fi
printf '%s\n' "/usr/share/simes-pcsc-fix"
}
do_verify() {
local d="$1" out rc classes prop errout errfile
local -a jvm_args=()
[ -x "$d/jre/bin/java" ] || { err "java calistirilamadi: $d/jre/bin/java"; return 2; }
[ -f "$d/simes-desktop-agent.jar" ] || { err "jar bulunamadi: $d/simes-desktop-agent.jar"; return 2; }
if [ "$NO_DEPS" -eq 0 ] && [ "$(akia_state)" != "ok" ]; then
err "uyari: akia $(akia_state_text "$(akia_state)") - okuyucu gorunse de SiMES kayit yapamaz (simes-fix.sh ile duzeltin)"
fi
classes="$(verify_classes)"
if agent_ok "$d"; then
jvm_args+=("$AGENT_ARG")
jvm_args+=("-Dsun.security.smartcardio.library=$BARE_OVERRIDE")
elif prop="$(prop_value "$d/SimesAgent.vmoptions")" && [ -n "$prop" ]; then
jvm_args+=("-Dsun.security.smartcardio.library=$prop")
fi
errfile="$(mktemp "${TMPDIR:-/tmp}/simes-verify-err.XXXXXX")" || {
err "dogrulama icin gecici dosya acilamadi"
return 2
}
out="$(cd "$d" && "$d/jre/bin/java" ${jvm_args[@]+"${jvm_args[@]}"} -cp "$classes:$d/simes-desktop-agent.jar" VerifyReaders 2>"$errfile")"
rc=$?
errout="$(cat -- "$errfile" 2>/dev/null)"
rm -f "$errfile"
if [ "$rc" -eq 0 ]; then
if [ -n "$out" ]; then
printf '%s\n' "$out"
return 0
fi
return 1
fi
err "dogrulama calistirilamadi (java cikis $rc)${errout:+: $errout}"
case "$errout" in
*CardException*)
err "ipucu: PC/SC katmanina erisilemedi. Surucu tarafini kontrol edin: systemctl status pcscd.socket; pcsc_scan" ;;
esac
return 2
}
# --------------------------------------------------------------------------
# Root turu
# --------------------------------------------------------------------------
mode_status() {
case "$MODE" in
check)
case "$1" in
0) printf 'onarili\n' ;;
1) printf 'onarim-gerekli\n' ;;
*) printf 'erisilemedi\n' ;;
esac ;;
verify)
case "$1" in
0) printf 'okuyucu-var\n' ;;
1) printf 'okuyucu-yok\n' ;;
*) printf 'erisilemedi\n' ;;
esac ;;
*)
if [ "$1" -eq 0 ]; then
printf 'uygulandi\n'
else
printf 'erisilemedi\n'
fi ;;
esac
}
do_all() {
local getent user uid home shell d st mode_arg discovered dst status worst=0
getent="${SIMES_PCSC_FIX_GETENT:-getent}"
if [ "$(id -u)" -ne 0 ]; then
err "--all yalnizca root olarak calistirilabilir"
return 2
fi
if ! command -v "$getent" >/dev/null 2>&1; then
err "getent bulunamadi"
return 2
fi
if [ "$NO_DEPS" -eq 0 ] && [ "$MODE" != "revert" ]; then
if [ "$MODE" = "check" ]; then
local astate
astate="$(akia_state)"
if [ "$astate" = "ok" ]; then
printf 'akia: kurulu ve saglam\n'
else
printf 'akia: %s -> onarim gerekli\n' "$(akia_state_text "$astate")"
worst=1
fi
else
ensure_akia || worst=2
fi
fi
while IFS=: read -r user _ uid _ _ home shell; do
case "$uid" in
''|*[!0-9]*) continue ;;
esac
case "$shell" in
*/nologin|*/false|'') continue ;;
esac
if [ "$uid" -ne 0 ] && [ "$uid" -lt 1000 ]; then
continue
fi
[ -n "$home" ] || continue
if command -v timeout >/dev/null 2>&1; then
timeout 5 test -d "$home"
else
test -d "$home"
fi
if [ $? -ne 0 ]; then
printf '%s: erisilemedi\n' "$user"
worst=2
continue
fi
discovered="$(HOME="$home" find_installs "$home" 0 2>/dev/null)"
dst=$?
if [ "$dst" -eq 3 ]; then
printf '%s: erisilemedi\n' "$user"
worst=2
continue
fi
if [ -z "$discovered" ]; then
printf '%s: kurulum-yok\n' "$user"
continue
fi
while IFS= read -r d; do
[ -n "$d" ] || continue
mode_arg=""
case "$MODE" in
check) mode_arg="--check" ;;
revert) mode_arg="--revert" ;;
verify) mode_arg="--verify" ;;
esac
if command -v runuser >/dev/null 2>&1; then
timeout 10 runuser -u "$user" -- "$SELF" --dir "$d" ${mode_arg:+"$mode_arg"} --quiet >/dev/null 2>&1
else
timeout 10 su -s /bin/sh -c "$(printf '%q --dir %q %s --quiet' "$SELF" "$d" "$mode_arg")" "$user" >/dev/null 2>&1
fi
st=$?
status="$(mode_status "$st")"
printf '%s: %s\n' "$user" "$status"
if [ "$st" -eq 2 ]; then
worst=2
elif [ "$st" -eq 1 ] && [ "$worst" -lt 1 ]; then
worst=1
fi
done <<< "$discovered"
done < <("$getent" passwd)
return "$worst"
}
# --------------------------------------------------------------------------
# Ana akis
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
if [ "$ALL" -eq 1 ]; then
do_all
exit $?
fi
if [ -n "$TARGET_DIR" ]; then
if ! is_install "$TARGET_DIR"; then
err "SiMES kurulumu bulunamadi: $TARGET_DIR"
exit 2
fi
run_for "$TARGET_DIR"
exit $?
fi
discovered="$(find_installs)"
dst=$?
if [ "$dst" -eq 3 ]; then
err "SiMES kurulumlari aranirken zaman asimi (ev dizini erisilemiyor olabilir)"
exit 2
fi
if [ "$dst" -ne 0 ] || [ -z "$discovered" ]; then
err "SiMES kurulumu bulunamadi"
exit 2
fi
mapfile -t INSTALLS <<< "$discovered"
rc=0
for d in "${INSTALLS[@]}"; do
run_for "$d"
st=$?
if [ "$st" -eq 2 ]; then
exit 2
fi
if [ "$st" -eq 1 ]; then
rc=1
fi
done
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
