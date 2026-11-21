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
7. **Probe 13** — SABR pha 1B (fetcher + PO token): cửa native
   DUY NHẤT còn lại cho Gold sau khi Probe 12 đóng cửa cookie. Mở
   probe là nó TỰ CHẠY: nó tái dùng danh tính OAuth của Probe 9 —
   token của Probe 9 đã mất theo các lần xoá app, nên nó sẽ tự
   chạy lại cửa device-code NGAY TRONG PROBE: khi TV hiện MÃ KÍCH
   HOẠT (chữ lớn trên nền vàng), anh mở
   https://www.google.com/device trên iPhone → nhập mã → duyệt
   bằng tài khoản Gold của anh. Duyệt xong probe tự chạy tiếp tới
   cùng, KHÔNG cần bấm gì thêm trên TV. Nó lấy /player TVHTML5
   cho tập Gold, rồi MINT PO TOKEN theo recipe TV (lấy challenge
   từ tv_config, chạy BotGuard trong WebView nhỏ ngay trên màn
   hình probe, đổi qua GenerateIT) và gắn token vào POST SABR —
   pha 1 không có token đã bị server trả 403 ngay cửa, pha 1B thử
   lại với token trong tay. Nó kiểm kê từng mảnh dữ liệu trả về:
   server có đòi attestation không, có format AVC/AAC không,
   segment thật có về không. Chỉ fetch + kiểm kê — KHÔNG phát
   hình, màn hình chỉ có chữ là đúng. Kết luận nằm ở dòng "KẾT
   QUẢ probe13b" (SABR PHA 1B: …) cuối log.
8. **Probe 14** — TVHTML5 downgraded + OAuth (bản 0.2.0): đường
   được cả hai đội nghiên cứu chấm hạng 1. **THỨ TỰ QUAN TRỌNG:
   chạy Probe 13 (bản 0.1.9) TRƯỚC và tải log 0.1.9 về gửi em
   TRƯỚC KHI xoá app để cài 0.2.0** — xoá app là log cũ mất.
   Cài 0.2.0 xong, mở Probe 14 là nó TỰ CHẠY: sandbox bị xoá
   nên token mất, nó sẽ lại hiện MÃ KÍCH HOẠT — anh duyệt lại
   một lần ở google.com/device bằng tài khoản Gold (như Probe
   13, đây là chuyện đã biết trước, không phải lỗi). Duyệt xong
   nó gọi /player cho tập Gold bằng client TVHTML5 bản 5.x
   (persona tv_samsung — client yt-dlp dùng mặc định cho tài
   khoản đã đăng nhập, không cần PO token): nếu client này trả
   format thường thay vì ép SABR như bản 7.x, trình phát native
   TỰ MỞ và phát thật — **cứ để nó phát hết ~2 phút rưỡi**
   (probe lấy mẫu vị trí mỗi 15 giây để chắc chắn link không
   chết giữa chừng kiểu ~30 giây), phát xong nó tự đóng và hiện
   kết luận. Kết luận nằm ở dòng "KẾT QUẢ probe14" cuối log.
9. **Probe 15** — giải mã sig/n cho client downgraded (bản 0.2.1):
   Probe 14 kết án client 5.x thoát SABR nhưng cả 31 format bị
   khoá chữ ký (signatureCipher) — probe này thử GIẢI khoá đó
   ngay trên TV. Mở Probe 15 là nó TỰ CHẠY: đi lại đúng đường
   Probe 14 (sandbox bị xoá nên lại hiện MÃ KÍCH HOẠT — duyệt
   một lần ở google.com/device bằng tài khoản Gold như thường),
   gọi /player, rồi lấy base.js của player, trích hai hàm
   sig/n bằng pattern kiểu yt-dlp, chạy chúng bằng
   JavaScriptCore (không qua WebView), giải URL của itag
   137/140/18, kiểm byte thật (Range GET) và phát thử bản
   muxed 18 bằng trình phát native — **cứ để nó phát hết
   ~2 phút rưỡi** như Probe 14. Màn hình chỉ có chữ cho tới
   lúc phát thử là đúng. Kết luận nằm ở dòng "KẾT QUẢ
   probe15" cuối log (SIG/N: ĐẠT / GIẢI ĐƯỢC MÀ PHÁT CHẾT /
   BYTE-CHECK BỊ TỪ CHỐI / KHÔNG TRÍCH ĐƯỢC HÀM / EVAL LỖI).
10. **Probe 16** — giải mã sig/n bằng EJS solver (bản 0.2.2):
   Probe 15 đã chết vì hai lớp — nó tìm hàm trong SAI file
   (bundle của app TV, không hề có bộ máy giải mã) và họ
   pattern regex của yt-dlp đời cũ đã bị chính yt-dlp khai
   tử ở thế hệ player hiện tại. Probe 16 đi đúng cách
   yt-dlp đang dùng: solver EJS đóng gói sẵn trong app —
   lấy player JS thật mà trang /tv nạp (tv-player-ias, có
   kiểm dấu vết trước khi dùng), cho JavaScriptCore đọc
   cây mã + chạy thử để nhận diện hai hàm sig/n theo hành
   vi, rồi giải mã như Probe 15 (byte-check 137/140 +
   phát thử muxed 18). Mở Probe 16 là nó TỰ CHẠY: lại hiện
   MÃ KÍCH HOẠT (sandbox bị xoá khi cài bản mới — duyệt
   một lần ở google.com/device bằng tài khoản Gold như
   thường), nếu phát được thì **cứ để nó phát hết ~2 phút
   rưỡi** như Probe 14/15. Màn hình chỉ có chữ cho tới lúc
   phát thử là đúng. Kết luận nằm ở dòng "KẾT QUẢ probe16"
   cuối log (EJS SIG/N: ĐẠT / SOLVER KHÔNG NẠP ĐƯỢC /
   SOLVER KHÔNG NHẬN DIỆN ĐƯỢC / SOLVER CHẠY LỖI /
   BYTE-CHECK BỊ TỪ CHỐI / GIẢI ĐƯỢC MÀ PHÁT CHẾT).
