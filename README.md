# Trợ Thủ Cờ Vua Duolingo (Duolingo Chess Assistant)

Phát triển bởi **tn2am**.

Trợ thủ gợi ý nước đi cờ vua trực tiếp (on-device) dành cho app Duolingo iOS, nhúng trực tiếp engine **Stockfish 18 NNUE** C++.
Tự động bắt FEN từ `DuolingoMultiplatformChessFen`, xác định tọa độ từ `ChessBoardView` và vẽ mũi tên gợi ý trực tiếp lên bàn cờ.

---

## 1. Cách tải file `.dylib`

Workflow GitHub Actions trong repo này tự động xuất ra trực tiếp file **`DuolingoChess.dylib`**.

* **Tải trực tiếp tại Releases:** [https://github.com/tn2am/doulingo-chess/releases](https://github.com/tn2am/doulingo-chess/releases)
* **Hoặc trong Actions:** Vào mục **Actions** -> Chọn build mới nhất -> Tải ở phần **Artifacts**.

---

## 2. Cách chích `DuolingoChess.dylib` vào file IPA Duolingo

### Cách 1: Sử dụng Sideloadly (trên máy tính Windows / Mac)
1. Mở Sideloadly, kéo file IPA Duolingo vào ô IPA.
2. Bấm vào nút **Advanced Options**.
3. Tại mục **Inject dylibs/frameworks**, bấm **`+`** và chọn file `DuolingoChess.dylib`.
4. Bấm **Start** để Sideloadly tự tiêm dylib, ký chứng chỉ và cài thẳng vào iPhone.

### Cách 2: Sử dụng Esign / Scarlet / Feather (trực tiếp trên iPhone)
1. Thêm IPA Duolingo vào ứng dụng ký (Esign/Scarlet).
2. Chọn **Signature** (Ký) -> **Add Library** -> Chọn file `DuolingoChess.dylib`.
3. Bấm ký và cài đặt.

---

## 3. Tính năng chính

* Giao diện thuần Việt 100%.
* Tự động nhận diện bàn cờ Duolingo và phân tích nước đi tốt nhất qua Stockfish 18.
* Thanh trượt chỉnh ELO từ 400 đến 3000.
* Nút chép mã FEN bàn cờ nhanh vào bộ nhớ tạm.
* Nhấn và giữ nút nổi ♟ để bật hoặc tạm dừng nhanh gợi ý.
