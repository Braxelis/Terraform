# EC01.3 – Note de cadrage
## Projet : Ville Intelligente

---

## 1. Synthèse des décisions

| # | Décision | Choix retenu | Justification |
|---|----------|-------------|---------------|
| D1 | Style d'architecture | Monolithe modulaire en V1 (couches) | Compromis maintenabilité / coût ; microservices différés en V2 |
| D2 | Protocole IoT | MQTT (broker Mosquitto / AWS IoT Core) | Légèreté, faible bande passante, standard industriel capteurs |
| D3 | Authentification | JWT stateless (usagers) + OAuth2/SSO (agents) | Séparation des populations ; scalabilité stateless |
| D4 | Hébergement | Cloud AWS (ECS + RDS PostgreSQL) | On-premise exclu en V1 (coût/délai déploiement) |
| D5 | Conformité RGPD | Aucune donnée de localisation personnelle persistée sans consentement | Obligation légale ; données paiement déléguées au PSP |
| D6 | Frontend | React (Web) + PWA (Mobile) | Partage de code, offline partiel, déploiement simplifié |
| D7 | Cache | Redis (lecture disponibilité temps réel) | SLA ≤ 2 s sur consultation ; soulage PostgreSQL |

---

## 2. Diagramme de cas d'utilisation

> Légende couleur MoSCoW — Bleu : Must · Vert : Should · Amber : Reporting · Coral : Agent

```mermaid
graph LR
  Citoyen((Citoyen))
  Résident((Résident))
  Agent((Agent terrain))
  Municipal((Service municipal))

  UC1([Consulter disponibilité temps réel])
  UC2([Payer un ticket])
  UC3([Recevoir alerte fin de ticket])
  UC4([Gérer abonnement résident])
  UC5([Signaler anomalie capteur])
  UC6([Consulter alertes / incidents])
  UC7([Accéder aux tableaux de bord KPI])

  Citoyen --> UC1
  Citoyen --> UC2
  Citoyen --> UC3
  Résident --> UC4
  Agent --> UC5
  Agent --> UC6
  Municipal --> UC6
  Municipal --> UC7
```

---

## 3. Diagramme de séquence — Consultation + Paiement (flux principal)

```mermaid
sequenceDiagram
  actor Citoyen
  participant App as App Web/Mobile
  participant GW as API Gateway
  participant Park as ParkingService
  participant DB as PostgreSQL / PSP

  Citoyen->>App: 1. Recherche zone / parking
  App->>GW: 2. GET /zones?dispo=true
  GW->>Park: 3. queryDisponibilité()
  Park->>DB: 4. SELECT places WHERE libre
  DB-->>Park: 5. [places disponibles]
  Park-->>GW: 6. {zones, dispo, tarif}
  GW-->>App: 7. 200 OK — liste zones
  App-->>Citoyen: 8. Affiche carte + dispo

  Note over Citoyen,DB: — Flux paiement —

  Citoyen->>App: 9. Sélectionne place + durée
  App->>GW: 10. POST /tickets
  GW->>Park: 11. creerTicket(params)
  Park->>DB: 12. POST /paiement (PSP)
  DB-->>Park: 13. {paiement_ok, ref}
  Park->>DB: 14. INSERT ticket (PostgreSQL)
  Park-->>GW: 15. {ticket_id, expiration}
  GW-->>App: 16. 201 Created
  App-->>Citoyen: 17. Confirmation + QR

  Note over App,Park: Tâche async : alerte 15 min avant expiration
```

---

## 4. Diagramme de composants

