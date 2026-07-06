# YAS Service Mesh với Istio

Phần này dành cho deliverable nâng cao: bật mTLS, giới hạn service-to-service access, cấu hình retry policy và chụp topology bằng Kiali.

Đọc thêm phần phân loại service trong `service-classification.md` trước khi demo. Bạn nên giữ nhóm core e-commerce gồm `product`, `cart`, `order`, `customer`, `inventory`, `tax`, `media`, `search`, `storefront-bff`, `storefront-ui`, `backoffice-bff`, `backoffice-ui`, `swagger-ui`; `sampledata` chỉ cần chạy một lần để seed data.

## 0. Chuẩn bị kết nối tới cluster

Mọi lệnh trong README (`kubectl`, `helm`, `istioctl`) đều là client gọi tới API server của master, nên có thể chạy theo 1 trong 2 hướng. Các bước từ mục 1 trở đi giống hệt nhau cho cả 2 hướng.

Với cluster dùng Tailscale, dùng IP `100.x.x.x` của master. Không dùng IP LAN `192.168.x.x`, `10.x.x.x`, `172.16.x.x`.

### Hướng A: SSH vào master và chạy trên master

Nếu máy hiện tại chỉ có code và không có `kubectl`, hãy đẩy thư mục này lên repo/git hoặc copy riêng lên master:

```bash
scp -r k8s/istio <user>@<master-tailscale-ip>:/home/<user>/yas-istio
ssh <user>@<master-tailscale-ip>
cd /home/<user>/yas-istio
```

Master đã sẵn `kubectl` + kubeconfig admin, chỉ cần cài thêm `istioctl` (mục 2).

### Hướng B: dùng kubeconfig trên worker (không SSH vào master)

Copy kubeconfig admin từ master về worker:

```bash
mkdir -p ~/.kube
scp <user>@<master-tailscale-ip>:/home/<user>/.kube/config ~/.kube/config
```

Khác biệt 1 - sửa địa chỉ API server: kubeconfig lấy từ master thường trỏ `server: https://<ip-lan-master>:6443`. Nếu worker nối với master qua Tailscale thì phải đổi sang IP Tailscale (cùng LAN và IP LAN gọi được thì giữ nguyên):

```bash
grep server: ~/.kube/config
sed -i 's|server: https://.*:6443|server: https://<master-tailscale-ip>:6443|' ~/.kube/config
kubectl get nodes -o wide
```

Khác biệt 2 - lỗi x509 khi đổi sang IP Tailscale: cert của API server do kubeadm sinh thường chỉ có SAN là IP LAN + hostname, nên có thể gặp `x509: certificate is valid for ... not 100.x.x.x`. Fix nhanh cho demo: mở `~/.kube/config`, trong entry `cluster` xóa dòng `certificate-authority-data` và thêm `insecure-skip-tls-verify: true`. (Cách chuẩn là regenerate cert apiserver thêm SAN, không cần thiết cho đồ án.)

Khác biệt 3 - worker cần tự cài tool: `kubectl`, `helm`, và `istioctl` (bước tải istioctl ở mục 2 chạy ngay trên worker được; `istioctl install` cài Istio vào cluster qua API server, không cần đứng trên master).

Các bước `kubectl run` / `kubectl exec` / `kubectl scale` trong các mục test phía sau không đổi gì cả - chúng chỉ cần kubeconfig có quyền admin.

## 1. Kiểm tra YAS đã deploy

```bash
kubectl get ns
kubectl get pods -n dev
kubectl get svc -n dev
```

YAS chart trong repo deploy các service vào namespace `dev`; service name thường là `cart`, `order`, `product`, `storefront-bff`, `backoffice-bff`, ...

## 2. Cài Istio và Kiali

Cách nhanh nhất:

```bash
curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH="$PWD/bin:$PATH"
istioctl install --set profile=demo -y
kubectl apply -f samples/addons/kiali.yaml
kubectl apply -f samples/addons/prometheus.yaml
kubectl rollout status deployment/kiali -n istio-system
```

Nếu cluster không cho tải internet trực tiếp trên master, tải thư mục `istio-*` ở máy cá nhân rồi copy lên master bằng `scp`.

## 3. Bật sidecar injection cho namespace YAS

```bash
kubectl label namespace dev istio-injection=enabled --overwrite
kubectl rollout restart deployment -n dev
kubectl rollout status deployment/product -n dev
kubectl get pods -n dev -o jsonpath='{range .items[*]}{.metadata.name}{" containers="}{.spec.containers[*].name}{"\n"}{end}'
```

Mỗi pod YAS cần có container `istio-proxy`.

Lưu ý về `sampledata`: nếu chưa seed data, hãy chạy `sampledata` xong TRƯỚC khi apply các AuthorizationPolicy ở mục 4, vì service account `sampledata` không nằm trong allow-list của `product`. Sau khi có data thì scale về 0:

