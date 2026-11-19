# Yazıcı Yönetimi (yazici-yonetimi.sh)

Debian 13 ve TÜBİTAK Pardus 25 için menü tabanlı yazıcı yönetim scripti.
Ağ yazıcılarının otomatik eklenmesini ve yazdırma iletişim kutusunda görünmesini
kontrol eder; yazıcı ekleme/kaldırma işlemlerinde yönetici şifresi istenmesini kaldırır.

## Özellikler

- `cups-browsed` servisini gösterir, kapatır (durdur + devre dışı) veya açar (etkinleştir + başlat).
- Yazdırma kutusundaki ağ yazıcılarını iki katmanlı modelle gizler/gösterir:
  1. **CUPS keşfi:** `cupsctl` ile `Browsing Off`, `BrowseLocalProtocols none`, `BrowseRemoteProtocols none`.
  2. **Avahi keşfi (gerekirse, onayla):** `use-ipv4=no`, `use-ipv6=no`.
- Tüm kullanıcılar için şifresiz yazıcı ekleme/kaldırma polkit kuralı ekler/kaldırır.
- `system-config-printer` paketini kurar (`apt update` + `apt install -y`).
- Değişiklik öncesi otomatik yedek, işlem günlüğü ve tekil çalışma kilidi.

## Gereksinimler

- systemd tabanlı Debian 13 / Pardus 25
- root yetkisi
- İlgili işlevler için: `cups`, `avahi-daemon`, `polkit`

## Kurulum ve Çalıştırma

```bash
chmod +x printer-management.sh
sudo ./printer-management.sh