```mermaid
graph TD
  subgraph Frontend
    FW[App Web - React]
    FM[App Mobile - PWA]
    FD[Dashboard Municipal]
  end

  subgraph API["API Layer"]
    GW[API Gateway - NestJS / REST]
  end

  subgraph Services["Services métier"]
    SP[ParkingService]
    ST[TicketService]
    SPay[PaymentService]
    SA[AlertService]
  end

  subgraph IoT["IoT Layer"]
    MB[MQTT Broker]
    IA[IoT Adapter]
  end

  subgraph Persistance
    PG[PostgreSQL - RDS]
    RD[Cache - Redis]
  end

  subgraph Externes["Systèmes externes"]
    PSP[PSP Paiement]
    NOTIF[SMS / Email]
    AUTH[Auth - OAuth2/JWT]
    CAPT[Capteurs IoT]
  end

  FW --> GW
  FM --> GW
  FD --> GW

  GW --> SP
  GW --> ST
  GW --> SPay
  GW --> SA

  SP --> MB
  ST --> PG
  SPay --> PSP
  SA --> NOTIF
  SP --> PG
  SP --> RD

  MB --> IA
  IA --> SP
  CAPT --> MB
  GW --> AUTH
```

---

## 5. Modèle de données (ERD)

```mermaid
erDiagram
  ZONE ||--o{ PARKING : contient
  PARKING ||--o{ PLACE : dispose
  PLACE ||--o{ CAPTEUR : surveille
  PLACE ||--o{ TICKET : occupe
  TICKET ||--|| PAIEMENT : genere
  UTILISATEUR ||--o{ TICKET : cree
  UTILISATEUR ||--o{ ABONNEMENT : souscrit
  ABONNEMENT ||--o{ PLACE : reserve

  ZONE {
    uuid id PK
    string nom
    string type
    string geojson_boundary
  }
  PARKING {
    uuid id PK
    uuid zone_id FK
    string nom
    int capacite_totale
    float tarif_horaire
  }
  PLACE {
    uuid id PK
    uuid parking_id FK
    string numero
    bool est_disponible
    timestamp maj_at
  }
  CAPTEUR {
    uuid id PK
    uuid place_id FK
    string device_id
    string statut
    timestamp derniere_mesure
  }
  TICKET {
    uuid id PK
    uuid place_id FK
    uuid utilisateur_id FK
    timestamp debut
    timestamp fin_prevue
    string statut
    float montant
  }
  PAIEMENT {
    uuid id PK
    uuid ticket_id FK
    string ref_psp
    string statut
    float montant
    timestamp paid_at
  }
  UTILISATEUR {
    uuid id PK
    string email
    string role
    timestamp created_at
  }
  ABONNEMENT {
    uuid id PK
    uuid utilisateur_id FK
    date debut
    date fin
    string type
  }
```

---

## 6. Tableau des tests TDD

> Couverture : 16 scénarios · 7 fonctionnalités · 4 types (Normal / Limite / Erreur / Performance)