```bash
kubectl scale deployment/sampledata -n dev --replicas=0
```

## 3.1. Cho ingress-nginx tham gia mesh (BẮT BUỘC khi bật STRICT)

Storefront/backoffice/api đều đi qua ingress-nginx. Khi `PeerAuthentication` mode `STRICT` được bật, pod ingress-nginx (không có sidecar) sẽ gửi plaintext vào các pod YAS và bị từ chối kết nối - toàn bộ web sẽ chết. Fix bằng cách inject sidecar cho ingress-nginx:

```bash
kubectl get ns | grep -i ingress
kubectl label namespace ingress-nginx istio-injection=enabled --overwrite
kubectl rollout restart deployment -n ingress-nginx
kubectl get pods -n ingress-nginx   # controller phải là 2/2
```

Kiểm tra tên service account của controller (dùng trong AuthorizationPolicy):

```bash
kubectl get pods -n ingress-nginx -o jsonpath='{.items[0].spec.serviceAccountName}'
```

Nếu kết quả khác `ingress-nginx` hoặc namespace khác, sửa lại principal `cluster.local/ns/ingress-nginx/sa/ingress-nginx` trong `product-authorization.yaml` và `search-authorization.yaml` cho khớp.

Nếu vì lý do nào đó không thể inject ingress-nginx (ví dụ controller chạy hostNetwork), phương án dự phòng để demo UI: `kubectl port-forward -n dev svc/storefront-ui 3000:3000` và bỏ qua đường ingress.

## 4. Apply manifest service mesh

Nếu đã clone cả repo trên master, chạy từ root repo:

```bash
kubectl apply -f k8s/istio/mesh-security.yaml
kubectl apply -f k8s/istio/tax-retry.yaml
kubectl apply -f k8s/istio/product-authorization.yaml
kubectl apply -f k8s/istio/search-authorization.yaml
```

Nếu chỉ copy riêng thư mục `k8s/istio` lên master, chạy:

```bash
kubectl apply -f mesh-security.yaml
kubectl apply -f tax-retry.yaml
kubectl apply -f product-authorization.yaml
kubectl apply -f search-authorization.yaml
```

Kiểm tra:

```bash
kubectl get peerauthentication,destinationrule,virtualservice,authorizationpolicy -n dev
istioctl x describe svc product -n dev
istioctl proxy-config routes deploy/order -n dev --name 80 -o json | grep -i retry -n
```

Lưu ý: lệnh `istioctl authn tls-check` đã bị gỡ khỏi istioctl từ bản 1.5, dùng `istioctl x describe` như trên (output sẽ hiện PeerAuthentication STRICT và DestinationRule ISTIO_MUTUAL áp lên service).

## 5. Kịch bản test mTLS

Kiểm tra sidecar và mTLS:

```bash
kubectl get pod -n dev -l app.kubernetes.io/name=cart
istioctl proxy-config secret deploy/cart -n dev
istioctl x describe svc cart -n dev
```

Test trực tiếp STRICT mTLS chặn plaintext: tạo pod ở namespace KHÔNG có sidecar (ví dụ `default`) rồi curl vào service YAS:

```bash
kubectl run plain-client -n default --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl wait -n default --for=condition=Ready pod/plain-client --timeout=120s
kubectl exec -n default plain-client -- curl -v --max-time 5 http://product.dev/product/actuator/health
```

Kết quả mong đợi: connection bị reset (curl exit code 56 hoặc "Connection reset by peer") vì client không có mTLS cert - đây là evidence mạnh nhất cho STRICT.

Evidence cần chụp:

- output `kubectl get pods -n dev` thấy mỗi pod có `2/2`.
- output `istioctl x describe svc cart -n dev` hiện PeerAuthentication STRICT.
- output `istioctl proxy-config secret` hiện cert `default` và `ROOTCA` trạng thái ACTIVE.
- curl plaintext từ pod ngoài mesh bị reset.
- Kiali edge giữa service có biểu tượng lock/mTLS.

## 6. Kịch bản test authorization policy

Policy trong file `product-authorization.yaml` chỉ cho các service account `cart`, `order`, `inventory`, `search`, `storefront-bff`, `backoffice-bff` và `ingress-nginx` gọi vào `product` port `80`. (`inventory` và `search` bắt buộc phải có vì code của chúng gọi trực tiếp product API; `ingress-nginx` để api/swagger-ui vẫn hoạt động.)

Policy trong file `search-authorization.yaml` chỉ cho `storefront-bff`, `backoffice-bff`, `product`, `ingress-nginx` gọi vào `search` port `80`. Đây là target tốt để demo AuthorizationPolicy cho chức năng tìm kiếm.

Tạo pod debug nằm ngoài allow-list:

