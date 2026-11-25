# pardus25-simes-auto 

Kullanım:

chmod +x pardus25-simes-auto.sh

./pardus25-simes-auto.sh

Pardus 25 üzerinde **SiMES e-imza istemcisinin (3.2.0) akıllı kart okuyucuyu
görememesi** sorununu onaran betik.

## Ne işe yarar?

- **PC/SC uyumluluğu:** Pardus 25'in yeni `libpcsclite` kütüphanesi ile SiMES'in gömülü
  JRE'si arasındaki uyumsuzluğu giderir. `SimesAgent.vmoptions` dosyasına işaretli bir
  blok ekler ve kütüphaneyi tam yoluyla önceden yükleyen küçük bir javaagent
  (`simes-pcsc-agent.jar`, betiğe gömülü) kurar.
- **Sistem katmanı (bir kez):** `akia` sürücü paketini kurar/onarır, `pcscd` servisini
  çalışır hale getirir.
- **Çoklu kullanıcı:** Tüm gerçek kullanıcıların ev dizinlerindeki SiMES kurulumlarını
  bulur, her birini sahipliğini koruyarak onarır.
- **Kurulum (`--install`):** Hiç kurulum yoksa HMB sayfasından güncel Linux sürümünü
  indirip **çağıran kullanıcıya** kurar (sistem geneli kurulum yapmaz).
- **Geri alınabilir:** Eklenen her şey `--revert` ile kaldırılır; satıcıya ait satırlara
  dokunulmaz.

## Hızlı başlangıç

```bash
./pardus25-simes-auto.sh              # Varsayılan eylem kurulum oldu


(secenek yok)     Tum kullanicilardaki SiMES kurulumlarini onar (akia+pcscd dahil)
--check           Onarim gerekip gerekmedigini soyle (yazmaz)
--revert          Eklenen satirlari ve ajani kaldir
--verify          SiMES'in kendi kodu okuyucuyu goruyor mu (teshis)
--install         Hic kurulum yoksa guncel surumu indirip CAGIRAN kullaniciya kur
--dir YOL         Yalnizca bu kurulum dizinini isle
--all             Tum kullanicilari isle (root)
--no-deps         akia/pcscd kontrolunu atla
--quiet           Yalnizca hata bas
--version         Surum
--help            Bu metin

Çıkış kodları

0 Başarılı / sistem hazır
1 Onarım gerekli veya okuyucu yok
2 Hata

Notlar

    Onarımdan sonra SiMES'i kapatıp yeniden açın; ajan yeni açılışta devreye girer.
    Betik idempotent'tir; tekrar çalıştırmak güvenlidir. Yazmalar atomiktir
    (geçici dosya + taşıma), sahiplik ve izinler korunur.
    Sistem katmanı (akia/pcscd) için root veya parolasız sudo gerekir; kurulum onarımı
    normal kullanıcı yetkisiyle de yapılabilir.
    --install için unzip ve curl/wget gerekir; arşiv indirildikten sonra
    bütünlüğü doğrulanır.
    Gereksinimler: bash, coreutils, pcsc-lite, akia (apt üzerinden).
