# Guide: Service Mesh với Istio 
---

# PHẦN I — KHÁI NIỆM NỀN TẢNG

## 1. Bối cảnh: microservices và các vấn đề phát sinh

Ứng dụng YAS là một hệ **microservices**: thay vì một khối code duy nhất (monolith),
nó được tách thành nhiều service nhỏ — `product` (danh mục sản phẩm), `cart` (giỏ
hàng), `order` (đặt hàng), `tax` (tính thuế), `search` (tìm kiếm)... Mỗi service chạy
trong pod riêng trên Kubernetes và **gọi nhau qua mạng** bằng HTTP.

Ví dụ một luồng đặt hàng:

```
storefront-ui → storefront-bff → order → tax      (tính thuế)
                                       → product  (kiểm tra sản phẩm)
                                       → customer (lấy địa chỉ)
```

Việc tách nhỏ mang lại lợi ích (deploy độc lập, scale riêng từng phần), nhưng đẻ ra
**ba nhóm vấn đề mới**, tất cả đều xoay quanh chuyện "gọi nhau qua mạng":

| Vấn đề | Câu hỏi cụ thể |
|---|---|
| **Bảo mật** | Traffic giữa các pod là HTTP **plaintext** — ai đứng trong mạng cluster đều đọc trộm được. Làm sao mã hóa? Làm sao biết bên gọi mình đúng là `order` chứ không phải một pod lạ giả danh? |
| **Kiểm soát truy cập** | Có nên cho phép *mọi* service gọi *mọi* service? Nếu một pod bị hack, kẻ tấn công gọi thẳng vào `product` được không? |
| **Độ tin cậy (resilience)** | Mạng có thể chập chờn, service có thể trả lỗi 500 thoáng qua. Ai chịu trách nhiệm retry? Timeout đặt ở đâu? |

**Cách làm cổ điển**: viết các logic này (TLS, xác thực, retry, timeout) **vào trong
code của từng service**. Nhược điểm chí mạng: 15 service × mỗi service phải tự cài
đặt lại — trùng lặp, dễ sai lệch giữa các team, đổi chính sách là phải sửa code và
deploy lại tất cả.

## 2. Service Mesh là gì?

**Service mesh** (lưới dịch vụ) là một **tầng hạ tầng riêng** đảm nhận toàn bộ việc
giao tiếp giữa các service, **tách hẳn khỏi code ứng dụng**. Ý tưởng cốt lõi:

> Đặt cạnh mỗi container ứng dụng một **proxy nhỏ** (gọi là **sidecar**). Mọi traffic
> ra/vào ứng dụng đều bị "bẻ lái" đi xuyên qua proxy này. Ứng dụng không hề hay biết.

```
   Pod "order"                            Pod "tax"
┌───────────────────┐               ┌───────────────────┐
│  ┌─────────────┐  │               │  ┌─────────────┐  │
│  │  app: order │  │               │  │  app: tax   │  │
│  └──────┬──────┘  │               │  └──────▲──────┘  │
│         │ (2)     │               │         │ (5)     │
│  ┌──────▼──────┐  │   (3) mTLS    │  ┌──────┴──────┐  │
│  │ istio-proxy │──┼───────────────┼─▶│ istio-proxy │  │
│  │   (Envoy)   │  │  mã hóa +     │  │   (Envoy)   │  │
│  └─────────────┘  │  retry +      │  └─────────────┘  │
└───────────────────┘  authz (4)    └───────────────────┘

(2) app gọi http://tax... như bình thường, plaintext, không biết gì về mesh
(3) sidecar phía gửi mã hóa mTLS, tự retry nếu lỗi
(4) sidecar phía nhận giải mã, kiểm tra "ai gọi? có được phép không?"
(5) nếu hợp lệ mới chuyển vào app
```

Vì mọi proxy đều do một trung tâm điều khiển cấu hình, ta được:

- **Mã hóa mTLS toàn bộ** traffic — không sửa một dòng code app nào.
- **Chính sách truy cập** khai báo bằng YAML, đổi lúc nào cũng được, có hiệu lực ngay.
- **Retry/timeout** cấu hình tập trung, đồng nhất.
- **Quan sát (observability)**: proxy thấy mọi request nên tự sinh metrics → vẽ được
  bản đồ topology ai-gọi-ai (Kiali).

## 3. Istio là gì? Kiến trúc của nó

**Istio** là service mesh phổ biến nhất cho Kubernetes. Kiến trúc gồm 2 tầng:

| Tầng | Thành phần | Nhiệm vụ |
|---|---|---|
| **Data plane** (tầng dữ liệu) | Các sidecar **Envoy** (container tên `istio-proxy` trong mỗi pod) | Trực tiếp truyền tải, mã hóa, chặn/cho phép, retry từng request |
| **Control plane** (tầng điều khiển) | **istiod** (1 pod trong namespace `istio-system`) | Đọc các YAML cấu hình (PeerAuthentication, AuthorizationPolicy, VirtualService...) rồi "dịch" thành config đẩy xuống từng Envoy; đồng thời làm CA cấp chứng chỉ mTLS |

**Envoy là gì?** Là một proxy tầng ứng dụng (L7) hiệu năng cao, viết bằng C++, dự án
tốt nghiệp của CNCF (cùng "nhà" với Kubernetes) — Istio không tự viết proxy mà dùng
Envoy làm sidecar. Đặc điểm quan trọng nhất: Envoy nhận **cấu hình động** từ istiod
qua giao thức xDS, nên khi ta `kubectl apply` một policy mới, istiod đẩy config xuống
và có hiệu lực **ngay lập tức, không cần restart** pod nào.

Điểm cần hiểu rõ: **istiod không nằm trên đường đi của request**. Nó chỉ phát cấu
hình. Request thực tế chỉ chạy qua các Envoy. Vì thế istiod có chết tạm thời thì
traffic vẫn chạy (chỉ không cập nhật được config mới).

**Sidecar injection** — làm sao Envoy "chui" vào pod? Ta gắn label cho namespace:

```bash
kubectl label namespace dev istio-injection=enabled
```

