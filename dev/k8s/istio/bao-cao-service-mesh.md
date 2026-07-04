# Báo cáo: Cấu hình Service Mesh (mTLS, Authorization, Retry) cho YAS

> Phần Nâng cao (2đ) — Đồ án 2 môn DevOps. Triển khai Istio Service Mesh trên
> Kubernetes cluster cho ứng dụng microservice YAS: bật mTLS giữa các service,
> giới hạn service-to-service bằng AuthorizationPolicy, cấu hình retry policy, và
> quan sát topology bằng Kiali.

---

## 1. Môi trường và kiến trúc

- **Cluster**: Kubernetes v1.36, kết nối các node qua Tailscale (dải IP `100.x.x.x`).
  - Control plane: `nbsng-legion-5-15iah7` (`100.100.184.0`)
  - Worker: `devops-project02-worker` (`100.74.174.110`) — node chạy toàn bộ pod YAS.
- **Service Mesh**: Istio `1.30.2` (istiod, istio-ingressgateway, Kiali `v2.26.0`).
- **Ứng dụng**: YAS deploy trong namespace `yas` (product, cart, order, customer,
  inventory, tax, media, search, recommendation, rating, storefront-bff/ui,
  backoffice-bff/ui, swagger-ui...).
- **Hạ tầng phụ trợ** (ngoài phạm vi mesh): `postgres`, `kafka`, `keycloak`, `redis`,
  `elasticsearch`.

Cách kết nối tới cluster: dùng kubeconfig admin của master, sửa `server` trỏ về IP
Tailscale của control plane (`https://100.100.184.0:6443`).

### Luồng một request đi qua mesh

```
Client pod ──(1) mTLS handshake──> istio-proxy (Envoy) của pod đích
   (2) PeerAuthentication STRICT: không có mTLS cert  -> RESET kết nối
   (3) AuthorizationPolicy: principal không trong allow-list -> RBAC 403
   (4) VirtualService: routing + retry policy (nếu upstream 5xx thì retry)
   -> App container (product / search / tax ...)
```

---

## 2. Bật mTLS toàn namespace (PeerAuthentication + DestinationRule)

### 2.1. Manifest

File `k8s/istio/mesh-security.yaml` gồm:
- `PeerAuthentication` mode `STRICT`: bắt buộc mọi inbound vào pod `yas` phải có mTLS.
- `DestinationRule` `ISTIO_MUTUAL`: phía gửi tự đính client cert khi gọi service khác.

Áp dụng sidecar injection và manifest:

```bash
# Bật sidecar injection cho namespace yas rồi restart để pod nhận istio-proxy
kubectl label namespace yas istio-injection=enabled --overwrite
kubectl rollout restart deployment -n yas

# Áp dụng cấu hình mTLS
kubectl apply -f k8s/istio/mesh-security.yaml
```

Sau khi restart, mỗi pod YAS có **2/2** container (app + `istio-proxy`):

```
NAME                       READY   STATUS
product-56f7b78c98-25qks   2/2     Running
cart-748755f887-crzbd      2/2     Running
order-55d78785f7-4nmdt     2/2     Running
...  (toàn bộ 2/2)
```

Kiểm tra resource đã vào:

```bash
kubectl get peerauthentication,destinationrule -n yas
```

```
NAME                                  MODE     AGE
peerauthentication.../yas-mtls-strict STRICT   ...

NAME                                  HOST                      AGE
destinationrule.../yas-default-mtls   *.yas.svc.cluster.local   ...
```

### 2.2. Bằng chứng: STRICT mTLS chặn traffic plaintext

Tạo một pod ở namespace `default` (**không có** sidecar, tức không có mTLS cert) rồi
curl vào `product`:

```bash
kubectl run plain-client -n default --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl exec -n default plain-client -- curl -v --max-time 5 http://product.yas/product/actuator/health
```

**Kết quả:**

```
* Connected to product.yas (10.109.27.244) port 80
> GET /product/actuator/health HTTP/1.1
* Request completely sent off
* Recv failure: Connection reset by peer
curl: (56) Recv failure: Connection reset by peer
command terminated with exit code 56
```

