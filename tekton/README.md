# Tekton CI Pipeline - MyColorForge

Este diretório contém a configuração completa do pipeline CI usando Tekton Pipelines.

## Arquitetura

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   GitHub Push   │────▶│   EventListener │────▶│   TriggerTemplate│
│   (Webhook)     │     │   (Tekton)      │     │   (PipelineRun)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                              ┌─────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Pipeline                                   │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────┐ │
│  │  Clone  │──▶│  Test   │──▶│  Build  │──▶│  Scan   │──▶│Push │ │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘   └─────┘ │
└─────────────────────────────────────────────────────────────────┘
                                                        │
                              ┌─────────────────────────┘
                              ▼
                        ┌─────────────────┐
                        │ Kustomize Update│───▶ ArgoCD Sync
                        │ (GitOps)        │
                        └─────────────────┘
```

## Estrutura de Diretórios

```
tekton/
├── tasks/                    # Tasks reutilizáveis
│   ├── git-clone.yaml        # Clone de repositório
│   ├── golang-build.yaml     # Build Go
│   ├── golang-test.yaml      # Testes Go
│   ├── nodejs-build.yaml     # Build Next.js
│   ├── kaniko-build.yaml     # Build de imagem OCI
│   └── kustomize-update.yaml # Atualização GitOps
├── pipelines/                # Definições de pipelines
│   ├── api-pipeline.yaml     # Pipeline do Go API
│   ├── frontend-pipeline.yaml# Pipeline do Next.js
│   └── database-migration-pipeline.yaml
├── triggers/                 # Configuração de webhooks
│   ├── event-listener.yaml   # EventListener + Ingress
│   ├── trigger-binding.yaml  # Bindings para diferentes eventos
│   ├── trigger-template.yaml # Template para push em main
│   ├── pr-template.yaml      # Template para Pull Requests
│   └── release-template.yaml # Template para releases (tags)
└── rbac/                     # Permissões e secrets
    ├── tekton-rbac.yaml      # ServiceAccounts, Roles
    ├── secrets.yaml          # Placeholders para secrets
    └── sealed-secrets-example.yaml # Exemplo com Sealed Secrets
```

## Pré-requisitos

### 1. Instalar Tekton Pipelines

```bash
# Tekton Pipelines
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Tekton Triggers
kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

# Tekton Interceptors (para GitHub webhooks)
kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

# Tekton Dashboard (opcional)
kubectl apply --filename https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
```

### 2. Configurar Harbor Registry

```bash
# Criar projeto no Harbor
# harbor.example.com → Projects → New Project → mycolorforge

# Criar robot account para CI
# harbor.example.com → Projects → mycolorforge → Robot Accounts → New Robot Account
# Permissões: push, pull
```

### 3. Configurar Secrets

```bash
# Opção 1: Criar secrets manualmente
kubectl create secret docker-registry harbor-credentials \
  --docker-server=harbor.example.com \
  --docker-username=robot\$mycolorforge \
  --docker-password=<TOKEN> \
  -n tekton-pipelines

kubectl create secret generic git-credentials \
  --from-literal=username=<GITHUB_USER> \
  --from-literal=password=<GITHUB_TOKEN> \
  -n tekton-pipelines

kubectl create secret generic github-webhook-secret \
  --from-literal=token=$(openssl rand -hex 20) \
  -n tekton-pipelines

# Opção 2: Usar Sealed Secrets (ver sealed-secrets-example.yaml)
```

## Deploy

### 1. Aplicar RBAC e Secrets

```bash
kubectl apply -f rbac/tekton-rbac.yaml
# Edite secrets.yaml com valores reais antes de aplicar
# OU use Sealed Secrets / External Secrets Operator
kubectl apply -f rbac/secrets.yaml
```

### 2. Aplicar Tasks

```bash
kubectl apply -f tasks/
```

### 3. Aplicar Pipelines

```bash
kubectl apply -f pipelines/
```

### 4. Aplicar Triggers

```bash
kubectl apply -f triggers/
```

### 5. Configurar Webhook no GitHub

1. Vá para Settings → Webhooks → Add webhook
2. Payload URL: `https://webhook.mycolorforge.com/`
3. Content type: `application/json`
4. Secret: (mesmo valor de github-webhook-secret)
5. Events: Push, Pull Request, Release

## Executar Pipeline Manualmente

```bash
# API Pipeline
tkn pipeline start mycolorforge-api-pipeline \
  --param git-url=https://github.com/your-org/mycolorforge.git \
  --param git-revision=main \
  --param image-tag=$(git rev-parse --short HEAD) \
  --workspace name=shared-workspace,volumeClaimTemplateFile=workspace-template.yaml \
  --workspace name=go-cache,claimName=go-cache-pvc \
  --workspace name=docker-credentials,secret=harbor-credentials \
  -n tekton-pipelines

# Frontend Pipeline
tkn pipeline start mycolorforge-frontend-pipeline \
  --param git-url=https://github.com/your-org/mycolorforge.git \
  --param git-revision=main \
  --param image-tag=$(git rev-parse --short HEAD) \
  --workspace name=shared-workspace,volumeClaimTemplateFile=workspace-template.yaml \
  --workspace name=node-cache,claimName=node-cache-pvc \
  --workspace name=docker-credentials,secret=harbor-credentials \
  -n tekton-pipelines
```