Từ đó, **mỗi pod mới được tạo** trong namespace này sẽ tự động bị Istio tiêm thêm
container `istio-proxy` (cơ chế mutating admission webhook của Kubernetes). Pod đang
chạy sẵn **không** tự thay đổi — phải restart để pod được tạo lại. Đó là lý do có bước
`kubectl rollout restart`. Sau khi tiêm, cột READY của pod đổi từ `1/1` thành `2/2`
(app + sidecar).

Còn việc "bẻ lái" traffic diễn ra bằng cách nào? Khi inject, Istio còn thêm một
**init-container** (`istio-init`) chạy trước tiên, cài các luật **iptables** ngay
trong network namespace của pod: mọi TCP đi ra bị redirect vào port 15001 của Envoy,
mọi TCP đi vào bị redirect qua port 15006. Vì luật nằm ở tầng kernel của pod, app
không cần (và không thể) cấu hình gì — cứ gọi `http://tax` như thường và gói tin tự
động chui qua sidecar. Đây cũng là lý do pod `hostNetwork` không inject được: nó dùng
chung network namespace với node, không có chỗ riêng để cài luật bẻ lái (sẽ gặp lại
ở Bước 4).

**Kiali** là dashboard đi kèm Istio: đọc metrics mà các Envoy báo về (qua Prometheus)
và vẽ đồ thị topology — node là service, cạnh là luồng gọi nhau, kèm biểu tượng ổ
khóa nếu cạnh đó được mã hóa mTLS.

## 4. Tại sao đồ án dùng Istio?

- Đề bài gợi ý thẳng: *"Option phổ biến: Istio (cài trên K8S) + Kiali để visualize"*.
- Istio hỗ trợ đủ 3 yêu cầu bằng 3 loại resource khai báo thuần YAML:

| Yêu cầu đề bài | Resource Istio | File trong repo |
|---|---|---|
| Enable mTLS giữa các service | `PeerAuthentication` + `DestinationRule` | `mesh-security.yaml` |
| Chỉ service được phép mới connect | `AuthorizationPolicy` | `product-authorization.yaml`, `search-authorization.yaml` |
| Lỗi 500 thì retry tự động | `VirtualService` (mục `retries`) | `tax-retry.yaml` |
| Vẽ topology | Kiali + Prometheus addon | (cài bằng manifest có sẵn của Istio) |

---

# PHẦN II — BA TRỤ CỘT: mTLS, AUTHORIZATION, RETRY

## 5. mTLS là gì và tác dụng

### 5.1. Từ TLS đến mTLS

- **TLS** (cái làm nên HTTPS): khi trình duyệt kết nối web, **server** xuất trình
  chứng chỉ để chứng minh danh tính, và kênh truyền được **mã hóa**. Client thì
  không cần chứng minh gì (server không biết bạn là ai — đăng nhập là chuyện của
  tầng ứng dụng).
- **mTLS** (mutual TLS — TLS **hai chiều**): **cả hai phía** đều phải xuất trình
  chứng chỉ. Kết quả:
  1. **Mã hóa**: nội dung truyền đi không thể bị đọc trộm/sửa đổi.
  2. **Xác thực hai chiều**: `tax` biết chắc bên gọi là `order` (không phải pod giả
     danh); `order` biết chắc nó đang nói chuyện với `tax` thật.

### 5.2. Istio làm mTLS "miễn phí" như thế nào

Bình thường muốn có mTLS phải tự tạo CA, phát hành chứng chỉ cho từng service, cấu
hình app đọc chứng chỉ, lo gia hạn... rất cực. Istio tự động hóa toàn bộ:

1. **istiod đóng vai trò CA** (Certificate Authority — nơi ký phát chứng chỉ).
2. Mỗi sidecar khi khởi động sẽ xin istiod một chứng chỉ. Danh tính ghi trong chứng
   chỉ **không phải IP** (IP pod thay đổi liên tục) mà là **service account** của pod,
   theo chuẩn **SPIFFE**:

   ```
   spiffe://cluster.local/ns/dev/sa/order
                          │      │  └── service account tên "order"
                          │      └───── trong namespace "dev"
                          └──────────── cluster tên "cluster.local"
   ```

   Trong repo này, Helm chart của mỗi service tạo một service account trùng tên
   service (`cart`, `order`, `tax`...), nên **danh tính mTLS = tên service**.
3. Chứng chỉ **tự xoay vòng** (mặc định hết hạn sau ~24h, sidecar tự xin cái mới).
4. Khi `order` gọi `tax`: sidecar của `order` và sidecar của `tax` bắt tay mTLS với
   nhau. **Hai app container hoàn toàn không biết** — chúng vẫn nói HTTP thường với
   sidecar cùng pod (đi qua localhost, không ra mạng).

### 5.3. Hai nửa của cấu hình mTLS

mTLS có 2 đầu, nên cần 2 resource:

| Resource | Điều khiển | Câu nói tương ứng |
|---|---|---|
| **PeerAuthentication** | Phía **NHẬN** (server) | "Tôi **chỉ chấp nhận** kết nối có mTLS" |
| **DestinationRule** | Phía **GỬI** (client) | "Khi gọi đi, tôi **chủ động dùng** mTLS" |

Ba chế độ của PeerAuthentication:

- `DISABLE` — không mTLS.
- `PERMISSIVE` (mặc định) — chấp nhận **cả hai**: mTLS lẫn plaintext. Dùng trong giai
  đoạn chuyển tiếp, hoặc khi có client bất khả kháng không vào mesh được (xem mục 11).
- `STRICT` — **chỉ** chấp nhận mTLS. Kết nối plaintext bị **reset thẳng tay** ở tầng
  TCP (client thấy "Connection reset by peer"). Đây là mode đồ án dùng để chứng minh.

## 6. Authorization Policy — "ai được gọi ai"

mTLS trả lời câu hỏi *"bạn là ai?"* (authentication — xác thực). Nhưng biết là ai rồi
thì *"bạn có được phép không?"* (authorization — trao quyền) là tầng tiếp theo.