| ID | Fonctionnalité | Type | Scénario | Données d'entrée | Résultat attendu | Critère ✓ (PASS) | Critère ✗ (FAIL) |
|----|---------------|------|----------|-----------------|-----------------|-----------------|-----------------|
| T01 | Consultation disponibilité | Normal | Zone existante avec places libres | zone_id valide, horodatage courant | HTTP 200 + liste places disponibles | ≥ 1 place retournée, statut libre | 200 vide ou erreur 5xx |
| T02 | Consultation disponibilité | Limite | Zone saturée (0 place libre) | zone_id avec capacité = 0 | HTTP 200 + tableau vide + flag "complet" | 200 + liste vide + flag saturé | Erreur 404 ou 5xx |
| T03 | Consultation disponibilité | Erreur | zone_id inexistant | zone_id = "xxx-invalide" | HTTP 404 + message d'erreur clair | 404 + body JSON `{error: "zone_not_found"}` | 500 ou réponse vide |
| T04 | Paiement ticket | Normal | Paiement CB valide, place libre | place_id dispo, durée 2h, carte valide | HTTP 201 + ticket créé + ref_psp | 201, ticket_id généré, statut = actif | Ticket créé sans paiement confirmé |
| T05 | Paiement ticket | Erreur | Refus PSP (carte refusée) | place_id dispo, carte refusée | HTTP 402 + aucun ticket créé | 402, aucune ligne en base | Ticket créé malgré refus PSP |
| T06 | Paiement ticket | Limite | Place déjà occupée au moment du paiement (race condition) | place_id non dispo | HTTP 409 + message "place_unavailable" | 409 + rollback paiement | Double occupation ou 500 |
| T07 | Alerte fin de ticket | Normal | Ticket expirant dans 15 min | ticket_id, fin_prevue = now + 15 min | SMS/email envoyé à l'utilisateur | Notification envoyée, log enregistré | Aucune notification ou doublon |
| T08 | Alerte fin de ticket | Limite | Ticket déjà clôturé avant alerte | ticket_id statut = clos | Aucune notification émise | 0 message envoyé | Notification émise sur ticket clos |
| T09 | Mise à jour capteur IoT | Normal | Capteur envoie statut "libre" | MQTT topic capteur/place_id, payload = `{libre}` | Place mise à jour en base < 1 s | est_disponible = true en BDD < 1 s | Place reste occupée ou délai > 5 s |
| T10 | Mise à jour capteur IoT | Erreur | Capteur envoie données corrompues | Payload malformé (JSON invalide) | Message ignoré, log d'anomalie créé | Erreur loggée, place inchangée | Exception non gérée / crash service |
| T11 | Gestion abonnement | Normal | Résident souscrit un abonnement mensuel | utilisateur_id, type = mensuel, place réservée | HTTP 201 + abonnement actif | 201, dates cohérentes, place réservée | Abonnement créé sans place associée |
| T12 | Gestion abonnement | Limite | Abonnement sur place déjà réservée | place_id déjà associée à un abonnement actif | HTTP 409 conflit | 409 + message explicite | Double réservation acceptée |
| T13 | Tableau de bord KPI | Normal | Agent municipal consulte taux d'occupation | zone_id, période = 7 derniers jours | HTTP 200 + taux occupation + recettes | 200, valeurs numériques cohérentes | Données vides ou incohérentes |
| T14 | Authentification | Erreur | Token JWT expiré ou invalide | Authorization: Bearer token_expiré | HTTP 401 Unauthorized | 401, aucune donnée retournée | Accès accordé malgré token invalide |
| T15 | Performance — disponibilité | Performance | 50 requêtes simultanées GET /zones | 50 users concurrents, charge normale | P95 ≤ 2 s, 0 erreur 5xx | P95 < 2 s, taux erreur < 0,1 % | P95 > 2 s ou ≥ 1 erreur 5xx |
| T16 | Performance — paiement | Performance | 20 paiements simultanés POST /tickets | 20 users concurrents, places différentes | 0 double occupation, P95 ≤ 3 s | Atomicité garantie, P95 < 3 s | Double occupation ou timeout |

---

## 7. Traçabilité bout-en-bout P1 → P3

| Élément P3 | Source P1 | Décision P2 |
|-----------|----------|------------|
| Cas d'usage (7 UC) | §4 Exigences fonctionnelles + §6 MoSCoW | D1 périmètre V1 |
| Séquence consultation/paiement | §8 Architecture logique + §10 Choix techno | D2 MQTT, D3 JWT, D5 RGPD |
| Composants (5 couches) | §8 Architecture + §9 Contraintes techniques | D1 couches, D6 React/PWA, D7 Redis |
| ERD (8 entités) | §3 Besoins + §5 Exigences NF (RGPD) | D5 données personnelles isolées |
| Tests T15/T16 | §5 SLA ≤ 2 s (NF) | D4 Cloud AWS + D7 Redis |
| Tests T04/T05/T06 | §4 Paiement (Must) | D5 PSP délégué, atomicité |
| Tests T09/T10 | §4 Capteurs IoT (Must) | D2 MQTT broker |

---

