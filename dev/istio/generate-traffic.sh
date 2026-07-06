#!/usr/bin/env bash
# generate-traffic.sh — sinh traffic service-to-service để Kiali vẽ topology.
#
# Tạo ra:
#   • edge mTLS (icon khóa 🔒) từ 1 pod generator tới nhiều service (health :8090 -> 200)
#   • edge ĐƯỢC PHÉP: generator (SA storefront-bff) -> product:80  (nằm trong allow-list)
#   • edge BỊ CHẶN: curl-denied (SA default) -> product:80 -> 403 (Kiali tô đỏ)
#   • edge RETRY: generator -> tax:80/actuator/health -> 500 -> VirtualService retry 3 lần
#
# Dùng:
#   ./generate-traffic.sh              # chạy 300s trên namespace dev
#   NS=staging DURATION=600 ./generate-traffic.sh
#   ./generate-traffic.sh clean        # xóa các pod generator
#
# Sau khi chạy: istioctl dashboard kiali -> chọn namespace -> Graph
#   -> Display: bật Traffic Animation + Security -> Time range: Last 5m + Refresh 10s

set -uo pipefail

NS="${NS:-dev}"
DURATION="${DURATION:-300}"     # tổng thời gian chạy (giây)
INTERVAL="${INTERVAL:-2}"       # nghỉ giữa các vòng (giây)
IMAGE="${IMAGE:-curlimages/curl:8.8.0}"

ALLOWED_POD="mesh-gen-allowed"  # SA storefront-bff — được phép gọi product & search
ALLOWED_SA="storefront-bff"
DENIED_POD="curl-denied"        # SA default — bị AuthorizationPolicy chặn

# services có pod đang chạy — gọi /actuator/health trên port 8090 (200, sạch, vẫn mTLS)
HEALTH_SVCS="product search cart order inventory customer media tax storefront-bff backoffice-bff"

if [ "${1:-}" = "clean" ]; then
  kubectl delete pod "$ALLOWED_POD" "$DENIED_POD" -n "$NS" --ignore-not-found
  exit 0
fi

# Tạo pod nếu chưa có / recreate nếu không ở trạng thái Running.
ensure_pod() {
  local name="$1" sa="$2"
  local phase
  phase=$(kubectl get pod "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$phase" != "Running" ]; then
    if [ -n "$phase" ]; then
      echo "==> pod $name đang ở '$phase' -> tạo lại"
      kubectl delete pod "$name" -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
    fi
    echo "==> tạo pod $name (serviceAccount=$sa)"
    kubectl run "$name" -n "$NS" --image="$IMAGE" --restart=Never \
      --overrides="{\"spec\":{\"serviceAccountName\":\"$sa\"}}" -- sleep 86400 >/dev/null
  fi
}

echo "==> namespace=$NS  duration=${DURATION}s  interval=${INTERVAL}s"
ensure_pod "$ALLOWED_POD" "$ALLOWED_SA"
ensure_pod "$DENIED_POD" "default"
kubectl wait -n "$NS" --for=condition=Ready pod/"$ALLOWED_POD" pod/"$DENIED_POD" --timeout=120s

# Loop chạy BÊN TRONG pod (một exec, không tốn overhead mỗi request). $1=NS $2=DUR $3=INT $4=svcs
ALLOWED_SCRIPT='
NS="$1"; DUR="$2"; INT="$3"; SVCS="$4";
END=$(( $(date +%s) + DUR ));
while [ "$(date +%s)" -lt "$END" ]; do
  for s in $SVCS; do
    curl -s -o /dev/null --max-time 3 "http://$s.$NS:8090/actuator/health";
  done;
  # được phép: storefront-bff -> product:80
  curl -s -o /dev/null --max-time 3 "http://product.$NS:80/product/storefront/products?page=0&size=1";
  # retry: tax:80/actuator/health trả 500 -> Envoy retry 3 lần
  curl -s -o /dev/null --max-time 5 "http://tax.$NS:80/tax/actuator/health";
  sleep "$INT";
done
'

DENIED_SCRIPT='
NS="$1"; DUR="$2"; INT="$3";
END=$(( $(date +%s) + DUR ));
while [ "$(date +%s)" -lt "$END" ]; do
  # bị chặn: default SA -> product:80 -> 403 RBAC
  curl -s -o /dev/null --max-time 3 "http://product.$NS:80/product/storefront/products?page=0&size=1";
  sleep "$INT";
done
'

echo "==> bắt đầu sinh traffic (${DURATION}s)... Ctrl-C để dừng sớm."
kubectl exec -n "$NS" "$ALLOWED_POD" -- sh -c "$ALLOWED_SCRIPT" _ "$NS" "$DURATION" "$INTERVAL" "$HEALTH_SVCS" &
PID_A=$!
kubectl exec -n "$NS" "$DENIED_POD" -- sh -c "$DENIED_SCRIPT" _ "$NS" "$DURATION" "$INTERVAL" &
PID_D=$!

trap 'echo; echo "==> dừng..."; kill $PID_A $PID_D 2>/dev/null; exit 0' INT
wait $PID_A $PID_D

echo "==> xong."
echo "    Mở Kiali:  istioctl dashboard kiali"
echo "    -> Graph -> namespace $NS -> Display: Traffic + Security -> Time: Last 5m"
echo "    Dọn dẹp:   ./generate-traffic.sh clean   (NS=$NS)"
