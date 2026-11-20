# YT Probe — app thử cơ chế YouTube cho Joe TV (tvOS)

App probe độc lập (bundle `com.luun.nguyen.ytprobe`, version 0.1.0/1),
cài SONG SONG với Joe TV — không đụng gì vào Joe TV 2.0.41.
Chiến lược của anh (2026-11-20): cơ chế nào chạy được trong app này
mới được nhúng vào Joe TV.

Mọi probe đều ghi log chẩn đoán (cùng khuôn với Joe TV: server LAN
cổng 18080 + PIN một lần nằm trong địa chỉ). Địa chỉ tải log hiện
NGAY TRÊN MÀN HÌNH CHÍNH của app — mở bằng iPhone cùng Wi-Fi để tải
file `ytprobe-diag.txt`. Cookie/token KHÔNG bao giờ vào log (chỉ ghi
có/không + độ dài).

## Thứ tự chạy buổi sáng (theo độ quyết định)

0. **TRƯỚC TIÊN — xuất log Joe TV 2.0.41 hiện có** (mở Joe TV →
   Cài đặt → Gửi log chẩn đoán → tải về). Log này là bằng chứng phân
   xử câu hỏi surface-2 của bản 2.0.41; để qua buổi probe là nó bị
   phiên Joe TV mới ghi đè.
1. **Probe 1** — 4 ô lever MSE. Tự chạy ~10 giây. Chụp màn hình kết quả.
2. **Probe 3+7** — bấm "Chạy ma trận 4 client", rồi bấm phát QUEUE
   (nút 2) — trong trình phát bấm "⏭ Qua tập" một lần. Thoát ra,
   bấm phát SWAP (nút 3) — qua tập một lần nữa. Sau đó bấm các nút
   Beacon D-P1 (chỉ chạy được sau Probe 4), C-5, C-6 khi rảnh.
3. **Probe 9** — device-code: bấm 1 (cào credentials) → 2 (xin mã) →
   nhập mã ở google.com/device trên điện thoại → chờ token → 4 (gọi
   TVHTML5 tập Gold) → "Phát HLS Gold" nếu có.
4. **Probe 4** — cửa đăng nhập: để masking ON, mở cửa, đăng nhập như
   bình thường (ô email/mật khẩu native). Nếu Google bật bước passkey:
   bấm **"Dùng mật khẩu thay thế"**. Thử thêm một lần với masking OFF
   nếu muốn đối chứng (đóng app mở lại để reset cửa).
5. **Probe 11** — trang Gold sau đăng nhập (chạy sau Probe 4).
6. **Probe 12** — trích xuất Gold sau đăng nhập (chạy sau Probe 4,
   cần phiên còn sống — nếu app vừa cài lại thì chạy Probe 4 trước).
   Bấm "Chạy ma trận Gold (6 client × cookie phiên)" và để yên cho
   ma trận chạy hết: 6 client gọi /player cho tập Gold bằng cookie
   của phiên (biến thể A có SAPISIDHASH, biến thể B cookie trần chỉ
   khi A không phát được). Client nào trả HLS sẽ tự bị kiểm tra
   media thật rồi app tự mở trình phát native thử — nếu trình phát
   hiện lên thì để nó chạy ~10 giây rồi đóng. Cuối cùng app tự chạy
   cột đối chứng với tập Free. Kết luận nằm ở dòng "KẾT QUẢ
   probe12" cuối log.
7. Các probe còn lại (2, 2b, 2c, 6, 5, E-P2, E-P6, C-3, 10, E-P4, 8)
   chạy theo thời gian cho phép — mỗi probe đều tự kết luận trong log.

Sau mỗi probe (hoặc cuối buổi): tải log ở màn hình chính YT Probe và
gửi file cho em.

## Ghi chú chạy dài (chỉ khi có thời gian)

- **Oscilloscope / tín hiệu kết thúc tập (C-1/C-7)**: Probe 2 tự ghi
  mọi sự kiện điều hướng SPA ở nhịp 500 ms. Để một tập chạy HẾT tự
  nhiên trong Probe 2 là log sẽ có đủ: video tự qua tập hay app nạp,
  tín hiệu "ended" nào tới trước.
- **So sánh qua tập MSE bật/tắt (C-2)**: chạy Probe 2 tới hết tập,
  rồi chạy Probe 2b (MSE tắt) tới hết tập — log hai buổi là đủ bộ.
- **D-P4 (độ tươi resumeข้าม máy)**: xem một tập trên Sony tới vị
  trí T (ghi lại số phút), mở ngay tập đó trong Probe 2 trên tvOS —
  dòng "vị trí đầu tiên t=…s" trong log là S. So S với T.
- **E-P5 (mirror đủ chưa)**: sau Probe 4, xem tập Gold trong Probe 11
  tới ~3:00, thoát app hẳn (kill), mở lại Probe 11 — vị trí bắt đầu
  mà trang phục vụ nằm trong log.

## Build

GitHub Actions (workflow `build-ytprobe.yml`, dispatch tay) →
artifact `YTProbe-ipa-run<N>` → cài bằng Signulous như Joe TV.
