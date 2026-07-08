# ArgoCD Multi-Source Setup Guide

## Cấu trúc thư mục

```
argocd/
  dev/
    apps.yaml             Tạo 14 Application cho namespace dev
  staging/
    apps.yaml             Tạo 14 Application cho namespace staging
  copy-yas-resources.sh   Copy các ConfigMap và Secret từ namespace "yas" sang namespace khác
```

## Cách apply (chọn 1 trong 2)

### Option 1: kubectl apply (khuyến nghị)

```bash
# Áp dụng cho namespace dev
kubectl apply -f argocd/dev/apps.yaml -n argocd

# Áp dụng cho namespace staging
kubectl apply -f argocd/staging/apps.yaml -n argocd
```

### Option 2: ArgoCD Web UI (https://localhost:8080)

1. Vào **Applications** → **New App** → chọn **Edit as YAML**
2. Copy **từng section** trong file `apps.yaml` (ngăn cách bởi `---`)
3. Dán vào editor → **Save** → **Create**
4. Lặp lại cho từng service

### Sau khi tạo các application xong chạy file sh để copy configmap và secret sang namespace dev và staging 
Lưu ý: phải đang deploy sẵn namespace yas 
```bash
chmod +x argocd/copy-resources.sh
./argocd/copy-resources.sh yas dev
./argocd/copy-resources.sh yas staging
```