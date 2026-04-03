# Documentation Technique — Pipeline CI/CD Flask API

> **Projet :** API Flask conteneurisée  
> **Stack :** Python 3.11 · Docker · GitLab CI/CD  
> **Date :** Avril 2026

---

## Table des matières

1. [Vue d'ensemble de l'architecture](#1-vue-densemble-de-larchitecture)
2. [Dockerfile — Image de production](#2-dockerfile--image-de-production)
3. [Docker Compose — Orchestration locale](#3-docker-compose--orchestration-locale)
4. [Pipeline GitLab CI/CD](#4-pipeline-gitlab-cicd)
   - 4.1 [Structure des stages](#41-structure-des-stages)
   - 4.2 [Variables et cache](#42-variables-et-cache)
   - 4.3 [Template réutilisable `.python_setup`](#43-template-réutilisable-python_setup)
   - 4.4 [Stage `build`](#44-stage-build)
   - 4.5 [Stage `test`](#45-stage-test)
   - 4.6 [Stage `security`](#46-stage-security)
   - 4.7 [Stage `deploy`](#47-stage-deploy)
5. [Intégration des tests](#5-intégration-des-tests)
6. [Pratiques DevSecOps](#6-pratiques-devsecops)
7. [Justification des choix techniques](#7-justification-des-choix-techniques)
8. [Risques, limites et recommandations](#8-risques-limites-et-recommandations)

---

## 1. Vue d'ensemble de l'architecture

```
Commit Git (develop / main)
        │
        ▼
┌─────────────────────────────────────────────┐
│              Pipeline GitLab CI/CD          │
│                                             │
│  ┌────────┐  ┌──────┐  ┌──────────┐  ┌───────────┐ │
│  │ build  │→ │ test │→ │security  │→ │  deploy   │ │
│  └────────┘  └──────┘  └──────────┘  └───────────┘ │
│  (develop+main)        (develop+main) (main only)   │
└─────────────────────────────────────────────┘
        │
        ▼ (main uniquement)
┌─────────────────────┐
│  VM GitLab Runner   │
│  docker compose up  │
│  → flask-api:5000   │
└─────────────────────┘
```

Le pipeline couvre l'intégralité du cycle **Build → Test → Secure → Deploy** dans un flux entièrement automatisé. Les branches `develop` et `main` déclenchent les trois premiers stages ; seule `main` déclenche le déploiement, ce qui matérialise une frontière claire entre intégration continue et livraison continue.

---

## 2. Dockerfile — Image de production

### Ordre reconstruit et annoté

```dockerfile
# 1. Image de base minimaliste — réduit la surface d'attaque
FROM python:3.11-slim

# 2. Variables d'environnement Python
ENV PYTHONDONTWRITEBYTECODE=1   # Pas de .pyc → image plus propre
ENV PYTHONUNBUFFERED=1          # Logs en temps réel dans Docker

# 3. Répertoire de travail
WORKDIR /app

# 4-5. Installation des dépendances en couche isolée
#      (exploite le cache Docker si requirements.txt ne change pas)
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /app/requirements.txt

# 6. Création d'un utilisateur non-root dédié
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /usr/sbin/nologin appuser

# 7. Copie du code source applicatif
COPY app.py /app/app.py
COPY database.py /app/database.py
COPY models.sql /app/models.sql

# 8. Création du répertoire de données et attribution des droits
RUN mkdir -p /app/data \
    && chown -R appuser:appuser /app

# 9. Passage en utilisateur non-root
USER appuser

# 10. Exposition du port applicatif
EXPOSE 5000

# 11. Commande de démarrage
CMD ["python", "app.py"]
```

### Points clés

| Aspect | Décision | Bénéfice |
|---|---|---|
| Image de base | `python:3.11-slim` | ~150 Mo vs ~1 Go pour l'image standard |
| Ordre des layers | `requirements.txt` avant le code | Cache Docker préservé entre les commits |
| Utilisateur | `appuser` non-root, sans shell | Empêche l'escalade de privilèges en cas de RCE |
| Stockage | Volume dédié `/app/data` | Persistance des données SQLite entre redémarrages |

---

## 3. Docker Compose — Orchestration locale

### Fichier reconstruit

```yaml
services:
  api:
    image: flask-api:latest      # Image construite localement via le pipeline
    restart: unless-stopped      # Redémarrage automatique sauf arrêt explicite
    ports:
      - "5000:5000"              # Exposition sur le port standard Flask
    env_file:
      - .env                     # Secrets et configuration hors dépôt
    volumes:
      - sqlite_data:/app/data    # Persistance de la base SQLite

volumes:
  sqlite_data:                   # Volume nommé géré par Docker
```

### Points clés

- **`restart: unless-stopped`** : garantit la disponibilité après un redémarrage du serveur ou un crash applicatif, sans empêcher un arrêt volontaire de l'opérateur.
- **`env_file: .env`** : aucune valeur sensible (clés, mots de passe) n'est committée dans le dépôt. Le pipeline vérifie l'existence du fichier avant le démarrage et le crée depuis `.env.example` si absent.
- **Volume nommé `sqlite_data`** : le stockage SQLite est découplé du cycle de vie du conteneur. Les données survivent aux mises à jour (`docker compose down` puis `up`).
- L'image `flask-api:latest` est construite directement sur la VM par le stage `deploy`, ce qui évite un registry d'images externe.

---

## 4. Pipeline GitLab CI/CD

### 4.1 Structure des stages

```yaml
stages:
  - build       # Vérification syntaxique et compilation
  - test        # Tests unitaires automatisés
  - security    # Audit des dépendances
  - deploy      # Déploiement sur la VM
```

La progression est **séquentielle et bloquante** : un échec à n'importe quel stage arrête le pipeline. Aucun déploiement ne peut avoir lieu si les tests ou l'audit de sécurité échouent.

### 4.2 Variables et cache

```yaml
variables:
  PIP_CACHE_DIR: "$CI_PROJECT_DIR/.cache/pip"
  DB_PATH: "/tmp/app.db"
  APP_DIR: "/home/gitlab-runner/flask_api"

cache:
  paths:
    - .cache/pip
```

- **`PIP_CACHE_DIR`** : le cache pip est stocké dans le répertoire du projet, ce qui permet à GitLab CI de le conserver entre les jobs via la directive `cache`. Cela réduit significativement le temps d'installation des dépendances.
- **`DB_PATH`** : chemin de la base de données pour l'environnement de test. `/tmp` est éphémère et approprié pour les tests.
- **`APP_DIR`** : chemin de déploiement sur la VM, centralisé en variable pour faciliter la maintenance.

### 4.3 Template réutilisable `.python_setup`

```yaml
.python_setup:
  before_script:
    - rm -rf .venv
    - python3 -m venv .venv
    - source .venv/bin/activate
    - pip install -r requirements.txt
```

Ce bloc est un **job caché** (préfixé par `.`) utilisé comme template via `extends`. Il factorie la configuration de l'environnement virtuel Python, appliquée identiquement aux stages `build`, `test` et `security`. Cela garantit l'**isolation** (pas de pollution entre les jobs) et la **reproductibilité** (chaque job part d'un environnement propre).

### 4.4 Stage `build`

```yaml
build:
  stage: build
  extends: .python_setup
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - python -m py_compile app.py database.py
```

**Objectif :** valider que le code Python est syntaxiquement correct avant d'investir du temps dans les tests.

`py_compile` détecte les erreurs de syntaxe sans exécuter le code — c'est un filet de sécurité rapide et à coût quasi nul. Si un développeur commet accidentellement un fichier avec une erreur de syntaxe, le pipeline échoue immédiatement à ce stage plutôt qu'à un stage plus tardif.

### 4.5 Stage `test`

```yaml
unit_tests:
  stage: test
  extends: .python_setup
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - export PYTHONPATH="$CI_PROJECT_DIR"
    - pytest -q tests/test_api.py
```

**Objectif :** exécuter la suite de tests unitaires.

`PYTHONPATH` est explicitement défini pour que pytest puisse importer les modules applicatifs (`app.py`, `database.py`) sans erreur d'import. Le flag `-q` (quiet) produit une sortie concise dans les logs CI.

### 4.6 Stage `security`

```yaml
security_scan:
  stage: security
  extends: .python_setup
  rules:
    - if: '$CI_COMMIT_BRANCH == "develop"'
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - pip-audit -r requirements.txt --ignore-vuln GHSA-5239-wwwm-4pmq
```

**Objectif :** détecter les vulnérabilités connues dans les dépendances Python.

`pip-audit` interroge la base de données de vulnérabilités PyPI (basée sur OSV). L'option `--ignore-vuln GHSA-5239-wwwm-4pmq` exclut un avertissement spécifique, impliquant qu'une décision documentée a été prise concernant cette vulnérabilité (faux positif, risque accepté, ou non-applicable à ce contexte).

### 4.7 Stage `deploy`

```yaml
deploy:
  stage: deploy
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - |
      if [ ! -d "$APP_DIR/.git" ]; then
        git clone "$CI_REPOSITORY_URL" "$APP_DIR"
      fi
    - cd "$APP_DIR"
    - git checkout main && git pull origin main
    - |
      if [ ! -f .env ]; then
        cp .env.example .env
      fi
    - docker compose down || true
    - docker build --network=host -t flask-api:latest .
    - docker compose up -d
    - sleep 5
    - docker ps
    - docker logs $(docker ps -q --filter "name=api") || true
    - curl --fail http://localhost:5000/ || (echo "App non joignable" && exit 1)
```

**Objectif :** déployer l'application sur la VM GitLab Runner.

Le script est idempotent :
1. **Clone ou pull** : si le répertoire n'existe pas, il effectue un clone initial ; sinon, il met à jour via `git pull`.
2. **Création du `.env`** : si le fichier de configuration n'existe pas, il est créé depuis `.env.example` (protection contre une première installation incomplète).
3. **Rebuild et redémarrage** : `docker compose down` arrête les conteneurs existants (`|| true` évite un échec si aucun conteneur ne tourne), puis l'image est reconstruite et les services relancés.
4. **Vérification de santé** : après 5 secondes, un `curl --fail` sur le port 5000 valide que l'application répond correctement. En cas d'échec, le job est marqué en erreur et l'équipe est notifiée.

---

## 5. Intégration des tests

### Stratégie actuelle

| Type | Outil | Fichier | Stage |
|---|---|---|---|
| Syntaxe | `py_compile` | `app.py`, `database.py` | `build` |
| Unitaires / API | `pytest` | `tests/test_api.py` | `test` |
| Dépendances | `pip-audit` | `requirements.txt` | `security` |
| Smoke test | `curl` | endpoint `/` | `deploy` |

### Flux de validation

```
Code commité
     │
     ▼
Syntaxe valide ? ──Non──▶ Échec immédiat
     │ Oui
     ▼
Tests unitaires OK ? ──Non──▶ Échec, pas de déploiement
     │ Oui
     ▼
Pas de CVE critique ? ──Non──▶ Échec, pas de déploiement
     │ Oui
     ▼
Déploiement (main uniquement)
     │
     ▼
App répond sur :5000 ? ──Non──▶ Alerte, déploiement marqué en échec
     │ Oui
     ▼
Pipeline ✅ Succès
```

### Environnement de test isolé

Les tests s'exécutent avec `DB_PATH="/tmp/app.db"` dans un environnement virtuel recréé à chaque job. Cela garantit que les tests ne polluent pas la base de production et que les résultats sont reproductibles.

---

## 6. Pratiques DevSecOps

Le pipeline intègre la sécurité à chaque étape, selon le principe **"shift-left security"** :

### Sécurité dans le Dockerfile

- **Image `slim`** : surface d'attaque réduite (moins de packages système, moins de CVE potentiels).
- **Utilisateur non-root** : `appuser` sans shell interactif (`/usr/sbin/nologin`). Même en cas de compromission de l'application, l'attaquant ne peut pas obtenir un shell root.
- **Pas de secrets dans l'image** : la configuration est injectée via `.env` au runtime, jamais baked dans l'image.
- **`--no-cache-dir`** : réduit la taille de l'image et évite de stocker des packages inutiles.

### Sécurité dans le pipeline

- **Audit des dépendances (SCA)** : `pip-audit` est exécuté à chaque push sur `develop` et `main`, avant tout déploiement. Une vulnérabilité connue dans les dépendances bloque le pipeline.
- **Séparation des branches** : le déploiement est restreint à `main`. Le code doit passer par `develop` (et potentiellement une merge request avec revue) avant d'atteindre la production.
- **Validation post-déploiement** : le smoke test `curl` détecte immédiatement un démarrage raté, limitant la durée d'une éventuelle fenêtre d'indisponibilité.
- **Idempotence du déploiement** : les vérifications `if [ ! -d ... ]` et `if [ ! -f .env ]` évitent des états incohérents sur la VM.

### Gestion des secrets

- **`.env` exclu du dépôt** : créé depuis `.env.example` sur la VM, jamais commité.
- **Variables CI/CD** : les secrets GitLab (`$CI_REPOSITORY_URL`) sont gérés par la plateforme, pas hardcodés.

---

## 7. Justification des choix techniques

### Pourquoi Python venv plutôt que Docker pour les tests CI ?

Le template `.python_setup` utilise un environnement virtuel Python plutôt qu'un conteneur Docker. Ce choix est justifié par :
- La **simplicité** : pas besoin de Docker-in-Docker (DinD), source de complexité et de problèmes de sécurité.
- La **rapidité** : le cache pip réduit le temps d'installation des dépendances.
- La **cohérence** : les mêmes dépendances servent pour le build, les tests et l'audit.

### Pourquoi reconstruire l'image sur la VM lors du déploiement ?

`docker build` est exécuté directement sur la VM plutôt que de pousser vers un registry. Cette approche est adaptée à un environnement single-node et évite la complexité d'un registry (authentification, stockage, rotation d'images). En revanche, elle crée un couplage fort entre le runner et le serveur de production (voir §8).

### Pourquoi `unless-stopped` comme restart policy ?

C'est le meilleur compromis pour une API web : redémarrage automatique après un crash ou un reboot serveur, mais sans redémarrage en boucle si le conteneur est arrêté intentionnellement (maintenance, mise à jour).

### Pourquoi `sleep 5` avant le smoke test ?

Flask démarre en quelques millisecondes, mais la base de données peut nécessiter une initialisation. Un délai fixe de 5 secondes est pragmatique mais fragile (voir §8 pour une approche plus robuste).

---

## 8. Risques, limites et recommandations

### Risques identifiés

| # | Risque | Sévérité | Description |
|---|---|---|---|
| R1 | Couplage runner/production | Haute | Le GitLab Runner et le serveur de production sont la même VM. Un job CI malveillant ou défaillant peut impacter la production. |
| R2 | `sleep 5` fragile | Moyenne | Un délai fixe ne garantit pas que l'application est prête. Sur un serveur chargé, 5 secondes peuvent être insuffisantes. |
| R3 | Tag `latest` non traçable | Moyenne | L'image taguée `latest` ne permet pas de rollback vers une version précise. |
| R4 | Pas de tests d'intégration | Moyenne | Seuls des tests unitaires et un smoke test sont présents. Les interactions entre composants (API ↔ base de données) ne sont pas couvertes par un test dédié. |
| R5 | Création automatique du `.env` | Faible | Si `.env.example` contient des valeurs par défaut faibles ou des placeholders, la création automatique peut exposer l'application avec une configuration non sécurisée. |
| R6 | `docker compose down` sans sauvegarde | Faible | Le volume SQLite persiste, mais aucune sauvegarde n'est effectuée avant le déploiement. |

### Limites de l'architecture actuelle

- **Single point of failure** : la VM est à la fois runner CI et serveur de production. Une panne matérielle impacte simultanément le pipeline et l'application.
- **Pas de rollback automatisé** : en cas d'échec du smoke test, le pipeline est en erreur mais aucune procédure de retour arrière automatique n'est déclenchée.
- **Couverture de tests** : `test_api.py` est le seul fichier de tests référencé. La couverture réelle dépend du contenu de ce fichier, qui n'est pas inclus dans les artefacts fournis.
- **Pas de linting** : aucun outil de qualité de code (`flake8`, `black`, `mypy`) n'est présent dans le pipeline.

### Recommandations

#### Court terme (quick wins)

1. **Remplacer `sleep 5` par un healthcheck** : utiliser une boucle `until curl --silent http://localhost:5000/ ; do sleep 1 ; done` avec un timeout maximal, ou configurer un `healthcheck` dans le `docker-compose.yml`.

   ```yaml
   # docker-compose.yml
   healthcheck:
     test: ["CMD", "curl", "-f", "http://localhost:5000/"]
     interval: 5s
     timeout: 3s
     retries: 5
   ```

2. **Versionner les images Docker** : taguer avec `$CI_COMMIT_SHORT_SHA` en plus de `latest` pour permettre un rollback.

   ```yaml
   - docker build -t flask-api:$CI_COMMIT_SHORT_SHA -t flask-api:latest .
   ```

3. **Ajouter un stage de linting** : intégrer `flake8` ou `ruff` avant les tests pour détecter les problèmes de qualité de code.

4. **Alertes en cas d'échec du pipeline** : configurer les notifications GitLab (email, Slack) pour les échecs sur `main`.

#### Moyen terme

5. **Séparer runner et production** : dédier une VM au GitLab Runner et une autre à la production. Utiliser un registry Docker privé (GitLab Container Registry, inclus dans GitLab) pour transférer les images.

6. **Ajouter des tests d'intégration** : tester l'API contre une vraie base de données de test, validant les endpoints CRUD complets.

7. **Scan de l'image Docker** : intégrer `trivy` ou `grype` pour auditer les CVE dans l'image finale, pas seulement dans les dépendances Python.

   ```yaml
   image_scan:
     stage: security
     script:
       - trivy image --exit-code 1 --severity HIGH,CRITICAL flask-api:latest
   ```

8. **Backup avant déploiement** : ajouter une étape de sauvegarde du volume SQLite avant `docker compose down`.

#### Long terme

9. **Infrastructure as Code** : gérer la VM avec Terraform ou Ansible pour garantir la reproductibilité de l'environnement.

10. **Observabilité** : intégrer des métriques (Prometheus), des logs centralisés (Loki/ELK) et des alertes pour monitorer l'API en production au-delà du simple smoke test.

---

## Annexe — Récapitulatif des fichiers

| Fichier | Rôle | Déclencheur |
|---|---|---|
| `Dockerfile` | Définition de l'image de production | `docker build` dans le stage deploy |
| `docker-compose.yml` | Orchestration du service API | `docker compose up` dans le stage deploy |
| `.gitlab-ci.yml` | Définition du pipeline CI/CD | Push sur `develop` ou `main` |
| `requirements.txt` | Dépendances Python | Installées dans `.python_setup` |
| `.env` / `.env.example` | Configuration runtime | Créé sur la VM au premier déploiement |
| `tests/test_api.py` | Suite de tests unitaires | Stage `test` |

---