`AuthorizationPolicy` của Istio là **luật lọc request** cài trên sidecar của service
**đích**, giống một "bảo vệ cổng":

- **selector** — luật này gắn lên pod nào (chọn theo label).
- **action: ALLOW + rules** — danh sách trường hợp được cho qua. Điểm cực kỳ quan
  trọng: **một khi pod có ít nhất 1 policy ALLOW, mọi request không khớp luật nào sẽ
  bị TỪ CHỐI mặc định** (deny-by-default). Không cần viết luật "cấm".
- **principals** — danh tính bên gọi, chính là **SPIFFE identity lấy từ chứng chỉ
  mTLS** (mục 5.2). Đây là chỗ hai khái niệm móc vào nhau: *không có mTLS thì không có
  danh tính đáng tin để mà trao quyền*. Kẻ giả mạo không thể "khai man" tên service
  vì danh tính nằm trong chứng chỉ do istiod ký, không phải trong header tự đặt.

Request bị chặn sẽ nhận `HTTP 403` với body `RBAC: access denied` — do **Envoy** trả
về, request **chưa hề chạm tới app**.

**Cách xác định allow-list trong đồ án** (tư duy quan trọng khi tự làm): đọc code/kiến
trúc xem **thực tế ai gọi ai**, liệt kê đúng những caller đó, không thừa không thiếu:

- Ai gọi `product`? → `cart` (validate giỏ), `order` (checkout), `inventory` và
  `search` (đồng bộ dữ liệu — có code gọi thẳng product API),
  2 BFF (`storefront-bff`, `backoffice-bff`), và `ingress-nginx` (đường API từ ngoài).
- Ai gọi `search`? → 2 BFF, `product` (đẩy dữ liệu index), `ingress-nginx`.

Quên một caller thật → chức năng đó âm thầm hỏng với lỗi RBAC deny (ví dụ quên
`search` thì đồng bộ Elasticsearch chết). Đây là loại lỗi khó lần ra nếu không hiểu
kiến trúc, nên trong 2 file YAML đều có comment ghi rõ lý do từng principal.

