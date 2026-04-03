# Documentation Technique – Pipeline CI/CD UrbanHub Park

> Intégration et Déploiement Continus
> Projet : Ville Intelligente

---

## Table des matières

1. [Introduction et contexte](#1-introduction-et-contexte)
2. [Architecture du pipeline CI/CD](#2-architecture-du-pipeline-cicd)
3. [Justification des choix techniques](#3-justification-des-choix-techniques)
4. [Stratégie de test](#4-stratégie-de-test)
5. [Volet sécurité – DevSecOps](#5-volet-sécurité--devsecops)
6. [Limites, risques et recommandations](#6-limites-risques-et-recommandations)
7. [Conclusion](#7-conclusion)

---

## 1. Introduction et contexte

### 1.1 Contexte du projet

UrbanHub Park est le module de gestion du stationnement de la plateforme UrbanHub. Ce module est un service critique qui nécessite des déploiements fiables, reproductibles et sécurisés. Toute régression ou faille de sécurité peut impacter directement la disponibilité du service pour les usagers.

Dans ce contexte, la mise en place d'un pipeline CI/CD complet répond à trois impératifs :

- **Fiabilité** : chaque modification du code est automatiquement validée avant d'atteindre la production.
- **Reproductibilité** : l'environnement d'exécution est containerisé via Docker, garantissant un comportement identique en local, en staging et en production.
- **Sécurité** : les vulnérabilités sont détectées le plus tôt possible dans le cycle de développement (principe du *Shift Left*).

### 1.2 Stack technique

| Composant | Technologie |
|---|---|
| Langage applicatif | Node.js 20 |
| Containerisation | Docker 24.0 (multi-stage build) |
| Orchestration locale | Docker Compose v3.9 |
| Base de données | PostgreSQL 16 |
| Plateforme CI/CD | GitLab CI/CD |
| Registry d'images | GitLab Container Registry |
| Déploiement cible | Kubernetes (kubectl) |

---

## 2. Architecture du pipeline CI/CD

### 2.1 Vue d'ensemble

Le pipeline est défini dans le fichier `.gitlab-ci.yml` et se compose de **6 stages séquentiels** qui s'exécutent à chaque Merge Request, à chaque push sur la branche `main`, et à chaque tag Git.

```
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌──────────┐    ┌─────────┐    ┌─────────┐
│  lint   │ →  │  build  │ →  │  test   │ →  │ security │ →  │ package │ →  │ deploy  │
└─────────┘    └─────────┘    └─────────┘    └──────────┘    └─────────┘    └─────────┘
```

Un échec dans n'importe quel stage **bloque les stages suivants**, garantissant qu'aucune image non validée ne soit déployée.

### 2.2 Description détaillée de chaque stage

---

#### Stage 1 – `lint` : Analyse statique du code

Ce stage est le premier rempart qualité. Il s'exécute sur chaque Merge Request et sur `main`.

| Job | Image | Rôle |
|---|---|---|
| `lint:eslint` | `node:20-alpine` | Analyse statique du code JavaScript/TypeScript |
| `lint:dockerfile` | `hadolint/hadolint:latest-alpine` | Vérification des bonnes pratiques Dockerfile |
| `lint:yaml` | `cytopia/yamllint:latest` | Validation de la syntaxe YAML (`.gitlab-ci.yml`, `docker-compose.yml`) |

**Artefacts produits :**
- `reports/eslint-report.json` – rapport ESLint (conservé 7 jours)
- `reports/hadolint-report.json` – rapport Hadolint (conservé 7 jours)

Le job `lint:eslint` installe les dépendances via `npm ci` (installation déterministe basée sur le `package-lock.json`) avant d'exécuter l'analyse. Un cache GitLab est configuré sur `node_modules/` avec une clé basée sur le `package-lock.json` pour éviter de réinstaller les dépendances à chaque pipeline.

---

#### Stage 2 – `build` : Construction de l'image Docker

| Job | Image | Rôle |
|---|---|---|
| `build:docker` | `docker:24.0` + service `docker:24.0-dind` | Build et tag de l'image Docker |

Le build utilise **Docker-in-Docker (DinD)** avec le driver `overlay2` et TLS activé (`DOCKER_TLS_CERTDIR: "/certs"`) pour la sécurité.

Deux tags sont produits :
- `$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA` – tag immuable lié au commit (traçabilité)
- `$CI_REGISTRY_IMAGE:latest` – tag flottant pour les déploiements rapides

L'image est également enrichie de **labels OCI de traçabilité** : hash du commit, branche, ID du pipeline et de la job. Cela permet de retrouver l'origine exacte de n'importe quelle image en production.

L'image buildée est sérialisée en fichier `image.tar` et transmise aux stages suivants via les **artefacts GitLab** (durée de vie : 1 heure, suffisante pour le pipeline).

**Artefacts produits :**
- `image.tar` – image Docker sérialisée (conservée 1 heure)

---

#### Stage 3 – `test` : Tests automatisés

| Job | Image | Type de test |
|---|---|---|
| `test:unit` | `node:20-alpine` | Tests unitaires avec couverture de code |
| `test:api` | `node:20-alpine` + service `postgres:16-alpine` | Tests d'intégration API avec vraie base de données |
| `test:performance` | `grafana/k6:latest` | Tests de charge / performance |

Voir la section [4 – Stratégie de test](#4-stratégie-de-test) pour le détail.

---

#### Stage 4 – `security` : Scans DevSecOps

| Job | Outil | Catégorie |
|---|---|---|
| `security:sast:semgrep` | Semgrep | SAST (analyse statique de sécurité) |
| `security:sca:dependency-check` | OWASP Dependency-Check | SCA (analyse des dépendances) |
| `security:secrets:gitleaks` | Gitleaks | Détection de secrets |
| `security:container:trivy` | Trivy | Scan de l'image Docker |
| `security:config:docker-bench` | Docker Bench Security | Audit de configuration Docker |

Voir la section [5 – Volet sécurité DevSecOps](#5-volet-sécurité--devsecops) pour le détail.

---

#### Stage 5 – `package` : Publication dans le registry

| Job | Condition de déclenchement | Rôle |
|---|---|---|
| `package:push` | Push sur `main` ou tag Git | Push de l'image dans le GitLab Container Registry |

Ce stage n'est exécuté que lorsque le code est mergé sur la branche principale ou lors d'un tag de release. Les branches de feature et les Merge Request ne publient pas d'image, évitant ainsi de polluer le registry.

Lorsqu'un **tag Git** est posé (ex : `v1.2.0`), l'image est également taguée avec ce numéro de version, permettant de conserver un historique des releases.

---

#### Stage 6 – `deploy` : Déploiement

| Job | Environnement | Déclenchement | Type |
|---|---|---|---|
| `deploy:staging` | Staging | Push sur `main` | Automatique |
| `deploy:production` | Production | Push sur `main` ou tag | **Manuel** (gate humain) |

Le déploiement s'effectue via `kubectl set image` sur un cluster Kubernetes. Un `rollout status` avec timeout est lancé après chaque déploiement pour vérifier que le rollout s'est correctement déroulé et déclencher un rollback automatique en cas d'échec.

Le kubeconfig est stocké en base64 dans les variables GitLab masquées (`KUBECONFIG_STAGING`, `KUBECONFIG_PROD`) et décodé à la volée dans le job — il n'apparaît jamais en clair dans les logs ni dans le dépôt.

### 2.3 Règles de déclenchement

| Condition | Stages exécutés |
|---|---|
| Ouverture / mise à jour d'une Merge Request | `lint`, `build`, `test`, `security` |
| Push sur `main` | Tous les stages (deploy staging : auto, deploy prod : manuel) |
| Création d'un tag Git | Tous les stages (deploy prod : manuel) |

### 2.4 Mécanismes transverses

**Cache des dépendances Node.js** : un cache GitLab est configuré sur `node_modules/` avec une clé basée sur le hash du `package-lock.json`. Cela évite de relancer `npm ci` à chaque pipeline si les dépendances n'ont pas changé, réduisant la durée totale du pipeline.

**Artefacts inter-stages** : l'image Docker buildée au stage 2 est transmise aux stages `security` et `package` via un artefact `image.tar`. Cela garantit que **la même image** est testée, scannée et publiée — sans rebuild.

---

## 3. Justification des choix techniques

### 3.1 GitLab CI/CD

GitLab CI/CD a été retenu car il est **natif au dépôt** : le pipeline, le registry d'images, les environnements et les variables sont tous gérés dans la même plateforme. Cela simplifie l'administration et réduit les dépendances externes. Contrairement à Jenkins qui nécessite une infrastructure dédiée, ou à GitHub Actions qui implique un dépôt externalisé, GitLab CI offre une solution intégrée et cohérente avec le workflow DevOps.

### 3.2 Docker multi-stage build

Le Dockerfile utilise deux stages distincts :

- **Stage `builder`** : installe toutes les dépendances (y compris `devDependencies`) et compile l'application.
- **Stage `production`** : part d'une image Alpine fraîche, ne copie que les artefacts de build et les `node_modules` de production.

Cette approche réduit drastiquement la taille de l'image finale (pas d'outils de build, pas de sources TypeScript) et sa **surface d'attaque**. Les outils de compilation ne sont jamais présents dans l'image qui tourne en production.

### 3.3 Image de base `node:20-alpine`

Alpine Linux a été choisi comme base pour sa légèreté (~5 Mo vs ~900 Mo pour une image Debian). Moins de packages installés signifie moins de CVEs potentielles. La version LTS Node.js 20 garantit un support jusqu'en 2026.

Un `apk update && apk upgrade` est exécuté au build pour intégrer les derniers patches de sécurité disponibles au moment du build.

### 3.4 Trivy pour le scan d'image

Trivy (Aqua Security) a été préféré à Snyk ou Clair pour plusieurs raisons :
- **Sans serveur** : Trivy fonctionne en mode CLI standalone, sans infrastructure dédiée.
- **Bases CVE à jour** : il télécharge automatiquement les dernières bases de vulnérabilités.
- **Polyvalent** : il scanne images Docker, dépendances, fichiers IaC et secrets dans un seul outil.
- **Intégration GitLab native** : les rapports JSON sont directement lisibles par GitLab Security Dashboard.

Le seuil de blocage est fixé à `CRITICAL` et `HIGH` (`TRIVY_EXIT_CODE: "1"`). Les vulnérabilités `MEDIUM` et `LOW` sont remontées dans le rapport mais ne bloquent pas le pipeline, pour éviter de paralyser les livraisons sur des risques faibles.

### 3.5 Semgrep pour le SAST

Semgrep a été préféré à SonarQube (qui nécessite un serveur dédié) pour sa capacité à s'exécuter en mode **CI-first**, sans infrastructure persistante. Les règles `p/owasp-top-ten` et `p/nodejs` couvrent les vulnérabilités les plus critiques pour une application Node.js (injection, XSS, mauvaise gestion des secrets en mémoire, etc.).

### 3.6 OWASP Dependency-Check pour la SCA

L'analyse de la composition logicielle (Software Composition Analysis) permet de détecter les vulnérabilités connues dans les dépendances npm. OWASP Dependency-Check croise les dépendances du projet avec la base NVD (National Vulnerability Database) du NIST. Le seuil de blocage est fixé à un score CVSS ≥ 7 (vulnérabilités `HIGH` et `CRITICAL`).

### 3.7 Stratégie de déploiement staging → production

Le déploiement en staging est **automatique** à chaque merge sur `main` : cela garantit que la branche principale est toujours représentée en staging et que les tests de recette peuvent commencer immédiatement. Le déploiement en production est **manuel** : il requiert une validation humaine explicite, introduisant un point de contrôle qualité avant toute mise en production. Cette approche est un compromis entre vitesse de livraison et maîtrise du risque.

---

## 4. Stratégie de test

### 4.1 Tests unitaires (`test:unit`)

**Outil** : Jest (ou équivalent Node.js)
**Environnement** : `node:20-alpine`, sans service externe

Les tests unitaires vérifient le comportement isolé de chaque fonction et module, en mockant les dépendances externes (base de données, API tierces). Ils sont les plus rapides à exécuter et constituent le premier filet de sécurité du pipeline.

**Couverture de code** : le job génère un rapport de couverture au format **Cobertura** (compatible GitLab) et un rapport **lcov** pour les badges de couverture. La couverture est extraite par la regex `/Lines\s*:\s*(\d+\.?\d*)%/` et affichée directement dans l'interface GitLab et dans les Merge Requests.

**Artefacts produits :**
- `reports/junit.xml` – rapport JUnit (affiché dans l'onglet Tests de GitLab)
- `coverage/cobertura-coverage.xml` – couverture de code (affiché dans les Merge Requests)
- `coverage/` – rapport lcov complet

### 4.2 Tests d'intégration API (`test:api`)

**Outil** : Supertest (ou équivalent) + Jest
**Environnement** : `node:20-alpine` + service PostgreSQL 16 Alpine dédié au pipeline

Contrairement aux tests unitaires, les tests API s'exécutent contre une **vraie base de données PostgreSQL** provisionnée automatiquement comme service Docker dans le pipeline. Cela permet de tester les requêtes SQL, les migrations et le comportement réel des endpoints HTTP.

Les variables de connexion (`DB_HOST`, `DB_PORT`, etc.) sont injectées via les variables d'environnement du job. La base est initialisée via `npm run db:migrate` avant l'exécution des tests.

**Artefacts produits :**
- `reports/api-tests.xml` – rapport JUnit des tests API

### 4.3 Tests de performance (`test:performance`)

**Outil** : k6 (Grafana)
**Environnement** : `grafana/k6:latest`

Les tests de charge vérifient le comportement de l'application sous contrainte (temps de réponse, taux d'erreur, throughput). Ils sont configurés en `allow_failure: true` : un dépassement des seuils de performance ne bloque pas le pipeline mais est visible dans les rapports, permettant une analyse sans bloquer les livraisons.

Le script de test (`tests/performance/load-test.js`) définit des scénarios de montée en charge progressive, des pics de charge et des tests d'endurance.

**Artefacts produits :**
- `reports/k6-results.json` – métriques de performance détaillées

### 4.4 Synthèse de la couverture

| Type | Outil | Bloquant | Rapport |
|---|---|---|---|
| Unitaires | Jest | ✅ Oui | JUnit XML + Cobertura |
| API / Intégration | Supertest + Jest | ✅ Oui | JUnit XML |
| Performance | k6 | ⚠️ Non (allow_failure) | JSON |

---

## 5. Volet sécurité – DevSecOps

L'approche DevSecOps adoptée repose sur le principe du **Shift Left** : les contrôles de sécurité sont intégrés le plus tôt possible dans le cycle de développement, dès la Merge Request, plutôt qu'après le déploiement.

### 5.1 Outils de sécurité intégrés

#### SAST – Semgrep (`security:sast:semgrep`)

**Rôle** : analyser le code source à la recherche de patterns de vulnérabilités connues.

Règles appliquées :
- `p/owasp-top-ten` : couvre les 10 risques OWASP les plus critiques (injection, broken auth, XSS, SSRF, etc.)
- `p/nodejs` : règles spécifiques à l'écosystème Node.js

Le job génère un rapport JSON archivé 30 jours. En cas de détection, le pipeline bloque et le développeur doit corriger la vulnérabilité ou la marquer comme faux positif documenté.

#### SCA – OWASP Dependency-Check (`security:sca:dependency-check`)

**Rôle** : identifier les vulnérabilités connues (CVE) dans les dépendances npm du projet.

Le scan croise chaque dépendance avec la base NVD du NIST via une clé API (`NVD_API_KEY`). Le pipeline échoue si une vulnérabilité avec un score CVSS ≥ 7.0 est détectée. Un rapport HTML lisible par un humain et un rapport JSON pour intégration outillée sont produits.

#### Détection de secrets – Gitleaks (`security:secrets:gitleaks`)

**Rôle** : détecter les secrets (clés API, mots de passe, tokens) accidentellement committés dans le code source.

Gitleaks analyse l'intégralité de l'historique Git du dépôt. Si un secret est détecté, le pipeline est bloqué immédiatement. Une configuration `.gitleaks.toml` permet de définir des exceptions pour les faux positifs (ex : clés de test factices).

#### Scan de l'image Docker – Trivy (`security:container:trivy`)

**Rôle** : détecter les CVEs dans les packages OS et les dépendances applicatives présents dans l'image Docker finale.

Trivy charge l'image depuis l'artefact `image.tar` produit au stage `build` — garantissant que c'est **exactement la même image** qui a été buildée qui est scannée. Un cache Trivy est configuré pour éviter de retélécharger les bases de vulnérabilités à chaque pipeline.

Politique de blocage :
- `CRITICAL` et `HIGH` → pipeline bloqué (`exit-code: 1`)
- `MEDIUM` et `LOW` → remontées dans le rapport, non bloquantes

#### Audit de configuration – Docker Bench Security (`security:config:docker-bench`)

**Rôle** : vérifier la conformité de la configuration Docker et du daemon aux recommandations du CIS Docker Benchmark.

Ce job est configuré en `allow_failure: true` car il nécessite des accès système qui peuvent ne pas être disponibles sur tous les runners. Il est non bloquant mais ses résultats sont archivés pour audit.

### 5.2 Sécurisation de l'image Docker

Au-delà des scans, la sécurité est intégrée directement dans la construction de l'image :

| Mesure | Implémentation | Justification |
|---|---|---|
| **Multi-stage build** | Stage `builder` + stage `production` | Élimine les outils de build de l'image finale |
| **Utilisateur non-root** | `USER appuser` (UID 1001) | Empêche l'escalade de privilèges si compromis |
| **Filesystem read-only** | `read_only: true` dans Compose | Empêche les écritures malveillantes sur le disque |
| **Suppression des capabilities** | `cap_drop: ALL` | Principe du moindre privilège au niveau kernel |
| **No new privileges** | `security_opt: no-new-privileges:true` | Empêche `setuid`/`setgid` dans le container |
| **Health check** | `HEALTHCHECK` dans Dockerfile | Détection automatique des instances défaillantes |
| **dumb-init** | `ENTRYPOINT ["dumb-init", "--"]` | Gestion correcte des signaux Unix (évite les zombies) |
| **Mise à jour des packages** | `apk update && apk upgrade` au build | Intègre les derniers patches de sécurité Alpine |

### 5.3 Gestion des secrets

Aucun secret n'est stocké dans le dépôt Git ni dans les fichiers de configuration versionnés. Tous les secrets sont injectés via les **variables CI/CD GitLab** (masked + protected) :

- `DB_PASSWORD` : mot de passe PostgreSQL
- `NVD_API_KEY` : clé API NIST pour OWASP Dependency-Check
- `KUBECONFIG_STAGING` / `KUBECONFIG_PROD` : accès Kubernetes, encodés en base64

Dans `docker-compose.yml`, la syntaxe `${DB_PASSWORD:?DB_PASSWORD is required}` garantit que Docker Compose **refuse de démarrer** si la variable n'est pas définie, évitant tout démarrage accidentel avec un mot de passe vide.

### 5.4 Politique globale de sécurité du pipeline

| Contrôle | Outil | Bloquant |
|---|---|---|
| Vulnérabilités code (SAST) | Semgrep | ✅ Oui |
| Vulnérabilités dépendances ≥ CVSS 7 | OWASP Dependency-Check | ✅ Oui |
| Secrets dans le code | Gitleaks | ✅ Oui |
| CVEs image CRITICAL/HIGH | Trivy | ✅ Oui |
| Mauvaises pratiques Dockerfile | Hadolint | ✅ Oui (seuil: warning) |
| Audit config Docker | Docker Bench Security | ⚠️ Non (allow_failure) |
| CVEs image MEDIUM/LOW | Trivy | ⚠️ Non (rapport uniquement) |

---

## 6. Limites, risques et recommandations

### 6.1 Limites de la solution actuelle

**Absence de DAST (Dynamic Application Security Testing)** : le pipeline ne comporte pas de tests de sécurité dynamiques (ex : OWASP ZAP) qui analyseraient l'application en cours d'exécution. Le DAST nécessite un environnement déployé et est donc plus complexe à intégrer dans le pipeline. Il est recommandé de l'ajouter en post-déploiement sur l'environnement staging.

**Tests de performance non bloquants** : les tests k6 sont configurés en `allow_failure: true`. Des régressions de performance pourraient passer inaperçues si les rapports ne sont pas consultés régulièrement. Il serait pertinent de définir des seuils précis (ex : p95 < 500ms) et de les rendre bloquants.

**Déploiement Kubernetes simplifié** : le déploiement utilise `kubectl set image`, qui ne gère pas les configurations avancées (Helm charts, gestion des ConfigMaps, rollback automatique sur métriques). Pour un projet mature, l'adoption de **Helm** ou **ArgoCD** serait recommandée.

**Pas de gestion des secrets avancée** : les secrets sont gérés via les variables GitLab CI/CD, ce qui est suffisant pour un projet de formation. En production réelle, un gestionnaire de secrets dédié comme **HashiCorp Vault** ou **AWS Secrets Manager** offrirait une rotation automatique et un audit d'accès.

**OWASP Dependency-Check potentiellement fragile** : le téléchargement de la base NVD peut échouer en cas de problème réseau ou de quota API. Cela constitue un risque si des vulnérabilités critiques dans les dépendances passent inaperçues. Une mise en cache locale de la base NVD serait recommandée.

### 6.2 Risques identifiés

| Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|
| Vulnérabilité dans une dépendance non détectée (NVD indisponible) | Faible | Élevé | Redondance avec Trivy qui scanne aussi les dépendances npm dans l'image |
| Secret commité puis supprimé (toujours dans l'historique Git) | Moyenne | Critique | Rotation immédiate du secret + `git filter-repo` pour expurger l'historique |
| Image de base Alpine avec CVE zero-day | Faible | Élevé | Rebuild hebdomadaire planifié + alertes Trivy automatiques |
| Compromission du GitLab Runner | Très faible | Critique | Isolation des runners, rotation des tokens d'enregistrement |
| Régression de performance non détectée | Moyenne | Moyen | Rendre les seuils k6 bloquants et configurer des alertes |

### 6.3 Recommandations pour la production

1. **Activer le DAST** : intégrer OWASP ZAP ou GitLab DAST en post-déploiement sur staging, avec un scan hebdomadaire automatique.

2. **Adopter Helm pour les déploiements** : remplacer `kubectl set image` par des Helm charts versionnés, permettant un historique de déploiement et un rollback en une commande.

3. **Mettre en place HashiCorp Vault** : centraliser la gestion des secrets avec rotation automatique, audit d'accès et intégration native avec Kubernetes.

4. **Configurer des alertes de sécurité** : connecter GitLab Security Dashboard à un outil de ticketing (Jira, GitLab Issues) pour créer automatiquement des tickets lors de la détection de nouvelles CVEs.

5. **Automatiser le rebuild des images** : programmer un pipeline hebdomadaire de rebuild pour intégrer les derniers patches Alpine, même sans modification du code source.

6. **Centraliser les rapports de sécurité** : agréger les rapports Trivy, Semgrep et OWASP Dependency-Check dans un outil dédié comme **DefectDojo** pour une vision consolidée de la posture de sécurité.

7. **Protéger les branches** : configurer des règles de protection sur `main` dans GitLab (approbation obligatoire de Merge Request, pipeline vert obligatoire, pas de push forcé).

### 6.4 Axes d'amélioration du pipeline

- Ajouter un **stage de notification** (Slack, email) en cas d'échec sur `main`.
- Intégrer **GitLab Environments** avec des métriques de monitoring (Prometheus/Grafana) pour visualiser l'état des déploiements.
- Mettre en place un **cache de registry** pour Trivy afin de ne pas dépendre d'internet lors des scans en pipeline.
- Envisager une **stratégie de déploiement blue/green** ou **canary** pour réduire le risque lors des mises en production.

---

## 7. Conclusion

Le pipeline CI/CD mis en place pour le module UrbanHub Park couvre l'ensemble du cycle de livraison logicielle, de l'analyse statique au déploiement en production, en passant par des tests multicouches et des scans de sécurité intégrés.

L'approche DevSecOps adoptée — avec cinq outils de sécurité complémentaires (Semgrep, OWASP Dependency-Check, Gitleaks, Trivy, Docker Bench Security) — garantit une détection précoce des vulnérabilités et limite le risque d'introduire des failles en production. La politique de blocage sur les vulnérabilités CRITICAL/HIGH assure que la sécurité n'est pas contournée au profit de la rapidité de livraison.

La distinction entre déploiement automatique en staging et déploiement manuel en production offre un équilibre entre agilité et maîtrise du risque opérationnel, conforme aux pratiques DevOps professionnelles.

Les limites identifiées — absence de DAST, gestion des secrets basique, tests de performance non bloquants — constituent des axes d'amélioration prioritaires pour une mise en production à grande échelle, et sont documentées pour permettre à l'équipe de les adresser dans les prochaines itérations.

---