**Giải thích:** client không có chứng chỉ mTLS nên Envoy của `product` **reset kết nối
ngay** (`curl exit code 56`). Đây là bằng chứng mạnh nhất cho việc STRICT mTLS đang thực
sự từ chối mọi traffic không mã hóa.

---

## 3. Authorization Policy (giới hạn service-to-service)

### 3.1. Manifest

- `k8s/istio/product-authorization.yaml`: chỉ cho service account `cart`, `order`,
  `inventory`, `search`, `recommendation`, `storefront-bff`, `backoffice-bff`,
  `ingress-nginx` gọi vào `product` port 80.
- `k8s/istio/search-authorization.yaml`: chỉ cho `storefront-bff`, `backoffice-bff`,
  `product`, `ingress-nginx` gọi vào `search` port 80.

```bash
kubectl apply -f k8s/istio/product-authorization.yaml
kubectl apply -f k8s/istio/search-authorization.yaml
```

Định danh service dựa trên **SPIFFE identity** gắn với service account:
`cluster.local/ns/yas/sa/<serviceaccount>`.

### 3.2. Bằng chứng: request bị CHẶN (service không được phép)

Pod trong `yas` nhưng dùng **default service account** (không nằm trong allow-list):

```bash
kubectl run curl-denied -n yas --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl exec -n yas curl-denied -- curl -v --max-time 5 http://product.yas:80/product/actuator/health
```

**Kết quả:**

```
< HTTP/1.1 403 Forbidden
< content-length: 19
< server: envoy
< x-envoy-upstream-service-time: 7
RBAC: access denied
```

**Giải thích:** request qua được lớp mTLS (pod này có sidecar) nhưng bị **Istio chặn tại
lớp AuthorizationPolicy** — `server: envoy` + body `RBAC: access denied` cho thấy Envoy
từ chối trước khi chạm tới app.

### 3.3. Bằng chứng: request được CHO PHÉP (service hợp lệ)

Pod dùng service account `cart` (có trong allow-list của `product`):

```bash
kubectl run curl-allowed -n yas --image=curlimages/curl:8.8.0 --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- sleep 3600
kubectl exec -n yas curl-allowed -- curl -v --max-time 5 http://product.yas:80/product/actuator/health
```

**Kết quả:**

```
< HTTP/1.1 500 Internal Server Error
< content-type: application/json
< server: envoy
{"statusCode":"500 INTERNAL_SERVER_ERROR","title":"Internal Server Error",
 "detail":"No static resource actuator/health for request '/product/actuator/health'."}
```

**Giải thích:** **KHÔNG** có chuỗi `RBAC: access denied` → Istio đã **cho qua** vì SA `cart`
nằm trong allow-list. Response là JSON lỗi của **chính app product** (định dạng
`ApiExceptionHandler` của YAS) → request đã chạm tới app container. Lỗi 500 chỉ vì đường
`/product/actuator/health` không tồn tại trên port 80 (actuator nằm ở port 8090), không
liên quan tới mesh.

> **Đối chiếu 2 test:** service không được phép → Envoy trả `403 RBAC: access denied`
> (chặn trước app); service được phép → app trả lời (đã qua Istio). Chính sự khác biệt này
> chứng minh AuthorizationPolicy hoạt động đúng.

Có thể xác nhận thêm bằng endpoint API thật (cho ra 200 sạch để chụp):

```bash
kubectl exec -n yas curl-allowed -- curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://product.yas:80/product/storefront/products?page=0&size=1"
# -> HTTP 200 (allowed)

kubectl exec -n yas curl-denied -- curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://product.yas:80/product/storefront/products?page=0&size=1"
# -> HTTP 403 (denied)
```

---

## 4. Retry Policy (VirtualService)

### 4.1. Manifest

File `k8s/istio/tax-retry.yaml` định nghĩa retry cho traffic tới `tax`: nếu upstream trả
`5xx`, reset, connect-failure, refused-stream, gateway-error thì Envoy retry tối đa **3
lần**, mỗi lần timeout **2s** (`perTryTimeout`), trong tổng timeout **10s**.