## Monitoramento

### Tekton Dashboard

```bash
kubectl port-forward -n tekton-pipelines svc/tekton-dashboard 9097:9097
# Acesse: http://localhost:9097
```

### CLI (tkn)

```bash
# Listar PipelineRuns
tkn pipelinerun list -n tekton-pipelines

# Ver logs de um PipelineRun
tkn pipelinerun logs mycolorforge-api-xyz -n tekton-pipelines -f

# Ver status
tkn pipelinerun describe mycolorforge-api-xyz -n tekton-pipelines
```

## Fluxo de Trabalho

### Push para main

1. Developer faz push para `main`
2. GitHub envia webhook para EventListener
3. CEL Interceptor filtra por `refs/heads/main`
4. TriggerTemplate cria PipelineRun para API e Frontend
5. Pipeline executa: clone → test → build → scan → push → update-manifests
6. Kustomize atualiza tag da imagem no overlay prod
7. ArgoCD detecta mudança e sincroniza

### Pull Request

1. Developer abre/atualiza PR
2. GitHub envia webhook
3. CEL Interceptor filtra por ação (opened, synchronize)
4. PR Template cria PipelineRun somente para CI (sem deploy)
5. Pipeline executa: clone → test → build
6. Status é reportado ao PR

### Release (tags v*)

1. Developer cria tag `v1.2.3`
2. GitHub envia webhook
3. CEL Interceptor extrai versão da tag
4. Release Template cria PipelineRuns com version tag
5. Imagens são tagueadas com versão semântica
6. Migrations são executadas
7. Deploy para produção via ArgoCD

## Troubleshooting

### Pipeline falhou no clone

```bash
# Verificar se git-credentials está correto
kubectl get secret git-credentials -n tekton-pipelines -o yaml

# Verificar logs do TaskRun
tkn taskrun logs <taskrun-name> -n tekton-pipelines
```

### Push para Harbor falhou

```bash
# Verificar credenciais
kubectl get secret harbor-credentials -n tekton-pipelines -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

# Testar login manualmente
docker login harbor.example.com
```

### Webhook não está sendo recebido

```bash
# Verificar EventListener está rodando
kubectl get eventlistener -n tekton-pipelines
kubectl get pods -l eventlistener=mycolorforge-listener -n tekton-pipelines

# Ver logs do EventListener
kubectl logs -l eventlistener=mycolorforge-listener -n tekton-pipelines -f
```

## Customização

### Adicionar nova Task

1. Crie arquivo em `tasks/nova-task.yaml`
2. Aplique: `kubectl apply -f tasks/nova-task.yaml`
3. Adicione ao Pipeline desejado

### Alterar thresholds de segurança

A analise de vulnerabilidades ja nao vive aqui. Havia tres copias do mesmo
`trivy-scan`, com o mesmo nome no mesmo namespace, e quem aplicasse por
ultimo ganhava. Passou a existir uma so, em
`archub-infra/ci-cd/tekton/tasks/trivy-scan.yaml`. Editar la:
```yaml
params:
  - name: severity
    value: "CRITICAL"  # Apenas críticos
  - name: exit-code
    value: "0"         # Não falhar (só alertar)
```

### Adicionar notificações Slack

Crie uma Task de notificação e adicione ao `finally` do Pipeline.

## kustomize-update: corridas entre runs

Os runs de todos os produtos escrevem no mesmo repo de infra e acabam fora de ordem. A Task `kustomize-update`:

- so escreve se o commit do run ainda e o HEAD de `main` na app (`git ls-remote`; o URL da app e o commit saem do
  checkout que a task `clone` deixou no workspace). Se ja ha um commit mais novo, salta com uma mensagem clara e
  termina com sucesso: o run desse commit escreve a sua propria imagem;
- se o push perde a corrida (non-fast-forward, cannot lock ref), faz `git pull --rebase` e repete, ate 5 vezes com
  espera curta, e volta a confirmar o HEAD da app antes de cada tentativa;
- um erro de push que nao e corrida falha logo.

Os parametros e os resultados da Task nao mudaram. Os testes correm o script do YAML num Alpine 3.19 (o mesmo BusyBox,
git e kustomize da Task) contra repos git descartaveis e nao tocam no cluster. Da raiz do repo, no Git Bash do Windows:

```bash
MSYS_NO_PATHCONV=1 podman run --rm -v "$(pwd -W):/repo:ro" docker.io/library/alpine:3.19 sh /repo/tekton/tests/kustomize-update/test.sh
```

Em Linux ou macOS, `-v "$PWD:/repo:ro"` e sem a variavel. `VERBOSE=1` mostra o log do step de cada caso.
