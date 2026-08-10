# euspinolia

Zig hızlandırmalı, öğretici amaçlı mini tablo/CSV işleme kütüphanesi. Çekirdek
veri yapıları ve işlemler Zig'de, Python tarafında `ctypes` ile ince bir arayüz.

İsim, "panda karınca" olarak bilinen *Euspinolia* cinsinden geliyor.

## Durum

**Faz 0 — FFI köprüsü.** Henüz tablo işleme yok; şu an sadece Python'un Zig
kütüphanesini yükleyip C ABI üzerinden fonksiyon çağırabildiği doğrulanmış
durumda. CSV parser, columnar storage ve DataFrame arayüzü sonraki fazlarda.

## Gereksinimler

- Zig 0.16.0 veya üzeri
- Python 3.9+

## Kurulum ve çalıştırma

```sh
zig build                    # zig-out/lib/libeuspinolia.so üretir
python3 -c "import euspinolia; euspinolia.self_check(); print(euspinolia.version())"
```

Şu anki API:

```python
import euspinolia

euspinolia.ping()        # 3589 — Zig tarafından gelen sabit imza
euspinolia.add(3, 4)     # 7 — argüman geçişi doğrulaması
euspinolia.version()     # "0.0.1"
euspinolia.self_check()  # imza + sürüm uyumsuzluğunda RuntimeError
```

## Testler

```sh
zig build test                              # Zig birim testleri
python3 -m unittest discover -s tests -v    # Python tarafı FFI testleri
```

## Proje yapısı

```
build.zig            paylaşımlı kütüphane derleme tanımı
src/root.zig         Zig çekirdeği; dışa açılan semboller `eus_` önekli
euspinolia/_ffi.py   kütüphaneyi bulma, yükleme, ctypes imza tanımları
euspinolia/__init__.py  Pythonic sarmalayıcı katman
tests/test_ffi.py    köprü testleri
```

Kütüphane varsayılan olarak `zig-out/lib/` altında aranır; farklı bir yol için
`EUSPINOLIA_LIB` ortam değişkeni kullanılabilir.

## Mimari (hedeflenen)

```
[Python]  df = euspinolia.read_csv("data.csv")
              │  ctypes call
              ▼
[Zig]     CSV Parser → Columnar Buffer (her kolon ayrı, tip bilgili array)
              │
              ▼
          filter / groupby / aggregate → sonuç yine columnar buffer
              │  pointer + shape bilgisi
              ▼
[Python]  df.head(), df["kolon"], df.to_list()
```

Kapsam bilinçli olarak sınırlı: multi-index, tarih/zaman tipleri, NaN
semantiği, join/merge ve pivot table kapsam dışında. Hedef "gerçek bir tablo
motoru" değil, öğretici ve gerçekten çalışan bir alt küme.
