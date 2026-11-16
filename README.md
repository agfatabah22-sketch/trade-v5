# Blue Hub Trade Only

Source utama untuk Blue Hub Trade Only. Konfigurasi pribadi disimpan di file loader lokal, di luar repository ini.

Engine membaca `getgenv().BlueHubConfig` sebelum mulai, memvalidasi isinya, lalu menyalinnya menjadi konfigurasi sesi. Config yang hilang atau gagal validasi struktur menghentikan proses sebelum startup game. Kecocokan nama item diperiksa setelah katalog game tersedia. Engine tidak mengirim config ke GitHub.

Gunakan file **Blue Hub - Config & Loader.lua** yang disimpan sendiri. Edit config di bagian atas file itu, lalu jalankan seluruh file lewat executor atau autoexec. Jangan upload file tersebut ke GitHub. URL source publik:

https://raw.githubusercontent.com/agfatabah22-sketch/trade-v5/main/BlueHub.lua

## Pengaturan yang didukung

| Field | Isi |
| --- | --- |
| `Username` | Username penerima, atau daftar username. Gunakan username Roblox, bukan display name. |
| `Pets` | Daftar nama pet/egg yang dipilih. |
| `Accessories` | Daftar nama aksesori. Minimal `Pets` atau `Accessories` berisi pilihan. |
| `Keep` | Nama item ke jumlah yang ingin disisakan. |
| `Excluded` | Daftar nama item yang dikecualikan. |
| `AutoStart` | Mulai otomatis; default `true`. |
| `IncludeEquipped`, `IncludePetPen` | Siapkan pet yang dipakai/berada di Pet Pen; default `true`. |
| `FastConfirm` | Konfirmasi sesuai pemeriksaan offer/stage yang ada; default `true`. |
| `BatchAddItems` | Masukkan hingga 18 item per trade; default `true`. |
| `AutoRetryTradeRequest` | Ulang permintaan yang belum dijawab; default `true`. |
| `RecipientSwitchSeconds` | Tunggu sebelum mencoba penerima berikutnya; default 3, rentang 1–300 detik. |
| `TradeRequestRetrySeconds` | Jeda sebelum meminta lagi ke username yang sama; default 15, rentang 10–300 detik. |
| `WaitForRecipientSeconds` | Batas menunggu penerima jika auto retry dimatikan; default 120 detik. |
| `FarmersV5.DisableAccount` | Nonaktifkan akun pengirim di AccountOps setelah seluruh target terverifikasi selesai; default `false`. |
| `FarmersV5.APIKey` | API key AccountOps pribadi, hanya di loader lokal. Wajib jika disable diaktifkan. |

Akun dalam daftar penerima otomatis melewati tindakan pengirim. Penerima bisa tetap dibuka manual. Permintaan yang belum dijawab dapat berganti penerima; trade yang sudah berlangsung tetap pada penerima tersebut. Status `TRANSFER COMPLETED` memerlukan hasil transfer terverifikasi, dan bila diaktifkan, konfirmasi disable AccountOps.

Ini tetap script trade-only. Tidak ada fitur beli, buka box, teleport, AutoSwap, atau HubKey pihak lain. Perubahan source tidak mengubah config lokal. Source versi `main` yang terbaru diambil saat loader dijalankan lagi; sesi yang sedang berjalan tidak diganti otomatis.

## Build

Jalankan `python build.py` dengan Python 3 untuk membangun `BlueHub.lua` dari `src/`. Builder tidak membaca `config.lua` atau file loader pribadi. Jangan menambahkan data akun, cookie, API key, atau backup instalasi ke repository.

Config tetap berada di memori executor selama sesi. Saat fitur disable aktif, API key hanya dipakai untuk request AccountOps yang dikonfigurasi dalam modulnya.