11. **Probe 17** — đường chung: Free + Super VIP (bản 0.2.3):
   Probe 16 đã chứng minh đường Gold (device-code + client
   TVHTML5 5.x + solver EJS). Anh chốt: MỘT đường duy nhất
   cho mọi tầng, bỏ trục Free riêng. Probe này kiểm hai ô
   chưa từng thử qua đường đó: tập Free (Bằng Chứng Thép II
   tập 1) và tập Super VIP (Cuộc Chiến Hoa Hồng tập 1).
   **THỨ TỰ QUAN TRỌNG: tải log bản 0.2.2 về gửi em TRƯỚC
   KHI xoá app để cài 0.2.3** — xoá app là log cũ mất.
   Cài 0.2.3 xong, mở Probe 17 là nó TỰ CHẠY: sandbox bị
   xoá nên lại hiện MÃ KÍCH HOẠT — anh duyệt MỘT lần ở
   google.com/device bằng tài khoản của anh (một lần duyệt
   chạy cho cả hai cell). Duyệt xong nó tự chạy cell A
   (Free) rồi cell B (Super VIP): mỗi cell giải mã, kiểm
   byte thật, rồi phát thử bản muxed — **cứ để nó phát hết
   ~1 phút mỗi cell**. Nếu tài khoản chưa lên Super VIP
   kịp thì cell B kết "CHƯA MỞ" kèm lý do nguyên văn của
   YouTube — đó là kết quả đọc được, không phải lỗi; khi
   nào anh lên hạng xong, chạy lại Probe 17 là cell B đi
   tiếp. Kết luận nằm ở dòng "KẾT QUẢ probe17" cuối log
   (FREE=… · SVIP=…).
12. **Probe 18** — VISIONOS + OAuth: nâng trần 480p? (bản 0.2.4):
   đường hiện tại (tv_samsung + OAuth) bị trần format THEO TỰA —
   có bộ chỉ được cấp tới 480p dù video có 1080p (FL-351). Probe
   này đo ô chưa ai thử: client VISIONOS mang danh tính OAuth
   của anh, trên đúng tựa bị cap (Nhân Chứng tập 1) + tựa đối
   chứng của Probe 16. **THỨ TỰ QUAN TRỌNG: tải log bản 0.2.3
   về gửi em TRƯỚC KHI xoá app để cài 0.2.4** — xoá app là log
   cũ mất. Cài 0.2.4 xong, mở Probe 18 là nó TỰ CHẠY: lại hiện
   MÃ KÍCH HOẠT — anh duyệt MỘT lần ở google.com/device bằng
   tài khoản của anh (một lần duyệt chạy cho mọi ô OAuth).
   Duyệt xong nó tự chạy 5 ô theo thứ tự: P18-1 baseline
   tv_samsung → P18-2 VISIONOS + đăng nhập → P18-3 VISIONOS
   ẩn danh → P18-4/P18-5 đối chứng. Ô nào trả HLS thì trình
   phát TỰ MỞ thử khung hình đầu — cứ để nó chạy vài giây, nó
   tự đóng, không cần bấm gì. Để yên tới khi dòng "KẾT QUẢ
   probe18" hiện ra (kèm nhánh kiến trúc A/B/C/D theo cây
   quyết định) rồi tải log ở màn hình chính gửi em.
13. **Probe 19** — Cuộc đua client: ai phá được trần 480p? (bản 0.2.5):
   Probe 18 đã đóng cửa VISIONOS; đợt nghiên cứu FL-351 xếp hạng lại
   các ứng viên còn đứng được, probe này đo hết trong MỘT lần chạy,
   mọi ô mang CÙNG danh tính device-code của anh (duyệt mã kích hoạt
   đúng một lần như Probe 18): P19-1 baseline tv_samsung (đối chứng
   của chính lần chạy) → P19-2 web_embedded ★ (ứng viên số 1: từng
   lấy trọn 1080p cho phim hội viên trong báo cáo yt-dlp #17049,
   nhưng bằng cookie — bearer đường TV có được chấp nhận không là
   câu hỏi chưa ai trả lời) → P19-3 tv-downgraded trần (bỏ vỏ
   Samsung) → P19-4 bản TV cổ 5.20150304 → P19-5 ba biến thể thông
   số (sts 8 số, ± supportXhr) của đường hiện tại. Mỗi ô chạy trên
   cả hai tựa (bị cap + đối chứng). **Vẫn như cũ: tải log bản trước
   về gửi em TRƯỚC KHI xoá app** — xoá app là log cũ mất. Ô nào trả
   HLS thì trình phát tự mở thử khung hình đầu vài giây rồi tự đóng.
   Để yên tới khi hai dòng "KẾT QUẢ probe19" và "KẾT LUẬN TRẦN
   480p" hiện ra rồi tải log ở màn hình chính gửi em.
14. Các probe còn lại (2, 2b, 2c, 6, 5, E-P2, E-P6, C-3, 10, E-P4, 8)
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
