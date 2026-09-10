# LocalVoiceAI iOS v3 — Qwen + Whisper + Turkish TTS

Bu paket mevcut `local-qwen-ios` GitHub repo'sunun üzerine kopyalanacak bir **repo overlay**'idir. Mac gerekmez; GitHub Actions macOS runner, iPhone için tek bir unsigned IPA üretir.

## Bu sürümde ne var?

- Qwen GGUF (`llama.cpp`) — cihaz içinde, offline
- Qwen3 thinking / non-thinking kontrolü
- Qwen3 için uygun sampler ve ChatML prompt akışı
- Whisper (`whisper.cpp` v1.9.2) — cihaz içinde, offline
- **Whisper aç/kapa** kontrolü
- Whisper `.bin` model seçimi ve Dosyalar'dan import
- Mikrofonla 16 kHz mono PCM kayıt
- Türkçe transkripsiyon (`language = tr`)
- Konuşma biter bitmez otomatik Qwen'e gönderme seçeneği
- iOS `AVSpeechSynthesizer` ile Türkçe sesli cevap
- **Düşük bellek modu**: varsayılan açık; Whisper çalışırken Qwen'i RAM'den geçici boşaltır ve sonra geri yükler. iPhone 13 + Qwen3 1.7B için önerilir.
- GGUF ve Whisper model dosyaları IPA'ya gömülmez; `Documents` içinde kalır. Böylece IPA küçük kalır ve model değiştirmek için yeniden sign gerekmez.

## Önerilen dosyalar

Qwen için telefonda çalıştırabildiğin modeli kullan:

`Qwen3-1.7B-Q4_K_M.gguf`

Whisper için önce:

`ggml-base-q5_1.bin`

ile dene. Bellek veya hız sorununda multilingual `tiny` quantize Whisper modeline inebilirsin. `.en` model kullanma; Türkçe için multilingual model gerekir.

## Windows'tan güncelleme

ZIP'in içindeki dosyaları mevcut repo klasörünün köküne kopyala. `.github` gizli klasörünün de kopyalandığından emin ol.

```bash
git add .
git commit -m "LocalVoiceAI v3.2 voice"
git push
```

GitHub -> Actions -> **Build LocalVoiceAI iOS v3.2 Voice**.

Başarılı build sonunda artifact:

`LocalVoiceAI-v3.2-Voice-unsigned-IPA`

İçindeki dosya:

`LocalVoiceAI-v3.2-Voice-unsigned.ipa`

Bunu Sideloadly + Remote Anisette ile sign/install et.

## Telefonda ilk kullanım

1. Qwen `.gguf` dosyanı uygulamanın Documents alanına koy veya Model -> Dosyalardan GGUF ekle ile seç.
2. Qwen'i yükle.
3. `ggml-base-q5_1.bin` dosyanı aynı Documents alanına koy veya Whisper menüsünden Dosyalardan Whisper `.bin` ekle.
4. Whisper satırındaki switch'i aç.
5. Whisper modelini seç.
6. Alttaki mikrofon düğmesine bas, konuş, bitince aynı düğmeye tekrar bas.
7. Varsayılan olarak transkripsiyon otomatik Qwen'e gönderilir ve Qwen cevabı Türkçe seslendirilir.

İlk mikrofon kullanımında iOS izin isteyecek.

## Bellek davranışı

`Düşük bellek modu` varsayılan olarak açık tasarlandı:

```text
Qwen yüklü
   ↓
Konuşma kaydı
   ↓
Qwen RAM'den geçici boşaltılır
   ↓
Whisper yüklenir -> Türkçe metin -> Whisper serbest bırakılır
   ↓
Qwen yeniden yüklenir
   ↓
Metin Qwen'e gönderilir -> cevap -> iOS TTS
```

Bu, sesli turu biraz yavaşlatır ama 4 GB RAM'li iPhone 13'te Qwen3 1.7B ile en güvenli başlangıçtır. Ayarlardan `Düşük bellek modu`nu kapatırsan Qwen RAM'de kalır; sesli tur daha hızlı olabilir ama bellek baskısı artar.

## Neden Whisper CPU-only build?

`llama.xcframework` zaten kendi ggml/Metal runtime'ını içeriyor. Ayrı bir resmi `whisper.xcframework` de ggml/Metal içerdiğinde aynı uygulamada çakışma riski oluşabiliyor. Workflow, Whisper'ı CPU + Accelerate olarak ayrı framework halinde derler ve yalnızca `whisper_*` sembollerini export eder. Qwen Metal kullanmaya devam eder.

## Gizlilik / offline çalışma

Model dosyaları yüklendikten sonra inference yolu:

```text
Mikrofon -> yerel WAV -> whisper.cpp -> metin -> llama.cpp/Qwen -> yanıt -> iOS TTS
```

Whisper/Qwen inference için PC, localhost server veya bulut API gerekmez.


## v3.2 build fix

GitHub Actions patch adimindaki `upstream sampler init block not found` hatasi giderildi. Sampler artik upstream kaynak kodundaki bosluklara bagli bir metin degistirme ile yamalanmiyor; uygulama her uretimden once `configureSampling()` ile ayarlari runtime tarafinda kuruyor.