**Phân biệt với RequestAuthentication** (đề bài có nhắc *"AuthorizationPolicy /
RequestAuthentication"*): đây là hai tầng xác thực khác nhau.
`PeerAuthentication` xác thực **service** gọi đến (danh tính lấy từ chứng chỉ mTLS —
trả lời "workload nào đang gọi?"), còn `RequestAuthentication` xác thực **người dùng
cuối** đứng sau request (kiểm tra JWT token, ví dụ token do Keycloak phát — trả lời
"user nào đang thao tác?"). Yêu cầu đồ án là giới hạn **service-to-service**, nên
PeerAuthentication + `principals` là đủ; RequestAuthentication là bước mở rộng nếu
muốn viết luật theo user/role (khi đó AuthorizationPolicy dùng thêm trường
`request.auth.claims` thay vì chỉ `principals`).

## 7. Retry Policy — tự động thử lại khi lỗi

Trong hệ phân tán, nhiều lỗi có tính **thoáng qua** (transient): pod đang restart,
nghẽn mạng 1 giây, GC pause... Yêu cầu đề bài: *"nếu service trả lỗi 500 thì retry
tự động"*.

Istio cấu hình retry bằng **VirtualService** — resource định nghĩa "luật định tuyến"
cho traffic đến một host. Trong mục `http` có thể khai `retries`:

- `attempts` — số lần thử lại tối đa.
- `perTryTimeout` — mỗi lần thử được chờ tối đa bao lâu.
- `retryOn` — những loại lỗi nào thì mới retry (`5xx`, `reset`, `connect-failure`...).

Retry do **sidecar phía gửi** thực hiện: app `order` gửi 1 request, nếu `tax` trả
500 thì Envoy của *bên gọi* lặng lẽ gửi lại, tối đa `attempts` lần; app chỉ nhận về
**một** kết quả cuối cùng. App không cần biết retry tồn tại.

⚠️ Lưu ý khi thiết kế: chỉ nên retry với **request an toàn khi lặp lại** (idempotent
— gọi 2 lần cho cùng kết quả, như GET). Retry một lệnh "trừ tiền" có thể trừ 2 lần.
Đồ án chọn demo trên `tax` (tính thuế — đọc, tính toán, không ghi) là vì vậy.

---

# PHẦN III — GIẢI THÍCH TỪNG FILE YAML

## 8. `mesh-security.yaml` — bật mTLS

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: dev-mtls-strict
  namespace: dev          # (1)
spec:
  mtls:
    mode: STRICT          # (2)
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: dev-default-mtls
  namespace: dev
spec:
  host: "*.dev.svc.cluster.local"   # (3)
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL            # (4)
```

- **(1)** PeerAuthentication đặt trong namespace `dev` và **không có `selector`**
  → áp dụng cho **mọi pod trong namespace** (namespace-wide). Muốn áp cho riêng một
  service thì thêm selector, nhưng đồ án muốn phủ toàn bộ YAS.
- **(2)** `STRICT`: mọi pod trong `dev` **từ chối mọi kết nối không mTLS** (phía nhận).
- **(3)** DestinationRule khớp host dạng wildcard — mọi service `*.dev.svc.cluster.local`.
- **(4)** `ISTIO_MUTUAL`: khi bất kỳ sidecar nào gọi **đến** các host trên, nó dùng
  mTLS với chứng chỉ do Istio tự quản lý (phía gửi). Phân biệt với mode `MUTUAL` là
  loại phải tự cung cấp file chứng chỉ.

Ghi chú trong file (đã gặp thật khi làm): PeerAuthentication namespace-wide **không
được phép** khai `portLevelMtls` (istiod từ chối manifest). May mắn là không cần:
health probe của kubelet vẫn hoạt động vì Istio tự ghi đè đường probe sang port
15020 của sidecar; Kiali lấy telemetry từ port 15090 của Envoy — cả hai không đi
qua cổng ứng dụng nên không đụng STRICT.

## 9. `product-authorization.yaml` — allow-list cho product

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: product-allow-selected-services
  namespace: dev
spec:
  selector:                              # (1) gắn luật lên pod product
    matchLabels:
      app.kubernetes.io/name: product
      app.kubernetes.io/instance: product
  action: ALLOW
  rules:
    - from:
        - source:
            principals:                  # (2) danh tính SPIFFE được phép
              - cluster.local/ns/dev/sa/cart
              - cluster.local/ns/dev/sa/order
              - cluster.local/ns/dev/sa/inventory      # (3)
              - cluster.local/ns/dev/sa/search         # (3)
              - cluster.local/ns/dev/sa/storefront-bff
              - cluster.local/ns/dev/sa/backoffice-bff
              - cluster.local/ns/ingress-nginx/sa/ingress-nginx  # (4)
      to:
        - operation:
            ports: ["80"]                # (5) luật trên chỉ áp cho port 80
    - to:
        - operation:
            ports: ["8090"]              # (6) port 8090: mở cho mọi nguồn
```

- **(1)** `selector` chọn đúng pod product qua label chuẩn của Helm chart.
- **(2)** Mỗi principal ứng với một service account — xem mục 6. Pod nào dùng SA
  khác (kể cả SA `default` của chính namespace `dev`) đều bị deny.
- **(3)** Hai SA dễ bị bỏ sót: code `inventory` và `search` gọi thẳng product API;
  thiếu chúng thì đồng bộ Elasticsearch/inventory âm thầm hỏng.
- **(4)** Cho ingress được gọi để đường `api.dev.local.com/product` (trình duyệt →
  ingress → product) hoạt động. Lưu ý thực tế của cluster này: ingress-nginx chạy
  `hostNetwork` nên **không có sidecar → không có danh tính** → dòng này không có
  tác dụng (xem mục 11) — để lại cũng vô hại.
- **(5)** Rule thứ nhất giới hạn theo port 80 — cổng API chính.
- **(6)** Rule thứ hai: port 8090 (actuator/metrics — health check, Prometheus scrape)
  cho phép **mọi** nguồn (rule không có `from` = không ràng buộc nguồn). Nếu khóa nốt
  8090 thì Prometheus không cào được metrics.

`search-authorization.yaml` **giống hệt cấu trúc**, chỉ khác selector (search) và
allow-list ngắn hơn: `storefront-bff`, `backoffice-bff`, `product`, `ingress-nginx`.

## 10. `tax-retry.yaml` — retry cho tax

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: tax-retry
  namespace: dev
spec:
  hosts:
    - tax                          # (1) tên ngắn
    - tax.dev.svc.cluster.local    #     và tên đầy đủ
  gateways:
    - mesh                         # (2) áp cho traffic nội bộ mesh
  http:
    - name: tax-http-retry
      timeout: 10s                 # (3) tổng thời gian tối đa
      retries:
        attempts: 3                # (4) tối đa 3 lần thử lại
        perTryTimeout: 2s          # (5) mỗi lần chờ tối đa 2s
        retryOn: 5xx,reset,connect-failure,refused-stream,gateway-error  # (6)
      route:
        - destination:
            host: tax.dev.svc.cluster.local
            port:
              number: 80
```

- **(1)** Khai cả 2 dạng tên để khớp dù caller gọi `http://tax` hay tên đầy đủ.
- **(2)** `mesh` = gateway ảo đại diện cho toàn bộ sidecar nội bộ (phân biệt với
  ingress gateway).
- **(3)(4)(5)** Phép tính cần nhớ: tổng thời gian xấu nhất = (1 lần gốc + 3 retry) ×
  2s = **8s**, nên `timeout` tổng phải ≥ 8s → chọn 10s. Nếu để 5s, các lần retry
  cuối bị cắt trước khi kịp chạy (sai số này đã được ghi chú ngay trong file).
- **(6)** `5xx` — đáp ứng đúng yêu cầu đề bài "trả lỗi 500 thì retry"; thêm các lỗi
  tầng kết nối (reset, connect-failure...) để phủ trường hợp pod chết/chưa lên.

Vì sao chọn `tax`: code `order` có dependency thật tới `tax` (flow checkout
`order → tax`), và API tính thuế mang tính đọc/tính toán, retry an toàn (mục 7).

---

# PHẦN IV — THỰC HÀNH TỪNG BƯỚC

## Bước 0 — Kết nối tới cluster

Mọi lệnh (`kubectl`, `istioctl`) đều là client gọi tới API server của master, nên có
thể chạy từ bất kỳ máy nào có kubeconfig admin. Copy kubeconfig từ master về:

```bash
mkdir -p ~/.kube
scp <user>@<master-tailscale-ip>:/home/<user>/.kube/config ~/.kube/config
```

Hai điểm hay vướng:

1. **Địa chỉ API server**: cluster nối các node qua Tailscale nên `server:` trong
   kubeconfig phải là IP Tailscale (`100.x.x.x`), không phải IP LAN:
   ```bash
   grep server: ~/.kube/config
   # nếu sai: sed -i 's|server: https://.*:6443|server: https://<master-tailscale-ip>:6443|' ~/.kube/config
   ```
2. **Lỗi x509** khi đổi sang IP Tailscale (cert của kubeadm không có SAN cho IP đó):
   fix nhanh cho đồ án — xóa dòng `certificate-authority-data`, thêm
   `insecure-skip-tls-verify: true` trong entry cluster.

Kiểm tra:

```bash
kubectl get nodes -o wide     # thấy các node, STATUS Ready
kubectl get pods -n dev       # các service YAS đang chạy 1/1
```

## Bước 1 — Cài Istio, Kiali, Prometheus

```bash
curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH="$PWD/bin:$PATH"

istioctl install --set profile=demo -y
kubectl apply -f samples/addons/kiali.yaml
kubectl apply -f samples/addons/prometheus.yaml     # (*)
kubectl rollout status deployment/kiali -n istio-system
```

Xác nhận:

```bash
kubectl get pods -n istio-system    # istiod, istio-ingressgateway, kiali, prometheus: Running
istioctl version                    # client/control plane/data plane cùng version
```

**(*) Bài học thực tế:** nhóm từng bỏ sót Prometheus addon → Kiali báo *"Prometheus
Unreachable"* và **Traffic Graph trống trơn** (Kiali cần Prometheus để lấy metrics vẽ
cạnh). Nếu lỡ thiếu, cài bổ sung theo đúng version Istio:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.30/samples/addons/prometheus.yaml
```

## Bước 2 — Seed data TRƯỚC khi bật policy

`sampledata` là service bơm dữ liệu mẫu (sản phẩm iPhone...) bằng cách **gọi API các
service khác**. Phải seed **trước** khi apply AuthorizationPolicy vì SA `sampledata`
không nằm trong allow-list của `product` — bật policy rồi mới seed sẽ bị RBAC deny.

Điểm không hiển nhiên (phát hiện khi làm): `sampledata` **không tự seed lúc khởi
động** — nó là REST service chờ được **trigger**:

```bash
# Trigger seed
kubectl run curl-seed -n dev --rm -it --restart=Never --image=curlimages/curl:8.8.0 -- \
  curl -X POST -H "Content-Type: application/json" -d '{}' \
  http://sampledata.dev:80/sampledata/storefront/sampledata