```bash
kubectl run curl-denied -n dev --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl wait -n dev --for=condition=Ready pod/curl-denied --timeout=120s
kubectl exec -n dev curl-denied -- curl -v --max-time 5 "http://product.dev:80/product/storefront/products?page=0&size=1"
```

Kết quả mong đợi: bị chặn — HTTP `403` với body `RBAC: access denied`.

Test từ service được phép. Image `cart` không có sẵn `curl`, nên tạo debug pod chạy với serviceAccount `cart` (flag `--serviceaccount` đã bị gỡ khỏi kubectl từ bản 1.24, phải dùng `--overrides`):

```bash
kubectl run curl-allowed -n dev --image=curlimages/curl:8.8.0 --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- sleep 3600
kubectl wait -n dev --for=condition=Ready pod/curl-allowed --timeout=120s
kubectl exec -n dev curl-allowed -- curl -v --max-time 5 "http://product.dev:80/product/storefront/products?page=0&size=1"
```

Kết quả mong đợi: HTTP `200`, không có chuỗi `RBAC: access denied` → SA `cart` nằm trong allow-list nên request chạm tới app. (Nếu gọi `/product/actuator/health` sẽ ra `500` vì actuator nằm ở port `8090`, không phải port 80 — không liên quan tới mesh.)

Test deny với `search` cũng tương tự:

```bash
kubectl exec -n dev curl-denied -- curl -v --max-time 5 http://search.dev:80/search/actuator/health
```

Kết quả mong đợi: `RBAC: access denied` hoặc HTTP `403`.

## 7. Kịch bản test retry policy

Retry policy nằm trong `tax-retry.yaml`: nếu upstream `tax` trả `5xx`, reset, gateway-error, connect-failure hoặc refused-stream thì Envoy retry tối đa 3 lần, mỗi lần timeout 2s (`perTryTimeout`), trong timeout tổng 10s. Chọn `tax` vì code `order` có dependency trực tiếp tới `tax`, hợp với flow demo `order -> tax`.

Kiểm tra config đã nằm trong proxy:

```bash
istioctl proxy-config routes deploy/order -n dev --name 80 -o json | grep -A20 -i retryPolicy
```

Chạy request từ client có sidecar vào `tax`. Dùng API nào có thể tạo lỗi 500 trong môi trường của bạn; nếu không có endpoint lỗi 500, có thể tạm thời scale `tax` về 0 để tạo connect failure rồi scale lại:

```bash
ORDER_POD=$(kubectl get pod -n dev -l app.kubernetes.io/name=order -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n dev "$ORDER_POD" -c istio-proxy -- pilot-agent request GET stats | grep upstream_rq_retry

kubectl scale deployment/tax -n dev --replicas=0
kubectl exec -n dev "$ORDER_POD" -c order -- curl -v --max-time 8 http://tax.dev:80/tax/actuator/health || true
kubectl scale deployment/tax -n dev --replicas=1
kubectl rollout status deployment/tax -n dev

kubectl exec -n dev "$ORDER_POD" -c istio-proxy -- pilot-agent request GET stats | grep upstream_rq_retry
```

Evidence cần chụp/log:

- VirtualService có `retryPolicy`.
- Counter `upstream_rq_retry` hoặc `upstream_rq_retry_success` tăng sau request lỗi.
- Log `curl -v` của request lỗi và retry counter trước/sau.

## 8. Chụp Kiali topology

Mở Kiali:

```bash
istioctl dashboard kiali
```

Lệnh này port-forward về chính máy đang chạy lệnh. Nếu theo Hướng B (worker/máy cá nhân có trình duyệt) thì mở thẳng `http://localhost:20001/kiali`, xong.

Nếu theo Hướng A (master headless, không có trình duyệt) thì port-forward mở ra ngoài rồi truy cập từ máy cá nhân:

```bash
kubectl port-forward -n istio-system svc/kiali 20001:20001 --address 0.0.0.0
```

Mở trình duyệt: `http://<master-tailscale-ip>:20001/kiali`.

Trong Kiali:

1. Chọn namespace `dev`.
2. Vào Graph.
3. Display: bật `Traffic`, `Security`, `Service Nodes`.
4. Generate traffic bằng cách truy cập storefront/backoffice hoặc curl các service.
5. Chụp màn hình topology.

Giải thích flow mẫu:

```text
storefront-ui -> storefront-bff -> cart/order/product/customer/...
backoffice-ui -> backoffice-bff -> product/inventory/order/...
cart -> product
order -> product/cart/customer/tax/promotion
search -> product
```

Cần ghi rõ trong báo cáo: các edge trong namespace `dev` được mã hóa mTLS; `product` và `search` chỉ chấp nhận inbound từ allow-list trong AuthorizationPolicy; retry policy được áp dụng cho traffic tới `tax`.

## 9. Dọn dẹp pod test

```bash
kubectl delete pod curl-denied curl-allowed -n dev --ignore-not-found
kubectl delete pod plain-client -n default --ignore-not-found
```
