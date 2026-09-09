# LocalQwen iOS - GitHub Actions Starter

Bu repo Windows kullanarak GitHub Actions üzerindeki macOS runner'da
llama.cpp'nin resmi SwiftUI iPhone örneğini derler ve imzasız bir IPA üretir.

## Neden ilk önce bunu yapıyoruz?

Bu ilk aşamanın amacı:
1. GitHub Actions ile iPhone/arm64 derlemesinin çalıştığını doğrulamak.
2. Windows + Sideloadly ile IPA'yı iPhone'a kurabildiğini doğrulamak.
3. Qwen3-1.7B GGUF modelinin iPhone 13'te gerçekten yüklenebildiğini test etmek.

Bu demo final sesli asistan değildir. Final uygulamada doğru Qwen chat template,
Whisper mikrofon entegrasyonu ve iOS TTS eklenecektir.

## Modeli GitHub'a yükleme

Qwen GGUF dosyasını bu repoya yükleme.
Model iPhone'a sonradan Files / File Sharing üzerinden kopyalanacak.

## Build

GitHub Actions sekmesinden `Build Local Qwen iOS IPA` workflow'unu çalıştır.

Build bitince Artifacts bölümünden:
`LocalQwen-iOS-unsigned-IPA`
indir.

## Kurulum

Windows'ta Sideloadly ile IPA'yı kendi Apple ID'nle imzalayıp iPhone'a yükle.

Ücretsiz Apple developer provisioning ile uygulama 7 gün sonra yeniden
imzalanmalıdır.

## Model

Önerilen ilk test:
Qwen3-1.7B-Q4_K_M.gguf

Modeli iPhone Files uygulamasındaki LocalQwen Documents klasörüne kopyala.
Uygulama yeniden açıldığında Documents klasöründeki GGUF dosyalarını tarar.

## Not

llama.cpp'nin resmi SwiftUI örneği bir test/demo uygulamasıdır ve güncel chat
modelleri için final sohbet arayüzü değildir. İlk testte ana hedef modelin
yüklenmesi ve inference yapmasıdır.