# → {"message":"Insert Sample Data successfully!"}

# Xác nhận có data
kubectl run curl-check -n dev --rm -it --restart=Never --image=curlimages/curl:8.8.0 -- \
  curl -s "http://product.dev:80/product/storefront/products?page=0&size=1"
# → totalElements > 0

# Xong thì tắt đi
kubectl scale deployment/sampledata -n dev --replicas=0
```

## Bước 3 — Bật sidecar injection cho namespace `dev`

```bash
kubectl label namespace dev istio-injection=enabled --overwrite
kubectl rollout restart deployment -n dev
```

Chờ rồi kiểm tra — **mỗi pod phải là `2/2`** và danh sách container có `istio-proxy`:

```bash
kubectl get pods -n dev
kubectl get pods -n dev -o jsonpath='{range .items[*]}{.metadata.name}{" containers="}{.spec.containers[*].name}{"\n"}{end}'
```

**Sự cố thực tế — "cơn bão restart":** lệnh trên restart ~15 deployment **cùng lúc**.
Nếu pod dồn trên ít node (cluster nhóm lúc đó chỉ còn 1 worker khỏe), giai đoạn
chuyển tiếp sẽ có **gấp đôi số pod** (Deployment mặc định giữ pod cũ đến khi pod mới
Ready) + mỗi pod thêm 1 Envoy → hàng chục JVM khởi động đồng thời → CPU nghẽn →
health probe (timeout 1s) fail → kubelet giết pod → restart → càng nghẽn.

Cách đọc tình huống: `kubectl get events -n dev` thấy hàng loạt
`Liveness/Readiness probe failed: context deadline exceeded` trên **nhiều service
cùng lúc** (kể cả pod cũ đang khỏe) = nghẽn tài nguyên node, **không phải lỗi cấu hình
Istio**. Kiểm tra `kubectl describe node <node> | grep -A10 "Allocated resources"`:
nếu Requests còn dưới 100% thì steady-state vẫn đủ chỗ — kiên nhẫn đợi 3–5 phút cụm
tự hội tụ về `2/2`; RESTARTS có tăng vài lần rồi đứng lại là ổn. Nếu kẹt lâu, tạm
scale bớt các service không thiết yếu (UI, rating...) rồi bật lại sau.

## Bước 4 — Xử lý ingress-nginx (điểm rẽ nhánh quan trọng)

Web bên ngoài đi vào theo đường: trình duyệt → `ingress-nginx` → service `dev`. Khi
`dev` bật STRICT, ingress **không có sidecar** sẽ gửi plaintext và bị từ chối → web
chết (HTTP 502). Có 2 tình huống:

- **Ingress controller là Deployment bình thường** → inject sidecar cho nó:
  ```bash
  kubectl label namespace ingress-nginx istio-injection=enabled --overwrite
  kubectl rollout restart deployment -n ingress-nginx   # (hoặc daemonset)
  kubectl get pods -n ingress-nginx                     # phải 2/2
  ```
- **Ingress controller chạy `hostNetwork: true`** (trường hợp cluster của nhóm —
  kiểm tra bằng `kubectl get pod -n ingress-nginx -o jsonpath='{.items[0].spec.hostNetwork}'`)
  → **không thể inject** (pod dùng network của node, không có network namespace
  riêng để chèn Envoy). Chấp nhận: dưới STRICT, đường web qua ingress sẽ 502.

**Điều này KHÔNG ảnh hưởng yêu cầu đồ án**, vì toàn bộ deliverable service mesh là
traffic **service-to-service bên trong** cluster, test bằng pod-to-pod curl (đúng
nguyên văn đề bài: *"vào pod khác trong cluster, thực hiện curl tới service"*).
Đường ingress là traffic bắc-nam, không nằm trong tiêu chí chấm. Cách vận hành web
song song với mesh: xem mục 11.

**Ghi chú mở rộng — giải pháp "chuẩn mesh" cho bài toán này:** hướng dài hạn là thay
ingress-nginx bằng **Istio Ingress Gateway** (thực tế đã được cài sẵn theo profile
demo — pod `istio-ingressgateway` trong `istio-system`). Nó là một Envoy chạy độc
lập ở rìa mesh, có danh tính và chứng chỉ như mọi sidecar, nên nói mTLS với backend
một cách tự nhiên — không dính giới hạn hostNetwork. Đồ án không chuyển vì phải viết
lại toàn bộ routing (Gateway + VirtualService thay cho các resource Ingress hiện có)
trong khi đường ingress không thuộc tiêu chí chấm; nhưng nếu được hỏi "làm sao cho
web sống dưới STRICT một cách đúng đắn" thì đây là câu trả lời.

## Bước 5 — Apply 4 manifest

```bash
kubectl apply -f k8s/istio/mesh-security.yaml
kubectl apply -f k8s/istio/tax-retry.yaml
kubectl apply -f k8s/istio/product-authorization.yaml
kubectl apply -f k8s/istio/search-authorization.yaml

