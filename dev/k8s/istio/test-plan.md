# Test plan - YAS Istio service mesh

## Phạm vi

- Namespace: `yas`
- Server có policy: `product`, `search`
- Target retry: `tax`
- Caller được phép gọi `product`: `cart`, `order`, `inventory`, `search`, `recommendation`, `storefront-bff`, `backoffice-bff`, `ingress-nginx`
- Caller được phép gọi `search`: `storefront-bff`, `backoffice-bff`, `product`, `ingress-nginx`
- Caller bị chặn: pod `curl-denied` dùng default service account
- Caller plaintext ngoài mesh: pod `plain-client` trong namespace `default`

## TC1 - Sidecar injection và mTLS

Lệnh:

```bash
kubectl get pods -n yas
istioctl x describe svc product -n yas
istioctl proxy-config secret deploy/product -n yas
kubectl run plain-client -n default --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl wait -n default --for=condition=Ready pod/plain-client --timeout=120s
kubectl exec -n default plain-client -- curl -v --max-time 5 http://product.yas/product/actuator/health
```

Kết quả mong đợi:

- Pod YAS hiển thị `2/2` containers.
- `istio-proxy` tồn tại trong mỗi pod được test.
- `istioctl x describe` hiển thị PeerAuthentication STRICT và DestinationRule ISTIO_MUTUAL.
- Plaintext curl từ pod không nằm trong mesh thất bại với connection reset (curl exit 56), chứng minh STRICT từ chối traffic không có mTLS.

## TC2 - Authorization bị chặn

Lệnh:

```bash
kubectl run curl-denied -n yas --image=curlimages/curl:8.8.0 --restart=Never -- sleep 3600
kubectl wait -n yas --for=condition=Ready pod/curl-denied --timeout=120s
kubectl exec -n yas curl-denied -- curl -v --max-time 5 http://product.yas:80/product/actuator/health
```

Kết quả mong đợi:

- HTTP `403` hoặc response body có `RBAC: access denied`.

Log evidence để paste vào báo cáo:

```text
<paste curl -v output here>
```

## TC3 - Authorization được phép

Lệnh:

```bash
kubectl run curl-allowed -n yas --image=curlimages/curl:8.8.0 --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- sleep 3600
kubectl wait -n yas --for=condition=Ready pod/curl-allowed --timeout=120s
kubectl exec -n yas curl-allowed -- curl -v --max-time 5 http://product.yas:80/product/actuator/health
```

Kết quả mong đợi:

- Request không bị Istio RBAC deny.
- Spring Security `401/403` vẫn chấp nhận được nếu endpoint yêu cầu app authentication; evidence quan trọng là không có `RBAC: access denied`.

Log evidence để paste vào báo cáo:

```text
<paste curl -v output here>
```

## TC4 - Retry policy

Lệnh:

```bash
istioctl proxy-config routes deploy/order -n yas --name 80 -o json | grep -A20 -i retryPolicy
ORDER_POD=$(kubectl get pod -n yas -l app.kubernetes.io/name=order -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n yas "$ORDER_POD" -c istio-proxy -- pilot-agent request GET stats | grep upstream_rq_retry
kubectl scale deployment/tax -n yas --replicas=0
kubectl exec -n yas "$ORDER_POD" -c order -- curl -v --max-time 8 http://tax.yas:80/tax/actuator/health || true
kubectl scale deployment/tax -n yas --replicas=1
kubectl rollout status deployment/tax -n yas
kubectl exec -n yas "$ORDER_POD" -c istio-proxy -- pilot-agent request GET stats | grep upstream_rq_retry
```

Kết quả mong đợi:

- Route config có retry policy với `numRetries: 3`.
- Retry counter tăng sau request lỗi tới upstream.

Log evidence để paste vào báo cáo:

```text
<paste route config and retry counter before/after here>
```

## TC5 - Kiali topology

Các bước:

1. Mở Kiali: `istioctl dashboard kiali` hoặc port-forward service `kiali`.
2. Chọn namespace `yas`.
3. Generate traffic bằng cách mở storefront/backoffice hoặc chạy curl tests.
4. Chụp Graph view có bật Traffic và Security.

Kết quả mong đợi:

- Graph hiển thị các YAS services và edges.
- Edge trong mesh có mTLS/security indicator.
