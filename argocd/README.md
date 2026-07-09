# ArgoCD Multi-Source Setup Guide

## Cấu trúc thư mục

```
argocd/
  dev/
    apps.yaml             Tạo 14 Application cho namespace dev
  staging/
    apps.yaml             Tạo 14 Application cho namespace staging
```

## Cách apply

```bash
# Áp dụng cho namespace dev
kubectl apply -f argocd/dev/apps.yaml -n argocd

# Áp dụng cho namespace staging
kubectl apply -f argocd/staging/apps.yaml -n argocd
```