kubectl get peerauthentication,destinationrule,virtualservice,authorizationpolicy -n dev
```

Kỳ vọng thấy: PeerAuthentication `STRICT`, DestinationRule host
`*.dev.svc.cluster.local`, VirtualService `tax-retry`, 2 AuthorizationPolicy `ALLOW`.

## Bước 6 — Test mTLS (bằng chứng số 1)

**Ý tưởng:** tạo pod ở namespace `default` — namespace này **không** bật injection
nên pod **không có sidecar, không có chứng chỉ** — rồi curl vào `product`:

```bash
kubectl run plain-client -n default --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl wait -n default --for=condition=Ready pod/plain-client --timeout=120s
kubectl exec -n default plain-client -- curl -v --max-time 5 http://product.dev/product/actuator/health
```

**Kết quả thật đã thu được:**

```
* Connected to product.dev (10.109.27.244) port 80
> GET /product/actuator/health HTTP/1.1
* Recv failure: Connection reset by peer
curl: (56) Recv failure: Connection reset by peer
command terminated with exit code 56
```

**Đọc kết quả:** TCP connect thành công (nên không phải lỗi mạng), nhưng vừa gửi HTTP
request thì bị **reset** — Envoy phía `product` đòi TLS handshake, client chỉ nói HTTP
thường → cắt. `exit code 56` chính là "chữ ký" của STRICT mTLS chặn plaintext.

## Bước 7 — Test Authorization (bằng chứng số 2)

**Ca 1 — BỊ CHẶN.** Pod trong `dev` (có sidecar → qua được cửa mTLS) nhưng dùng SA
`default` (không có trong allow-list):

```bash
kubectl run curl-denied -n dev --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl wait -n dev --for=condition=Ready pod/curl-denied --timeout=120s
kubectl exec -n dev curl-denied -- curl -v --max-time 5 http://product.dev:80/product/actuator/health
```

Kết quả thật:

```
< HTTP/1.1 403 Forbidden
< server: envoy
RBAC: access denied
```

`server: envoy` + `RBAC: access denied` = bị chặn ở tầng AuthorizationPolicy, request
**chưa chạm tới app**.

**Ca 2 — ĐƯỢC PHÉP.** Pod "đóng vai" service `cart` bằng cách chạy với service
account `cart` (mọi pod dùng SA nào sẽ mang danh tính SPIFFE của SA đó):

```bash
kubectl run curl-allowed -n dev --image=curlimages/curl:8.8.0 --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- sleep 3600
kubectl wait -n dev --for=condition=Ready pod/curl-allowed --timeout=120s
kubectl exec -n dev curl-allowed -- curl -v --max-time 5 http://product.dev:80/product/actuator/health
```

Kết quả thật:

```
< HTTP/1.1 500 Internal Server Error
{"statusCode":"500 INTERNAL_SERVER_ERROR","detail":"No static resource actuator/health ..."}
```

**Đừng hiểu nhầm cái 500 này là fail!** Điểm mấu chốt: **không có** `RBAC: access
denied`, và response là **JSON lỗi của chính app product** (format ApiExceptionHandler
của YAS) → request **đã đi xuyên qua Istio và chạm tới app**. 500 chỉ vì đường dẫn
actuator không tồn tại trên port 80 (actuator nằm ở port 8090) — lỗi của app, không
liên quan mesh. Muốn cặp bằng chứng "đẹp" 200-vs-403 thì gọi endpoint thật:

```bash
kubectl exec -n dev curl-allowed -- curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://product.dev:80/product/storefront/products?page=0&size=1"   # → HTTP 200
kubectl exec -n dev curl-denied  -- curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://product.dev:80/product/storefront/products?page=0&size=1"   # → HTTP 403
```

## Bước 8 — Test Retry (bằng chứng số 3)

**Bằng chứng tĩnh** — retry policy đã được istiod đẩy xuống Envoy của bên gọi:

```bash
istioctl proxy-config routes deploy/order -n dev --name 80 -o json | grep -A20 -i retryPolicy
```

Trong output tìm block gắn với `virtual-service/tax-retry`:

```json
"retryPolicy": {
    "retryOn": "5xx,reset,connect-failure,refused-stream,gateway-error",
    "numRetries": 3,
    "perTryTimeout": "2s"
}
```

⚠️ Chú ý phân biệt: các route **khác** cũng có `retryPolicy` nhưng `numRetries: 2` —
đó là **retry mặc định** Istio tự gắn cho mọi service. Chỉ block có `numRetries: 3`
+ `perTryTimeout: 2s` + metadata trỏ `virtual-service/tax-retry` là của mình.

**Bằng chứng động** — chứng minh retry thật sự chạy. Hai cách trong README/test-plan
gặp trở ngại thực tế: (a) đọc counter `upstream_rq_retry` qua `pilot-agent request
GET stats` — không thấy, vì Istio mặc định **lọc bớt stats** Envoy, counter theo
từng outbound cluster không được expose; (b) `kubectl exec` vào container `order` để
curl — image của app **không có curl**. Cách thay thế đã dùng — **đếm số request mà
app `tax` thực nhận** cho đúng 1 lần client gọi:

```bash
TAX_POD=$(kubectl get pod -n dev -l app.kubernetes.io/name=tax -o jsonpath='{.items[0].metadata.name}')
BEFORE=$(kubectl logs -n dev "$TAX_POD" -c tax | grep -c "Error: URI: /actuator/health")

# đúng MỘT request từ client; endpoint này trả 500 (khớp retryOn: 5xx)
kubectl exec -n dev curl-allowed -- curl -s -o /dev/null -w "client thấy HTTP %{http_code}\n" \
  --max-time 10 http://tax.dev:80/tax/actuator/health