```yaml
http:
  - name: tax-http-retry
    timeout: 10s
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,reset,connect-failure,refused-stream,gateway-error
    route:
      - destination:
          host: tax.yas.svc.cluster.local
          port: { number: 80 }
```

```bash
kubectl apply -f k8s/istio/tax-retry.yaml
```

### 4.2. Bằng chứng 1: retry policy đã nằm trong route config của Envoy

```bash
istioctl proxy-config routes deploy/order -n yas --name 80 -o json | grep -A20 -i retryPolicy
```

Block gắn với `virtual-service/tax-retry`:

```json
"retryPolicy": {
    "retryOn": "5xx,reset,connect-failure,refused-stream,gateway-error",
    "numRetries": 3,
    "perTryTimeout": "2s"
},
"maxGrpcTimeout": "10s",
"metadata": { "filterMetadata": { "istio": {
    "config": ".../namespaces/yas/virtual-service/tax-retry" } } }
```

> **Lưu ý phân biệt:** các route khác hiển thị `numRetries: 2` là **retry mặc định Istio
> tự thêm** cho mọi service. Chỉ block gắn `tax-retry` với `numRetries: 3` +
> `perTryTimeout: 2s` là cấu hình của nhóm.

### 4.3. Bằng chứng 2: runtime — 1 client call sinh ra nhiều upstream request

Vì Istio mặc định lọc bớt stats của Envoy (counter `upstream_rq_retry` của từng outbound
cluster không được expose), ta chứng minh retry bằng cách **đếm số request mà app `tax`
thực nhận** cho một lần client gọi. Endpoint `/tax/actuator/health` trên port 80 trả 500
(khớp `retryOn: 5xx`) nên kích hoạt retry:

```bash
TAX_POD=$(kubectl get pod -n yas -l app.kubernetes.io/name=tax -o jsonpath='{.items[0].metadata.name}')
BEFORE=$(kubectl logs -n yas "$TAX_POD" -c tax | grep -c "Error: URI: /actuator/health")

# 1 request duy nhất từ client
kubectl exec -n yas curl-allowed -- curl -s -o /dev/null -w "client thấy HTTP %{http_code}\n" \
  --max-time 10 http://tax.yas:80/tax/actuator/health

AFTER=$(kubectl logs -n yas "$TAX_POD" -c tax | grep -c "Error: URI: /actuator/health")
echo "tax nhận $((AFTER-BEFORE)) request cho 1 lần client gọi"
```

**Kết quả:**

```
client thấy HTTP 500
tax nhận 8 request cho 1 lần client gọi
```

**Giải thích:** app Spring Boot log mỗi request lỗi thành 2 dòng (dispatch + ERROR
re-dispatch), nên `8 ÷ 2 = 4 request thật = 1 gốc + 3 retry`, khớp chính xác
`numRetries: 3`. Ngoài ra header `x-envoy-upstream-service-time: 242ms` (gấp ~20 lần
request thường ~12ms) cũng phản ánh Envoy đã thử lại nhiều lần.

---

## 5. Kiali Topology

### 5.1. Cài Prometheus addon (Kiali cần để vẽ traffic graph)

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.30/samples/addons/prometheus.yaml
kubectl rollout status deployment/prometheus -n istio-system
```

### 5.2. Mở Kiali và sinh traffic

```bash
# Port-forward Kiali ra ngoài (truy cập từ máy có trình duyệt qua Tailscale)
kubectl port-forward -n istio-system svc/kiali 20001:20001 --address 0.0.0.0
# -> http://<tailscale-ip>:20001/kiali

# Sinh traffic để đồ thị có cạnh
for i in $(seq 1 30); do
  kubectl exec -n yas curl-allowed -- curl -s -o /dev/null --max-time 3 "http://product.yas:80/product/storefront/products?page=0&size=2"
  kubectl exec -n yas curl-allowed -- curl -s -o /dev/null --max-time 3 "http://tax.yas:80/tax/actuator/health"
  kubectl exec -n yas curl-allowed -- curl -s -o /dev/null --max-time 3 "http://inventory.yas:80/inventory/actuator/health"
  kubectl exec -n yas curl-allowed -- curl -s -o /dev/null --max-time 3 "http://media.yas:80/media/actuator/health"
