# Duolingo Chess Assistant (Dylib)

Dylib trợ thủ cờ vua chạy on-device cho Duolingo iOS, nhúng trực tiếp **Stockfish 18 NNUE** C++.
Tự động bắt FEN từ `DuolingoMultiplatformChessFen`, xác định tọa độ từ `ChessBoardView` và vẽ mũi tên gợi ý trực tiếp lên bàn cờ.

---

## 1. Cách lấy file `.dylib` nhanh nhất (Không cần cài đặt)

Workflow GitHub Actions trong repo này đã được cấu hình để xuất ra trực tiếp file **`DuolingoChess.dylib`**.

1. Đẩy thư mục này lên một repo GitHub cá nhân (chế độ Public hoặc Private).
2. Vào tab **Actions** -> Chọn **Build Duolingo Chess Dylib** -> Bấm **Run workflow**.
3. Sau khoảng 3–5 phút, workflow hoàn thành:
   * Bạn có thể tải ngay file **`DuolingoChess.dylib`** ở mục **Artifacts** bên dưới trang workflow.
   * Hoặc tải từ mục **Releases** của repo.

---

## 2. Cách gắn `DuolingoChess.dylib` vào IPA Duolingo

Sau khi có file `DuolingoChess.dylib`:

### Cách 1: Dùng Sideloadly (Rất đơn giản trên Windows/Mac)
1. Mở Sideloadly, kéo file IPA Duolingo vào ô IPA.
2. Bấm vào nút **Advanced Options**.
3. Tại mục **Inject dylibs/frameworks**, bấm **+** và chọn file `DuolingoChess.dylib`.
4. Bấm **Start** để Sideloadly tự tiêm dylib, ký và cài thẳng vào iPhone.

### Cách 2: Dùng Esign / Scarlet / Feather (Trực tiếp trên iPhone)
1. Nhập IPA Duolingo vào Esign/Scarlet.
2. Chọn **Signature** (Ký) -> **Add Library** -> Chọn file `DuolingoChess.dylib`.
3. Ký và cài đặt.

### Cách 3: Dùng công cụ dòng lệnh (Mac/Linux)
```bash
# Cài optool hoặc insert_dylib
optool install -c load -p "@executable_path/Frameworks/DuolingoChess.dylib" -t Payload/DuolingoMobile.app/DuolingoMobile
```

---

## 3. Cách tự build dylib trên máy Mac (Nếu có sẵn macOS & Theos)

Yêu cầu: Xcode + [Theos](https://theos.dev).

```bash
# 1. Clone Stockfish 18 & tải mạng NNUE
git clone --depth 1 --branch sf_18 https://github.com/official-stockfish/Stockfish.git sf
cd sf/src && make net && cd ../..

# 2. Biên dịch Stockfish sang iOS arm64 static library
cd sf/src
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
CXX=$(xcrun -sdk iphoneos -f clang++)
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -std=c++17 -O3 -DNDEBUG -fno-exceptions -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8 -I. -w"
for f in $(find . -name '*.cpp' ! -path './universal/*'); do
  $CXX $FLAGS -c "$f" -o "$f.o"
done
ar rcs libstockfish.a $(find . -name '*.cpp.o' ! -name 'main.cpp.o')
cd ../..

# 3. Biên dịch dylib
make FINALPACKAGE=1
# File dylib xuất ra tại: .theos/obj/Chess.dylib (hoặc trong packages/*.deb)
```
