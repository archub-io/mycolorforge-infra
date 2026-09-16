#!/bin/bash
# Script para executar pipelines Tekton manualmente
# Uso: ./run-pipeline.sh [backend|frontend] [branch]

set -e

PIPELINE_TYPE="${1:-backend}"
NAMESPACE="tekton-pipelines"

case "$PIPELINE_TYPE" in
  backend|api)
    BRANCH="${2:-main}"  # backend usa main
    echo "Executando pipeline BACKEND (branch: $BRANCH)..."
    cat << EOF | kubectl create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: manual-backend-
  namespace: $NAMESPACE
spec:
  pipelineRef:
    name: colorforge-backend-pipeline
  params:
    - name: git-url
      value: "https://github.com/archub-io/mycolorforge-service.git"
    - name: git-revision
      value: "$BRANCH"
    - name: image-name
      value: "ghcr.io/r7next/mycolorforge-api"
    - name: image-tag
      value: "manual-$(date +%Y%m%d-%H%M%S)"
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Gi
          storageClassName: local-path
    - name: go-cache
      emptyDir: {}  # Cache efêmero para builds manuais (evita conflito de PVCs)
    - name: trivy-cache
      emptyDir: {}
    - name: docker-credentials
      secret:
        secretName: harbor-registry-credentials
    - name: git-credentials
      secret:
        secretName: github-credentials
    - name: sonar-credentials
      secret:
        secretName: sonarqube-credentials
EOF
    ;;

  frontend|front)
    BRANCH="${2:-master}"  # frontend usa master
    echo "Executando pipeline FRONTEND (branch: $BRANCH)..."
    cat << EOF | kubectl create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: manual-frontend-
  namespace: $NAMESPACE
spec:
  pipelineRef:
    name: colorforge-frontend-pipeline
  params:
    - name: git-url
      value: "https://github.com/archub-io/mycolorforge-front.git"
    - name: git-revision
      value: "$BRANCH"
    - name: image-tag
      value: "manual-$(date +%Y%m%d-%H%M%S)"
    - name: skip-tls-verify
      value: "true"
    # Staging URLs
    - name: api-url
      value: "https://api.colorforge.local/api/v1"
    - name: app-url
      value: "https://colorforge.local"
    - name: storage-url
      value: "https://minio.colorforge.local/mycolorforge"
    - name: faro-enabled
      value: "false"
    # Skip security scans for manual builds
    - name: security-scan-enabled
      value: "false"
    - name: sonar-enabled
      value: "false"
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 4Gi
          storageClassName: local-path
    - name: node-cache
      persistentVolumeClaim:
        claimName: colorforge-npm-cache
    - name: trivy-cache
      persistentVolumeClaim:
        claimName: colorforge-trivy-cache
    - name: docker-credentials
      secret:
        secretName: harbor-registry-credentials
    - name: git-credentials
      secret:
        secretName: github-credentials
    - name: sonar-credentials
      secret:
        secretName: sonarqube-credentials
  taskRunTemplate:
    serviceAccountName: tekton-pipeline-sa
  timeouts:
    pipeline: "30m0s"
    tasks: "15m0s"
EOF
    ;;

  *)
    echo "Uso: $0 [backend|frontend] [branch]"
    echo ""
    echo "Exemplos:"
    echo "  $0 backend          # Roda backend na branch main"
    echo "  $0 frontend         # Roda frontend na branch master"
    echo "  $0 frontend develop # Roda frontend na branch develop"
    echo "  $0 api              # Alias para backend"
    echo "  $0 front            # Alias para frontend"
    exit 1
    ;;
esac

echo ""
echo "Pipeline iniciado! Acompanhe em:"
echo "  - Dashboard: https://tekton.local"
echo "  - CLI: kubectl get pipelinerun -n $NAMESPACE -w"