AFTER=$(kubectl logs -n dev "$TAX_POD" -c tax | grep -c "Error: URI: /actuator/health")
echo "tax nhận $((AFTER-BEFORE)) log entry cho 1 lần client gọi"
```

Kết quả thật: **8 log entry** cho 1 client call. App Spring Boot log mỗi request lỗi
thành 2 dòng, vậy `8 ÷ 2 = 4 request thật = 1 lần gốc + 3 retry` — khớp chính xác
`attempts: 3`. Bằng chứng phụ: header `x-envoy-upstream-service-time: 242` (ms) —
gấp ~20 lần request bình thường (~12ms) vì Envoy đã âm thầm thử 4 lần trước khi trả
kết quả cuối về client.

## Bước 9 — Kiali topology (bằng chứng số 4)

```bash
# Sinh traffic để đồ thị có cạnh (Kiali chỉ vẽ những gì CÓ traffic gần đây)
for i in $(seq 1 30); do
  kubectl exec -n dev curl-allowed -- curl -s -o /dev/null --max-time 3 "http://product.dev:80/product/storefront/products?page=0&size=2"
  kubectl exec -n dev curl-allowed -- curl -s -o /dev/null --max-time 3 "http://tax.dev:80/tax/actuator/health"
done

# Mở Kiali — port-forward mở ra ngoài để xem từ máy có trình duyệt (qua Tailscale)
kubectl port-forward -n istio-system svc/kiali 20001:20001 --address 0.0.0.0
# → http://<tailscale-ip-máy-chạy-lệnh>:20001/kiali
```

Trong Kiali: **Traffic Graph** (không phải trang "Mesh" — trang đó chỉ hiện hạ tầng
control plane) → chọn namespace `dev` → Display bật `Traffic`, `Security`,
`Service Nodes` → chụp màn hình.

Cách đọc đồ thị để giải thích trong báo cáo:

- Node vuông = service; node tam giác = workload (app); badge version `latest`.
- **Cạnh có icon ổ khóa 🔒 = traffic được mã hóa mTLS** — trọng tâm cần chụp.
- Cạnh tới `postgresql`/`kafka` **không có khóa** — đúng, vì các namespace hạ tầng
  không thuộc mesh; điều này thể hiện quyết định phạm vi có chủ đích (chỉ mesh hóa
  app YAS, không ép mTLS lên database/message broker).
- `PassthroughCluster` = traffic đi ra đích ngoài phạm vi Istio quản lý.

## Bước 10 — Dọn dẹp pod test

```bash
kubectl delete pod curl-denied curl-allowed -n dev --ignore-not-found
kubectl delete pod plain-client -n default --ignore-not-found
```

## Bước 11 — Gỡ mesh (rollback) khi cần

Nếu muốn đưa hệ thống về trạng thái trước khi có mesh (ví dụ mesh gây trục trặc ngay
trước buổi demo phần khác), làm theo **đúng thứ tự** sau:

```bash
# 1. Xóa 4 manifest (policy/mTLS/retry) TRƯỚC
kubectl delete -f k8s/istio/product-authorization.yaml
kubectl delete -f k8s/istio/search-authorization.yaml
kubectl delete -f k8s/istio/tax-retry.yaml
kubectl delete -f k8s/istio/mesh-security.yaml

# 2. Gỡ label injection rồi restart để pod quay về 1/1 (không còn sidecar)
kubectl label namespace dev istio-injection-
kubectl rollout restart deployment -n dev

# 3. (Tùy chọn) Gỡ hẳn Istio khỏi cluster
istioctl uninstall --purge -y
kubectl delete namespace istio-system
```

Vì sao thứ tự này an toàn: sau khi xóa STRICT (bước 1), Istio quay về mặc định
PERMISSIVE + auto-mTLS — sidecar-với-sidecar vẫn mTLS, còn plaintext cũng được chấp
nhận. Nhờ đó trong giai đoạn chuyển tiếp của bước 2 (pod mới không sidecar tồn tại
song song với pod cũ còn sidecar), hai loại pod vẫn gọi nhau bình thường. Nếu làm
ngược (gỡ sidecar trong khi STRICT còn hiệu lực), pod không sidecar sẽ bị các pod
còn STRICT từ chối → lỗi loang trong lúc rollout. Đường web qua ingress cũng tự
sống lại ngay sau bước 1 (hết STRICT là hết 502).

⚠️ Bước 2 restart đồng loạt toàn namespace — sẽ gặp lại "cơn bão khởi động" như đã
mô tả ở Bước 3; trên cluster ít node hãy chờ vài phút cho cụm hội tụ.

---

# PHẦN V — VẬN HÀNH & CÂU HỎI THƯỜNG GẶP

## 11. STRICT vs PERMISSIVE — mesh và web chung sống

Sau khi hoàn tất bằng chứng STRICT, web qua ingress vẫn 502 (mục Bước 4, do ingress
hostNetwork không vào mesh được). Nếu cần web chạy lại bình thường (dev/demo UI):

```bash
# Nới sang PERMISSIVE: vẫn mTLS giữa các sidecar, nhưng CHẤP NHẬN THÊM plaintext
kubectl patch peerauthentication dev-mtls-strict -n dev --type merge \
  -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'
```

Rồi trên máy có trình duyệt (nằm trong Tailnet), thêm file hosts trỏ các hostname về
IP node chạy ingress:

```
<ip-node-worker>  storefront.dev.local.com backoffice.dev.local.com api.dev.local.com identity.dev.local.com
```

→ mở `http://storefront.dev.local.com`. (Cần đủ cả 4 hostname vì trình duyệt còn tự
gọi `api...` và redirect đăng nhập qua `identity...`.)

Quay lại STRICT khi cần demo bảo mật:

```bash
kubectl patch peerauthentication dev-mtls-strict -n dev --type merge \
  -p '{"spec":{"mtls":{"mode":"STRICT"}}}'
```

⚠️ Dưới PERMISSIVE, test "plaintext bị reset (exit 56)" **không tái hiện được** —
phải chụp/lưu bằng chứng STRICT trước khi nới.

## 12. Bảng tra cứu lỗi thường gặp (troubleshooting)

