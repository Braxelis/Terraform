# EC03 – Guide CI/CD DevSecOps : Ville Intelligente

> Pipeline GitLab CI/CD complet, sécurisé et reproductible — compatible DevSecOps

---

## Table des matières

1. [Dockerfile](#1-dockerfile)
2. [docker-compose.yml](#2-docker-composeyml)
3. [.gitlab-ci.yml](#3-gitlab-ciyml)
4. [Exécution locale](#4-exécution-locale)
5. [Exécution sur GitLab CI/CD](#5-exécution-sur-gitlab-cicd)
6. [Variables d'environnement à configurer](#6-variables-denvironnement-à-configurer)
7. [Bonnes pratiques DevSecOps appliquées](#7-bonnes-pratiques-devsecops-appliquées)

---

## 1. Dockerfile

```dockerfile
# ─────────────────────────────────────────────
# Dockerfile – UrbanHub Park / Waste Module
# DevSecOps best practices :
#   - Multi-stage build (réduction de la surface d'attaque)
#   - Utilisateur non-root
#   - Image de base minimale (distroless / alpine)
#   - Aucun secret dans l'image
# ─────────────────────────────────────────────

# ── Stage 1 : Build ──────────────────────────
FROM node:20-alpine AS builder

# Métadonnées OCI
LABEL org.opencontainers.image.title="urbanhub-park" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.description="UrbanHub – Module Stationnement" \
      org.opencontainers.image.source="https://gitlab.example.com/urbanhub/park"

WORKDIR /app

# Copier uniquement les fichiers de dépendances en premier (cache layer)
COPY package*.json ./

# Installer les dépendances sans les devDependencies en production
RUN npm ci --only=production && npm cache clean --force

# Copier le reste du code source
COPY . .

# Build de l'application (si applicable, ex : TypeScript, Vite, etc.)
RUN npm run build --if-present

# ── Stage 2 : Production ─────────────────────
FROM node:20-alpine AS production

# Mise à jour des packages système pour corriger les CVEs
RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache dumb-init && \
    rm -rf /var/cache/apk/*

# Créer un utilisateur non-root dédié
RUN addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -s /bin/sh -D appuser

WORKDIR /app

# Copier uniquement les artefacts de build depuis le stage builder
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app/dist ./dist
COPY --from=builder --chown=appuser:appgroup /app/package.json ./

# Passer à l'utilisateur non-root
USER appuser

# Exposer uniquement le port nécessaire
EXPOSE 3000

# Health check intégré
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

# Point d'entrée avec dumb-init pour une gestion correcte des signaux
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/index.js"]
```

---

## 2. docker-compose.yml

```yaml
# ─────────────────────────────────────────────
# docker-compose.yml – UrbanHub Park / Waste
# Environnement local de développement et de test
# DevSecOps best practices :
#   - Isolation réseau
#   - Secrets via variables d'environnement (pas en clair)
#   - Volumes nommés (pas de bind-mounts en prod)
#   - Ressources limitées
#   - Read-only filesystem
# ─────────────────────────────────────────────

version: "3.9"

services:

  # ── Application principale ──────────────────
  app:
    build:
      context: .
      dockerfile: Dockerfile
      target: production
    image: urbanhub-park:local
    container_name: urbanhub-park-app
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - PORT=3000
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_NAME=${DB_NAME:-urbanhub_park}
      - DB_USER=${DB_USER:-appuser}
      - DB_PASSWORD=${DB_PASSWORD:?DB_PASSWORD is required}
    networks:
      - backend
      - frontend
    depends_on:
      postgres:
        condition: service_healthy
    # Lecture seule du filesystem + tmpfs pour les writes nécessaires
    read_only: true
    tmpfs:
      - /tmp
    # Limites de ressources
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          memory: 128M
    # Supprimer toutes les capabilities Linux non nécessaires
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

  # ── Base de données PostgreSQL ──────────────
  postgres:
    image: postgres:16-alpine
    container_name: urbanhub-park-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${DB_NAME:-urbanhub_park}
      - POSTGRES_USER=${DB_USER:-appuser}
      - POSTGRES_PASSWORD=${DB_PASSWORD:?DB_PASSWORD is required}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d:ro
    networks:
      - backend
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-appuser} -d ${DB_NAME:-urbanhub_park}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ── Tests d'intégration (service éphémère) ──
  test-runner:
    build:
      context: .
      dockerfile: Dockerfile
      target: builder
    container_name: urbanhub-park-tests
    command: npm run test:integration
    environment:
      - NODE_ENV=test
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_NAME=${DB_NAME:-urbanhub_park}
      - DB_USER=${DB_USER:-appuser}
      - DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - backend
    profiles:
      - test

networks:
  backend:
    driver: bridge
    internal: true   # Pas d'accès internet direct depuis le backend
  frontend:
    driver: bridge

volumes:
  postgres_data:
    driver: local
```

---

## 3. .gitlab-ci.yml

```yaml
# ─────────────────────────────────────────────
# .gitlab-ci.yml – UrbanHub Park / Waste
# Pipeline CI/CD complet et sécurisé
#
# Stages :
#   1. lint       – Analyse statique du code
#   2. build      – Build Docker
#   3. test       – Tests unitaires, API, non fonctionnels
#   4. security   – Scans DevSecOps (SAST, DAST, SCA, secrets)
#   5. package    – Push image vers registry
#   6. deploy     – Déploiement (staging → prod avec gate manuel)
#
# DevSecOps best practices :
#   - GitLab Auto DevOps templates
#   - Trivy pour le scan de vulnérabilités d'image
#   - Semgrep pour SAST
#   - GitLeaks pour la détection de secrets
#   - OWASP Dependency-Check pour SCA
#   - Règles de protection des branches
# ─────────────────────────────────────────────

image: docker:24.0

variables:
  # Image Docker
  IMAGE_NAME: $CI_REGISTRY_IMAGE
  IMAGE_TAG: $CI_COMMIT_SHORT_SHA
  IMAGE_LATEST: $CI_REGISTRY_IMAGE:latest
  IMAGE_VERSIONED: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA

  # Docker-in-Docker
  DOCKER_DRIVER: overlay2
  DOCKER_TLS_CERTDIR: "/certs"

  # Trivy (scan de vulnérabilités)
  TRIVY_CACHE_DIR: .trivycache/
  TRIVY_SEVERITY: "CRITICAL,HIGH"
  TRIVY_EXIT_CODE: "1"           # Fait échouer le pipeline si CRITICAL/HIGH

  # Configuration générale
  FF_USE_FASTZIP: "true"

stages:
  - lint
  - build
  - test
  - security
  - package
  - deploy

# ── Cache global ─────────────────────────────
.node_cache: &node_cache
  cache:
    key:
      files:
        - package-lock.json
    paths:
      - node_modules/
    policy: pull-push

# ── Règles de déclenchement communes ─────────
.rules_mr_and_main: &rules_mr_and_main
  rules:
    - if: $CI_MERGE_REQUEST_IID
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_COMMIT_TAG

# ═══════════════════════════════════════════
# STAGE 1 — LINT (Analyse statique)
# ═══════════════════════════════════════════

lint:eslint:
  stage: lint
  image: node:20-alpine
  <<: *node_cache
  <<: *rules_mr_and_main
  before_script:
    - npm ci
  script:
    - npm run lint
    - npm run lint:report || true
  artifacts:
    when: always
    paths:
      - reports/eslint-report.json
    expire_in: 7 days

lint:dockerfile:
  stage: lint
  image: hadolint/hadolint:latest-alpine
  <<: *rules_mr_and_main
  script:
    - hadolint --failure-threshold warning Dockerfile
    - hadolint -f json Dockerfile > reports/hadolint-report.json || true
  artifacts:
    when: always
    paths:
      - reports/hadolint-report.json
    expire_in: 7 days

lint:yaml:
  stage: lint
  image: cytopia/yamllint:latest
  <<: *rules_mr_and_main
  script:
    - yamllint .gitlab-ci.yml docker-compose.yml

# ═══════════════════════════════════════════
# STAGE 2 — BUILD
# ═══════════════════════════════════════════

build:docker:
  stage: build
  services:
    - docker:24.0-dind
  <<: *rules_mr_and_main
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    # Build avec labels de traçabilité
    - |
      docker build \
        --label "git.commit=$CI_COMMIT_SHA" \
        --label "git.branch=$CI_COMMIT_BRANCH" \
        --label "ci.pipeline=$CI_PIPELINE_ID" \
        --label "ci.job=$CI_JOB_ID" \
        --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --build-arg VCS_REF=$CI_COMMIT_SHA \
        --cache-from $IMAGE_LATEST \
        -t $IMAGE_VERSIONED \
        -t $IMAGE_LATEST \
        .
    # Sauvegarder l'image pour les stages suivants
    - docker save $IMAGE_VERSIONED > image.tar
  artifacts:
    paths:
      - image.tar
    expire_in: 1 hour

# ═══════════════════════════════════════════
# STAGE 3 — TESTS
# ═══════════════════════════════════════════

test:unit:
  stage: test
  image: node:20-alpine
  <<: *node_cache
  <<: *rules_mr_and_main
  before_script:
    - npm ci
  script:
    - npm run test:unit -- --coverage --coverageReporters=cobertura --coverageReporters=lcov
  coverage: '/Lines\s*:\s*(\d+\.?\d*)%/'
  artifacts:
    when: always
    reports:
      junit: reports/junit.xml
      coverage_report:
        coverage_format: cobertura
        path: coverage/cobertura-coverage.xml
    paths:
      - coverage/
    expire_in: 7 days

test:api:
  stage: test
  image: node:20-alpine
  services:
    - name: postgres:16-alpine
      alias: postgres
  <<: *node_cache
  <<: *rules_mr_and_main
  variables:
    POSTGRES_DB: urbanhub_test
    POSTGRES_USER: testuser
    POSTGRES_PASSWORD: testpassword
    NODE_ENV: test
    DB_HOST: postgres
    DB_PORT: "5432"
    DB_NAME: urbanhub_test
    DB_USER: testuser
    DB_PASSWORD: testpassword
  before_script:
    - npm ci
    - npm run db:migrate || true
  script:
    - npm run test:api
  artifacts:
    when: always
    reports:
      junit: reports/api-tests.xml
    expire_in: 7 days

test:performance:
  stage: test
  image: grafana/k6:latest
  <<: *rules_mr_and_main
  allow_failure: true   # Non bloquant mais visible dans le rapport
  script:
    - k6 run --out json=reports/k6-results.json tests/performance/load-test.js
  artifacts:
    when: always
    paths:
      - reports/k6-results.json
    expire_in: 7 days

# ═══════════════════════════════════════════
# STAGE 4 — SECURITY (DevSecOps)
# ═══════════════════════════════════════════

# ── 4a. SAST – Analyse statique de sécurité ──
security:sast:semgrep:
  stage: security
  image: returntocorp/semgrep:latest
  <<: *rules_mr_and_main
  script:
    - mkdir -p reports
    - |
      semgrep \
        --config=auto \
        --config=p/owasp-top-ten \
        --config=p/nodejs \
        --json \
        --output=reports/semgrep-report.json \
        . || true
    - semgrep --config=auto --config=p/owasp-top-ten . --error
  artifacts:
    when: always
    paths:
      - reports/semgrep-report.json
    expire_in: 30 days

# ── 4b. SCA – Scan des dépendances (OWASP) ───
security:sca:dependency-check:
  stage: security
  image: owasp/dependency-check:latest
  <<: *rules_mr_and_main
  allow_failure: true
  script:
    - |
      /usr/share/dependency-check/bin/dependency-check.sh \
        --project "UrbanHub-Park" \
        --scan . \
        --out reports/ \
        --format JSON \
        --format HTML \
        --failOnCVSS 7 \
        --nvdApiKey $NVD_API_KEY
  artifacts:
    when: always
    paths:
      - reports/dependency-check-report.*
    expire_in: 30 days

# ── 4c. Détection de secrets ──────────────────
security:secrets:gitleaks:
  stage: security
  image: zricethezav/gitleaks:latest
  <<: *rules_mr_and_main
  script:
    - mkdir -p reports
    - gitleaks detect --source . --report-path reports/gitleaks-report.json --report-format json
  artifacts:
    when: always
    paths:
      - reports/gitleaks-report.json
    expire_in: 30 days

# ── 4d. Scan de l'image Docker (Trivy) ───────
security:container:trivy:
  stage: security
  image: aquasec/trivy:latest
  <<: *rules_mr_and_main
  dependencies:
    - build:docker
  before_script:
    - docker load < image.tar
  script:
    - mkdir -p reports .trivycache
    # Scan en mode table pour les logs CI
    - |
      trivy image \
        --cache-dir $TRIVY_CACHE_DIR \
        --severity $TRIVY_SEVERITY \
        --exit-code $TRIVY_EXIT_CODE \
        --format table \
        $IMAGE_VERSIONED
    # Rapport JSON pour archivage
    - |
      trivy image \
        --cache-dir $TRIVY_CACHE_DIR \
        --severity $TRIVY_SEVERITY \
        --format json \
        --output reports/trivy-report.json \
        $IMAGE_VERSIONED || true
  cache:
    paths:
      - .trivycache/
  artifacts:
    when: always
    paths:
      - reports/trivy-report.json
    expire_in: 30 days

# ── 4e. Scan de la configuration Docker ──────
security:config:docker-bench:
  stage: security
  image: docker:24.0
  services:
    - docker:24.0-dind
  <<: *rules_mr_and_main
  allow_failure: true
  script:
    - docker run --rm --net host --pid host --userns host --cap-add audit_control
        -v /etc:/etc:ro
        -v /usr/bin/containerd:/usr/bin/containerd:ro
        -v /var/lib:/var/lib:ro
        -v /var/run/docker.sock:/var/run/docker.sock:ro
        --label docker_bench_security
        docker/docker-bench-security 2>/dev/null | tee reports/docker-bench.txt || true
  artifacts:
    when: always
    paths:
      - reports/docker-bench.txt
    expire_in: 30 days

# ═══════════════════════════════════════════
# STAGE 5 — PACKAGE (Push vers registry)
# ═══════════════════════════════════════════

package:push:
  stage: package
  services:
    - docker:24.0-dind
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_COMMIT_TAG
  dependencies:
    - build:docker
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker load < image.tar
  script:
    - docker push $IMAGE_VERSIONED
    - docker push $IMAGE_LATEST
    # Tag avec le numéro de version si c'est un tag git
    - |
      if [ -n "$CI_COMMIT_TAG" ]; then
        docker tag $IMAGE_VERSIONED $CI_REGISTRY_IMAGE:$CI_COMMIT_TAG
        docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_TAG
      fi
  environment:
    name: registry
    url: $CI_REGISTRY

# ═══════════════════════════════════════════
# STAGE 6 — DEPLOY
# ═══════════════════════════════════════════

# ── 6a. Déploiement automatique en Staging ───
deploy:staging:
  stage: deploy
  image: alpine/k8s:1.28.0   # ou image avec kubectl/helm
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  environment:
    name: staging
    url: https://staging.urbanhub.example.com
  before_script:
    - echo "$KUBECONFIG_STAGING" | base64 -d > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
  script:
    - |
      kubectl set image deployment/urbanhub-park \
        app=$IMAGE_VERSIONED \
        -n staging \
        --record
    - kubectl rollout status deployment/urbanhub-park -n staging --timeout=120s

# ── 6b. Déploiement manuel en Production ─────
deploy:production:
  stage: deploy
  image: alpine/k8s:1.28.0
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual   # Gate manuel obligatoire
    - if: $CI_COMMIT_TAG
      when: manual
  environment:
    name: production
    url: https://urbanhub.example.com
  before_script:
    - echo "$KUBECONFIG_PROD" | base64 -d > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
  script:
    - |
      kubectl set image deployment/urbanhub-park \
        app=$IMAGE_VERSIONED \
        -n production \
        --record
    - kubectl rollout status deployment/urbanhub-park -n production --timeout=180s
  when: manual
```

---

## 4. Exécution locale

### Prérequis

- Docker ≥ 24.0
- Docker Compose ≥ 2.20
- Node.js ≥ 20 (pour les tests en dehors de Docker)

### 4.1 – Construire et démarrer l'application

```bash
# 1. Copier et remplir le fichier de variables d'environnement
cp .env.example .env
# Éditer .env et définir DB_PASSWORD, etc.

# 2. Build de l'image
docker compose build

# 3. Démarrer l'application + la base de données
docker compose up -d

# 4. Vérifier l'état des services
docker compose ps
docker compose logs -f app
```

### 4.2 – Exécuter les tests localement

```bash
# Lancer les tests d'intégration (profil "test")
docker compose --profile test run --rm test-runner

# Ou directement avec Node (hors Docker)
npm ci
npm run test:unit
npm run test:api
```

### 4.3 – Lancer les scans de sécurité localement

```bash
# Scan Trivy de l'image locale
docker pull aquasec/trivy:latest
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $HOME/.cache/trivy:/root/.cache/trivy \
  aquasec/trivy:latest image \
  --severity CRITICAL,HIGH \
  urbanhub-park:local

# Détection de secrets avec Gitleaks
docker run --rm \
  -v $(pwd):/path \
  zricethezav/gitleaks:latest detect \
  --source /path \
  --report-format json \
  --report-path /path/reports/gitleaks-report.json

# SAST avec Semgrep
docker run --rm \
  -v $(pwd):/src \
  returntocorp/semgrep:latest \
  semgrep --config=auto --config=p/owasp-top-ten /src
```

### 4.4 – Arrêter l'environnement

```bash
# Arrêter les services
docker compose down

# Arrêter ET supprimer les volumes (reset complet)
docker compose down -v
```

---

## 5. Exécution sur GitLab CI/CD

### 5.1 – Structure de dossiers recommandée

```
urbanhub-park/
├── .gitlab-ci.yml
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── .gitleaks.toml          # Config Gitleaks (exceptions)
├── .semgrepignore          # Fichiers à exclure du SAST
├── .hadolint.yaml          # Config Hadolint
├── package.json
├── src/
├── tests/
│   ├── unit/
│   ├── api/
│   └── performance/
│       └── load-test.js
├── db/
│   └── init/
│       └── 01-schema.sql
└── reports/               # Généré automatiquement par le pipeline
```

### 5.2 – Activer GitLab CI/CD

1. Pousser les fichiers sur votre dépôt GitLab :
   ```bash
   git add .gitlab-ci.yml Dockerfile docker-compose.yml
   git commit -m "feat: add CI/CD pipeline with DevSecOps"
   git push origin main
   ```

2. Dans GitLab, aller dans **CI/CD > Pipelines** pour visualiser l'exécution.

### 5.3 – Configurer les GitLab Runners

```bash
# Installer un GitLab Runner (Linux)
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install gitlab-runner

# Enregistrer le runner avec Docker executor
sudo gitlab-runner register \
  --url https://gitlab.example.com \
  --registration-token <TOKEN> \
  --executor docker \
  --docker-image docker:24.0 \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
  --description "urbanhub-docker-runner"
```

> ⚠️ Le montage de `/var/run/docker.sock` est pratique mais expose le daemon Docker. En production, préférer **Docker-in-Docker (DinD)** avec TLS ou un runner Kubernetes.

---

## 6. Variables d'environnement à configurer

À définir dans **GitLab > Settings > CI/CD > Variables** :

| Variable | Type | Description |
|---|---|---|
| `CI_REGISTRY_USER` | Auto | Fourni par GitLab automatiquement |
| `CI_REGISTRY_PASSWORD` | Auto | Fourni par GitLab automatiquement |
| `DB_PASSWORD` | Secret (masked) | Mot de passe base de données |
| `DB_USER` | Variable | Utilisateur base de données |
| `DB_NAME` | Variable | Nom de la base de données |
| `NVD_API_KEY` | Secret (masked) | Clé API NIST NVD (OWASP Dependency-Check) |
| `KUBECONFIG_STAGING` | Secret (masked) | Kubeconfig staging encodé en base64 |
| `KUBECONFIG_PROD` | Secret (masked) | Kubeconfig production encodé en base64 |

Pour encoder un kubeconfig :
```bash
cat ~/.kube/config | base64 -w 0
```

---

## 7. Bonnes pratiques DevSecOps appliquées

### Sécurité de l'image (Shift Left)

| Pratique | Outil | Fichier |
|---|---|---|
| Multi-stage build | Docker | `Dockerfile` |
| Utilisateur non-root | Docker | `Dockerfile` |
| Lecture seule du filesystem | Docker | `docker-compose.yml` |
| Scan de vulnérabilités image | **Trivy** | `.gitlab-ci.yml` |
| Lint du Dockerfile | **Hadolint** | `.gitlab-ci.yml` |

### Sécurité du code (SAST / SCA)

| Pratique | Outil | Description |
|---|---|---|
| Analyse statique | **Semgrep** | Règles OWASP Top 10, NodeJS |
| Dépendances vulnérables | **OWASP Dependency-Check** | Corrélation CVE via NVD |
| Détection de secrets | **Gitleaks** | Empêche les commits de secrets |

### Pipeline

| Pratique | Description |
|---|---|
| Fail fast | Les scans CRITICAL/HIGH bloquent le pipeline |
| Artefacts de sécurité | Tous les rapports sont archivés 30 jours |
| Gate manuel | La production nécessite une validation humaine |
| Traçabilité | Labels Git sur chaque image Docker |
| Isolation réseau | Réseau `internal: true` pour le backend |

### Recommandations supplémentaires pour la production

- Activer **GitLab DAST** (Dynamic Application Security Testing) sur l'environnement staging.
- Utiliser **Vault HashiCorp** ou **GitLab Secrets Manager** pour la gestion des secrets.
- Mettre en place des **règles de protection de branches** (`main`, `release/*`).
- Configurer des **alertes Slack/email** en cas d'échec de stage `security`.
- Archiver les rapports dans un **tableau de bord de sécurité** (ex : DefectDojo).

---

CI-CD-Gitlab