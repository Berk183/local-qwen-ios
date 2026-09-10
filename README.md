# LocalVoiceAI iOS v1

Bu sürüm, iPhone üzerinde tamamen yerel `llama.cpp` inference yapan **kendi sohbet arayüzümüzün ilk sürümüdür**.

## Bu sürümde ne var?

- Qwen2.5-Instruct için doğru ChatML prompt formatı
- Çok turlu sohbet (2K context'i korumak için son 8 mesaj)
- GGUF dosyalarını uygulamanın Documents alanından görme
- Dosyalar uygulamasından `.gguf` import etme
- Model yükleme / boşaltma
- Streaming cevap
- Gerçek üretime daha yakın token/sn göstergesi
- iOS `AVSpeechSynthesizer` ile Türkçe sesli cevap
- Tamamen cihaz üzerinde çalışma; model inference için HTTP/server yok

> v1'de **Whisper/mikrofon henüz yok**. Önce Qwen chat katmanını iPhone 13 üzerinde sağlamlaştırıyoruz. v2'de whisper.cpp + mikrofon eklenerek sesli giriş tamamlanacak.

## Neden resmi llama.swiftui demosunu patch ediyoruz?

Mac olmadan Windows + GitHub Actions kullanıyoruz. Workflow sabitlenmiş `llama.cpp b10883` sürümünü indirir, resmi iOS projesinin derleme altyapısını kullanır ama `ContentView`'ı bizim uygulamamızla değiştirir.

Ayrıca resmi demo üzerinde iki küçük inference düzeltmesi yapar:

1. Qwen'in `<|im_start|>` / `<|im_end|>` özel tokenlarının tokenizer tarafından special token olarak işlenmesi.
2. İlk cevaptan sonra `is_done` değişkeninin sıfırlanması. Demo bunu sıfırlamadığı için ikinci mesajda hiç token üretmeden bitebilir.

## Önerilen model

İlk hedef:

`Qwen2.5-1.5B-Instruct-Q3_K_M.gguf`

Bu model mevcut testte iPhone 13 üzerinde yüklenebildiği için v1'in ana hedefidir.

## Mevcut GitHub repo'na kurulum

Bu ZIP'in içeriğini mevcut `local-qwen-ios` repo klasörünün köküne kopyala. `.github` klasörünün de kopyalandığından emin ol.

Ardından Windows terminalinde:

```bash
git add .
git commit -m "LocalVoiceAI v1"
git push
```

Push sonrası GitHub -> **Actions** -> `Build LocalVoiceAI iOS v1` workflow'u otomatik başlar. İstersen `Run workflow` ile elle de başlatabilirsin.

## IPA

Başarılı build sonunda Actions sayfasındaki **Artifacts** bölümünden:

`LocalVoiceAI-v1-unsigned-IPA`

indir. ZIP'in içindeki `LocalVoiceAI-v1-unsigned.ipa` dosyasını Sideloadly + Remote Anisette ile kur.

## Modeli telefona koyma

File Sharing açık. Windows Apple Devices / iTunes File Sharing üzerinden GGUF'u uygulamanın Documents alanına kopyalayabilirsin. Uygulama içinde **Model -> Model listesini yenile** deyip modeli seç.

Alternatif olarak uygulamada **Model -> Dosyalardan GGUF ekle…** ile Files picker açılır.

## İlk test

Modeli yükledikten sonra sırayla şunları dene:

```text
Merhaba
```

```text
Benimle yalnızca sohbet et. Şu an nasılsın?
```

```text
Az önce sana ne sormuştum?
```

Beklenen: Model sadece assistant cevabı üretmeli; kendi kendine sahte user/assistant konuşması yazmamalı ve ikinci mesajda boş cevap vermemeli.

## Not: Eski LocalQwen ve model dosyaları

Workflow hâlâ resmi `llama.swiftui` projesinin bundle kimliğini kullanır. Aynı Apple hesabıyla Sideloadly üzerinden eski uygulamanın üstüne kurulursa iOS genellikle Documents verisini korur. Yine de GGUF'un PC'deki ana kopyasını sakla; uygulamayı **Delete App** ile silersen sandbox içindeki model de silinir.

## Sonraki sürüm (v2)

v1 chat testi geçtiğinde eklenecekler:

- whisper.cpp XCFramework
- Whisper tiny/base quantized model seçimi
- AVAudioEngine mikrofon kaydı
- 16 kHz mono PCM
- Türkçe ASR
- Whisper -> Qwen otomatik gönderme
- Qwen -> iOS TTS
- RAM koruması için Whisper/Qwen yükleme-boşaltma stratejisi