done
```

Trong Kiali: chọn namespace `yas` → **Graph** → Display bật `Traffic`, `Security`,
`Service Nodes` → chụp màn hình.

*(Chèn 2 ảnh chụp: (a) toàn cảnh topology, (b) chi tiết các cạnh có khóa mTLS.)*

### 5.3. Giải thích topology

- Mỗi node **vuông** = service, node **tam giác/tròn** = workload/app (tag version
  `latest`).
- **Cạnh có icon khóa 🔒** = traffic được mã hóa **mTLS** (nhờ PeerAuthentication STRICT +
  DestinationRule ISTIO_MUTUAL). Thấy rõ trên các cạnh `recommendation → product`,
  `product → media`, `media → workload`.
- **Cạnh xanh KHÔNG có khóa** đi tới `postgresql` = kết nối TCP tới database ở namespace
  `postgres`, **không** thuộc mesh (không bật sidecar) nên đúng là không mTLS — khớp với
  quyết định giới hạn mTLS trong phạm vi `yas`, không ép lên hạ tầng.
- **PassthroughCluster** (icon chìa khóa) = traffic thoát ra ngoài mesh tới đích Istio
  không quản lý.
- `search → kafka-cluster-kafka-brokers` = search giao tiếp event qua Kafka.

---

## 6. Ghi chú triển khai (vấn đề gặp phải và cách xử lý)

1. **Seed data trước khi bật authz:** service `sampledata` không tự seed lúc start mà cần
   trigger qua API `POST /sampledata/storefront/sampledata`. Phải seed xong (product có
   data) rồi mới scale `sampledata` về 0 và bật mesh.

2. **Cơn bão khởi động khi restart đồng loạt:** `kubectl rollout restart deployment -n yas`
   restart toàn bộ ~15 service cùng lúc trên **một** node → JVM khởi động dồn dập làm CPU
   nghẽn → probe `timeout=1s` fail → pod restart lặp. Node đủ tài nguyên ở steady-state
   (CPU requests 63%, RAM 73%) nên cụm tự hội tụ `2/2` sau vài phút. Nếu kẹt lâu có thể
   tạm scale bớt các UI/BFF không thiết yếu để giảm tải.

3. **ingress-nginx chạy hostNetwork:** controller là DaemonSet với `hostNetwork: true` nên
   Istio **không inject sidecar được**. Vì các bằng chứng mesh (mTLS/authz/retry/topology)
   đều là traffic **service-to-service bên trong** cluster (test bằng pod-to-pod curl theo
   đúng yêu cầu đề bài), việc ingress không vào mesh **không ảnh hưởng** deliverable. Web
   UI nếu cần demo thì dùng `kubectl port-forward` thay đường ingress.

---

## 7. Tổng kết Deliverables

| # | Yêu cầu | Bằng chứng |
|---|---------|-----------|
| 1 | YAML mTLS + authorization | `mesh-security.yaml`, `product/search-authorization.yaml` đã apply |
| — | mTLS chặn plaintext | `curl exit 56` — Connection reset by peer |
| 2 | Kiali topology + giải thích | 2 ảnh graph namespace `yas` với khóa mTLS |
| 3a | Authorization allow/deny | denied → `403 RBAC: access denied`; allowed → app response (không RBAC) |
| 3b | Retry policy | route config `numRetries:3, perTryTimeout:2s`; 1 client call → tax nhận 4 request |
| 4 | Test plan + logs | Toàn bộ output curl + lệnh trong báo cáo này |

**Manifest đính kèm** (thư mục `k8s/istio/`):
`mesh-security.yaml`, `tax-retry.yaml`, `product-authorization.yaml`,
`search-authorization.yaml`, kèm `README.md` hướng dẫn từng bước và `test-plan.md`.
