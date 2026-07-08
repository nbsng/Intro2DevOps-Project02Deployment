#!/bin/bash
# =============================================================================
# Script: copy-resources
# Mục đích: Copy các ConfigMap và Secret bắt buộc từ namespace source
#           sang namespace destination.
#
# Các service trong namespace dev, staging cần dùng chung:
#   - ConfigMaps: application configs, gateway routes, yas-configuration
#   - Secrets: redis, keycloak, postgresql, elasticsearch, openai credentials
#
# Cách chạy:
#   chmod +x copy-resources.sh
#   ./copy-resources.sh <namespace source> <namespace destination>
# =============================================================================

set -e

SOURCE_NS="${1}"
TARGET_NS="${2}"

echo "=============================================="
echo "  Copying resources: ${SOURCE_NS} → ${TARGET_NS}"
echo "=============================================="

# Đảm bảo namespace đích tồn tại
kubectl create namespace "${TARGET_NS}" --dry-run=client -o yaml | kubectl apply -f -

# ==============================================================================
# 1. COPY TẤT CẢ CONFIGMAPS (bỏ qua các configmap hệ thống của istio/kube)
# ==============================================================================
echo ""
echo "[1/2] Copying ConfigMaps..."

CONFIGMAPS=(
    "backoffice-bff-extra-configmap"
    "cart-application-configmap"
    "customer-application-configmap"
    "media-application-configmap"
    "order-application-configmap"
    "product-application-configmap"
    "sampledata-application-configmap"
    "search-application-configmap"
    "storefront-bff-configmap"
    "storefront-bff-extra-configmap"
    "yas-configuration-configmap"
    "yas-gateway-routes-config-configmap"
)

for CM in "${CONFIGMAPS[@]}"; do
    echo -n "  → ConfigMap/${CM}: "
    if kubectl get configmap "${CM}" -n "${SOURCE_NS}" &>/dev/null; then
        kubectl get configmap "${CM}" -n "${SOURCE_NS}" -o json \
            | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")' \
            | jq ".metadata.namespace = \"${TARGET_NS}\"" \
            | kubectl apply -f - -n "${TARGET_NS}" 2>&1 | grep -E "created|configured|unchanged"
    else
        echo "SKIP (not found in ${SOURCE_NS})"
    fi
done

# ==============================================================================
# 2. COPY TẤT CẢ SECRETS
# ==============================================================================
echo ""
echo "[2/2] Copying Secrets..."

SECRETS=(
    "yas-elasticsearch-credentials-secret"
    "yas-keycloak-credentials-secret"
    "yas-openai-api-key-secret"
    "yas-postgresql-credentials-secret"
    "yas-redis-credentials-secret"
)

for SECRET in "${SECRETS[@]}"; do
    echo -n "  → Secret/${SECRET}: "
    if kubectl get secret "${SECRET}" -n "${SOURCE_NS}" &>/dev/null; then
        kubectl get secret "${SECRET}" -n "${SOURCE_NS}" -o json \
            | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")' \
            | jq ".metadata.namespace = \"${TARGET_NS}\"" \
            | kubectl apply -f - -n "${TARGET_NS}" 2>&1 | grep -E "created|configured|unchanged"
    else
        echo "SKIP (not found in ${SOURCE_NS})"
    fi
done

echo ""
echo "=============================================="
echo "  ✅ Done! Verify with:"
echo "     kubectl get configmap,secret -n ${TARGET_NS}"
echo "=============================================="
