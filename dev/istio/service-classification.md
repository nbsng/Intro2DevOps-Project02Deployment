# Phân loại service YAS cho demo Service Mesh

## Nên giữ cho demo e-commerce và Service Mesh

| Service | Giữ? | Lý do |
| --- | --- | --- |
| product | Có | Product catalog, service trung tâm của shop. Đây là target tốt cho AuthorizationPolicy vì `cart`, `order`, và các BFF service đều gọi tới nó. |
| cart | Có | Giỏ hàng, cần cho flow mua hàng và có gọi `product` để validate sản phẩm. |
| order | Có | Flow checkout/order. Đây là client tốt cho retry demo vì nó gọi các service khác như `tax`, `cart`, `customer`, `product`, và `promotion`. |
| customer | Có | Dữ liệu profile/address của khách hàng, dùng trong order flow. |
| inventory | Có | Domain kho/stock. Giữ để topology e-commerce đầy đủ, dù trong snapshot repo hiện tại code `order` không gọi trực tiếp `inventory`. |
| tax | Có | Service tính thuế. Dùng làm target chính cho VirtualService retry demo ở flow `order -> tax`. |
| media | Có | Service ảnh/media sản phẩm, hữu ích cho demo quản lý sản phẩm. |
| search | Có | Service tìm kiếm. Dùng làm target demo AuthorizationPolicy; cho phép BFF/product callers và chặn pod ngẫu nhiên. |
| storefront-bff | Có | Backend-for-frontend cho storefront của khách hàng. Đây là service inbound chính cho flow storefront. |
| storefront-ui | Có | UI phía khách hàng để demo cho giảng viên. |
| backoffice-bff | Có | Backend-for-frontend cho workflow admin/backoffice. |
| backoffice-ui | Có | UI admin để quản lý product/media/order. |
| swagger-ui | Có | API documentation và dùng để tra endpoint nhanh trong lúc demo. |
| sampledata | Chạy một lần | Chạy một lần để seed data, sau đó scale down hoặc uninstall khi đã có data. |

Tổng cho demo: 14 application services, trong đó `sampledata` được xem như service chạy một lần sau khi seed data.

## Optional hoặc không bắt buộc cho demo Service Mesh tối thiểu

| Service | Khuyến nghị | Ghi chú |
| --- | --- | --- |
| payment | Optional | Giữ nếu nhóm muốn demo payment APIs. Script `deploy-yas-applications.sh` hiện tại không deploy service này mặc định. |
| payment-paypal | Optional | Chỉ giữ nếu PayPal flow nằm trong phạm vi demo. |
| promotion | Optional nhưng hữu ích | Code `order` có gọi `promotion`, nên giữ nếu test phần tính promotion trong checkout. Script deploy hiện tại không deploy service này mặc định. |
| rating | Optional | Hữu ích cho product detail, nhưng không bắt buộc cho demo mTLS/authz/retry. |
| recommendation | Optional nhưng hữu ích | Gọi dữ liệu liên quan tới product và làm topology trong Kiali phong phú hơn. Service này được deploy bởi script hiện tại. |
| location | Optional | Hữu ích cho address/customer flows. Script hiện tại không deploy service này. |
| webhook | Optional | Domain event/webhook, không cần cho demo service mesh core. |

## Infrastructure nên để ngoài phân loại app service

Đây là các platform dependency bắt buộc, không phải YAS app services:

- `postgres` / PostgreSQL operator và databases
- `redis`
- `keycloak`
- `kafka` / Strimzi / Debezium
- `elasticsearch` / Kibana
- các component trong `istio-system`: `istiod`, ingress/egress gateway, Kiali, Prometheus addon
- observability stack optional: Grafana, Loki, Tempo, OpenTelemetry Collector

Với deliverable Service Mesh, tập trung mTLS và AuthorizationPolicy vào namespace `dev`. Không ép Istio mTLS lên các namespace infrastructure trừ khi cả nhóm đồng ý và đã test kỹ blast radius.

## Tên riêng theo repo này

Trong Helm chart của repo này, Kubernetes service name là tên ngắn:

- `product`, `cart`, `order`, `tax`, `search`, `storefront-bff`, `backoffice-bff`

Service port của backend apps là `80`, còn actuator/metrics port là `8090`.

Không dùng tên generic như `catalog-service`, `order-service`, `payment-service`, hoặc port `8080` trừ khi cluster thật của nhóm hiển thị đúng các tên đó bằng:

```bash
kubectl get svc -n dev
kubectl get deploy -n dev
```