Tổng hợp các lỗi đã gặp thật trong quá trình làm đồ án — tra theo triệu chứng:

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `x509: certificate is valid for ...` khi chạy kubectl | kubeconfig trỏ IP Tailscale nhưng cert API server (kubeadm sinh) không có SAN cho IP đó | Xóa `certificate-authority-data` trong kubeconfig, thêm `insecure-skip-tls-verify: true` (Bước 0) |
| Pod kẹt `1/2`, RESTARTS tăng hàng loạt sau `rollout restart` | "Bão khởi động": hàng chục JVM + Envoy start cùng lúc trên ít node → CPU nghẽn → probe fail → restart lặp | Đợi 3–5 phút cụm tự hội tụ; nếu kẹt lâu, scale bớt service phụ (UI, rating...) rồi bật lại (Bước 3) |
| `curl exit 56` giữa hai service **hợp lệ** | Caller chưa có sidecar: namespace chưa label injection, hoặc pod chưa restart sau khi label | Kiểm tra pod caller phải `2/2`; label + `rollout restart` namespace của caller |
| `RBAC: access denied` với service **đáng lẽ được phép** | Thiếu service account của caller thật trong allow-list (dễ sót các caller "ngầm" như `inventory`, `search` gọi product) | Thêm principal `cluster.local/ns/<ns>/sa/<sa>` vào file authorization tương ứng rồi apply lại |
| HTTP 502 khi vào web qua ingress | ingress-nginx không có sidecar (hostNetwork) gửi plaintext, bị STRICT từ chối | Chuyển PERMISSIVE (mục 11) hoặc port-forward thẳng service; hướng chuẩn: Istio Gateway (Bước 4) |
| Kiali Traffic Graph trống / "Prometheus Unreachable" | Thiếu Prometheus addon — Kiali không có nguồn metrics để vẽ cạnh | Cài addon đúng version Istio (Bước 1); nhớ sinh traffic vì chỉ luồng có traffic gần đây mới hiện |
| Seed sampledata bị `RBAC: access denied` | Apply AuthorizationPolicy trước khi seed — SA `sampledata` không nằm trong allow-list | Xóa tạm 2 policy authorization → seed → apply lại (đúng thứ tự là seed trước, Bước 2) |
| `kubectl exec ... curl` báo `curl: executable file not found` | Image của app (Java slim) không có curl | Dùng pod riêng từ image `curlimages/curl` với `serviceAccountName` phù hợp (Bước 7) |

## 13. Q&A 
**Hỏi: App có phải sửa code gì để có mTLS không?**
Không. Sidecar chặn và mã hóa traffic ở tầng hạ tầng; app vẫn nói HTTP thường với
sidecar cùng pod qua localhost.

**Hỏi: Danh tính trong AuthorizationPolicy lấy từ đâu, giả mạo được không?**
Từ chứng chỉ mTLS mà istiod (CA) ký, danh tính = service account của pod (chuẩn
SPIFFE `cluster.local/ns/<ns>/sa/<sa>`). Không giả được vì không có private key
tương ứng; muốn "đóng vai" service nào phải được quyền tạo pod dùng SA đó — tức đã
kiểm soát bởi RBAC của Kubernetes.

**Hỏi: Vì sao test allowed lại nhận 500 mà vẫn tính là pass?**
Vì tiêu chí là "Istio có cho qua không". Bằng chứng cho qua = không có `RBAC: access
denied` và response do chính app sinh ra. 500 là lỗi đường dẫn của app (actuator nằm
port 8090, không phải 80), xảy ra **sau** khi đã qua cửa Istio.

**Hỏi: Nếu một pod có policy ALLOW mà request không khớp rule nào thì sao?**
Bị từ chối (deny-by-default). Đây là lý do chỉ cần viết allow-list, không cần viết
luật cấm.

**Hỏi: Retry có làm chậm client không?**
Có, trong trường hợp lỗi: client chờ đến khi hết attempts (tối đa ~8s với config
này) mới nhận lỗi cuối. Đổi lại, lỗi thoáng qua được che hoàn toàn. Số đo thực tế:
`x-envoy-upstream-service-time` tăng từ ~12ms lên ~242ms khi cả 4 lần đều lỗi.

**Hỏi: Vì sao không mesh hóa luôn postgres/kafka/keycloak?**
Phạm vi đề bài là service của ứng dụng YAS. Ép STRICT lên hạ tầng có blast radius
lớn (database, message broker là điểm chết toàn hệ thống) và các hệ này thường có cơ
chế mã hóa/xác thực riêng. Quyết định phạm vi được ghi trong
`service-classification.md`.

**Hỏi: Kiali lấy dữ liệu vẽ đồ thị từ đâu?**
Mỗi Envoy xuất metrics (request giữa các cặp service, mã trạng thái, có mTLS hay
không) → Prometheus cào về → Kiali truy vấn Prometheus để dựng đồ thị. Vì vậy thiếu
Prometheus là graph trống, và chỉ những luồng **có traffic gần đây** mới hiện cạnh.

## 14. Checklist deliverables (đối chiếu yêu cầu đề bài)

| Yêu cầu | Bằng chứng | Trạng thái |
|---|---|---|
| YAML mTLS + authorization | 4 manifest trong `k8s/istio/` | ✅ |
| mTLS hoạt động | pod ngoài mesh curl → `exit 56` Connection reset | ✅ |
| Authorization chặn/cho phép | `403 RBAC: access denied` vs response từ app (200 với endpoint thật) | ✅ |
| Retry khi 500 | route config `numRetries: 3`; 1 client call → tax nhận 4 request | ✅ |
| Kiali topology + giải thích | screenshot graph namespace `dev` với icon khóa mTLS | ✅ |
| Test plan + logs | `test-plan.md` + output curl trong `bao-cao-service-mesh.md` | ✅ |
| README từng bước | `README.md` trong `k8s/istio/` + tài liệu này | ✅ |

## 15. Tài liệu liên quan trong repo

- `README.md` — hướng dẫn thao tác gốc, đầy đủ lệnh theo từng mục.
- `test-plan.md` — 5 test case với chỗ dán log cho báo cáo.
- `concept-map.md` — bảng tra nhanh khái niệm ↔ file YAML ↔ lệnh kiểm chứng.
- `service-classification.md` — vì sao giữ/bỏ từng service YAS trong phạm vi demo.
- `bao-cao-service-mesh.md` — báo cáo kết quả với output thật.
