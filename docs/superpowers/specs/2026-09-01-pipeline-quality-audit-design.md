# Audit qualité et exhaustivité du pipeline de collecte (chantier 4) — Design

**Date :** 2026-09-01
**Origine :** chantier 4, identifié dans `docs/PROJECT_STATUS.md` depuis le chantier 1 (repo-split) sous le titre « Audit qualité des pipelines », jamais spécifié jusqu'ici. Démarré à la demande explicite de l'utilisateur le 2026-09-01.

## Objectif

Répondre à trois questions concrètes sur le harvester, pas à un audit de code abstrait :
1. Le système rate-t-il des tenders réellement pertinents (faux négatifs) ?
2. Remonte-t-il des tenders non pertinents (faux positifs) ?
3. Pour chaque écart constaté, quelle en est la cause probable — bug de logique/config (corrigible indépendamment de la techno), limite architecturale, ou limite d'une techno mal adaptée (auquel cas le spike Scrapling déjà identifié en devient directement informé) ?

Ce chantier ne corrige rien lui-même (cf. Décision 6) — il produit un diagnostic priorisé et sourcé, sur lequel les corrections seront planifiées séparément après revue utilisateur.

## Décisions validées

### 1. Périmètre — multi-tenant, multi-pays, pas seulement Burkina Faso
Correction actée le 2026-09-01 : TenderAI n'est **pas** centré Burkina Faso, contrairement à des formulations résiduelles dans `tenderai-backend/CLAUDE.md` et `tender-ai/docs/PROJECT_STATUS.md`. Le staging a des sources configurées pour 2 pays au moment de l'écriture :

- **BF** (5 sources, toutes activées) : DGCMEF (`pdf_rag`), Joffres.net (`html-listing`), UNGM (`ungm`), UEMOA (`html-tender`), Enabel (`html-tender`).
- **CA** (16 sources, 7 activées / 9 désactivées) : Achats Canada, Ville de Montréal, Le Devoir, Nova Scotia, UNDP, Commonwealth, Palladium Group (activées) ; Bonfire Hub Canada, Public Procurement Belgium, Guinea Tenders, UNDP Africa, World Bank, NATO NSPA, BAD, OMD/WCO, AFD DGMarket (désactivées). Certaines de ces sources sont des organismes internationaux (UNDP, World Bank...) rattachés au tenant CA sans logique géographique apparente — traité comme un fait à vérifier, pas une anomalie présumée.

L'audit couvre les deux pays. Nettoyage doc (item de clôture, cf. Livrables) : vérification faite le 2026-09-01, la formulation fautive (« harvester for Burkina Faso ») ne vit en réalité que dans les deux fichiers `CLAUDE.md` racine — `/home/yulcom/web/tenderai/CLAUDE.md:7` et `/home/yulcom/web/tender-ai/CLAUDE.md:7` — pas dans `tenderai-backend/CLAUDE.md` (propre) ni dans `PROJECT_STATUS.md` (les occurrences BF y sont des références légitimes à l'un des deux pays actifs, pas un cadrage fautif). Corrigés dans ce chantier.

### 2. Méthode retenue — trace de bout en bout avec vérité terrain indépendante
Pour chaque source **activée** :
1. Identifier la ou les entreprises abonnées à cette source/pays et récupérer leurs critères de pertinence réels (mots-clés/prompt de classification tels que configurés en DB — pas un jugement à dire d'expert de l'agent).
2. Déclencher un run de collecte frais sur staging.
3. En parallèle (fenêtre temporelle serrée, pour éviter un décalage dû à des annonces publiées/retirées entre les deux mesures), parcourir manuellement le portail en direct (navigateur Chrome) et consigner chaque avis actuellement listé (titre, référence, échéance) comme vérité terrain horodatée.
4. Reconstituer, pour chaque avis de la vérité terrain, son parcours dans le pipeline via les logs par nœud (`logs/nodes/*.json`) et les tables DB (`notices`, stats de run) : présent après fetch ? après parse ? classé pertinent ? survit au dédoublonnage ? persisté ? livré ?
5. Pour tout avis de la vérité terrain absent du résultat final, localiser l'étage exact où il a disparu → cause racine (taxonomie ci-dessous).
6. Pour tout avis livré par le pipeline mais qui ne correspond pas clairement aux critères de l'entreprise, tracer pourquoi l'étage classification l'a laissé passer.

Alternatives envisagées, écartées comme méthode principale mais réutilisées en soutien :
- **Revue de code statique seule** (sélecteurs, prompts, seuils de dédoublonnage) : rapide, mais ne confirme rien empiriquement — reste un complément pour expliquer une cause une fois qu'un écart est confirmé, jamais la preuve initiale.
- **Analyse historique des runs déjà en DB** (recherche d'anomalies : source retombée à 0 résultats, chute brutale un jour donné) : peu coûteuse car les logs existent déjà, bonne pour détecter une régression dans le temps, mais ne dit rien des avis que le pipeline n'a jamais tenté de récupérer. Utilisée en soutien pour corroborer/dater un écart trouvé par la méthode principale, jamais seule.

### 3. Sources désactivées — passage allégé, pas de trace complète
Pour les 9 sources CA désactivées : vérifier la raison de désactivation (message de commit, `patterns`/config, ou absence totale de justification), un sanity-check que le `list_url` résout toujours, et si la désactivation reste justifiée ou constitue elle-même un angle mort de couverture. Pas de run de collecte déclenché pour ces sources (aucun sens à tracer un pipeline qui ne s'exécute pas).

### 4. Taxonomie des causes racines
Chaque écart constaté est classé dans une (ou plusieurs) de ces catégories, avec la sous-cause précise et la ligne de code/config concernée :

| Étage | Sous-causes typiques |
|---|---|
| Fetch | Pagination insuffisante (`max_pages`), blocage anti-bot/Cloudflare, sélecteur CSS cassé (redesign du site), rate limit trop agressif, `list_url` périmée |
| Parse | Échec d'extraction (PDF mal structuré pour `pdf_rag`, sélecteur de champ manquant) |
| Classify | Critères de pertinence mal configurés côté entreprise, prompt insuffisant, erreur de jugement du LLM |
| Dedup | Fusion à tort de deux avis distincts, ou échec à fusionner de vrais doublons (bruit, pas une perte) |
| Delivery | Bug de curseur/statut (cf. le bug Critical déjà trouvé et corrigé au chantier 3 — vérifier qu'il n'y a pas de régression ou de variante non couverte) |
| Config | Source désactivée sans raison valable, `enabled=false` oublié après un correctif |

Chaque finding porte une étiquette : **bug logique/config** (corrigible indépendamment de la techno), **limite architecturale**, ou **limite technologique** (la techno actuelle — Playwright nu, pas de stealth, sélecteurs statiques — n'est structurellement pas adaptée ; alimente directement le spike Scrapling déjà identifié).

### 5. Séquencement — diagnostic complet avant toute correction
Directive explicite de l'utilisateur (2026-09-01) : aucune correction n'est appliquée pendant ce chantier. Le rapport d'audit est livré et revu intégralement d'abord ; la planification des corrections (quelles priorités, quel repo, quel séquencement) fait l'objet d'un chantier/plan séparé, décidé avec l'utilisateur après lecture du rapport.

### 6. Environnement — staging uniquement
Comme tous les chantiers précédents : aucun run ni aucune requête sur la production sans autorisation explicite (jamais donnée à ce jour).

## Livrables

1. **Rapport d'audit** : `docs/audits/2026-09-01-pipeline-quality-audit-report.md` (nouveau dossier — ce n'est pas un design de build, donc pas rangé sous `specs/`). Une section par source activée (méthode appliquée, vérité terrain, écarts trouvés, causes racines, sévérité), une section courte par source désactivée, une synthèse priorisée globale (quels écarts sont les plus impactants, lesquels sont de simples bugs vs des limites structurelles).
2. **Nettoyage doc BF-centric** : correction de la phrase d'ouverture dans `/home/yulcom/web/tenderai/CLAUDE.md:7` et `/home/yulcom/web/tender-ai/CLAUDE.md:7` (cf. Décision 1) — item de clôture trivial, inclus dans ce chantier plutôt que laissé en tâche séparée.
3. `docs/PROJECT_STATUS.md` mis à jour avec le statut du chantier 4 et un pointeur vers le rapport.

## Hors scope

- Toute correction de bug trouvé (phase 2, planifiée séparément après revue).
- Ajout de nouvelles sources.
- Le spike Scrapling reste une tâche autonome distincte (voir `docs/PROJECT_STATUS.md`) — ce chantier l'alimente en constats concrets par source, il ne l'exécute pas.
- Décision de réactiver/désactiver des sources — signalé dans le rapport, pas exécuté ici.

## Critères de validation du rapport (tient lieu de « tests » pour un chantier de diagnostic)

- Chaque source activée a une vérité terrain indépendante collectée le même jour que le run de collecte tracé (pas de comparaison à des données historiques comme substitut).
- Chaque finding cite une preuve concrète (avis précis de la vérité terrain + entrée de log/DB correspondante), jamais une affirmation générale non sourcée.
- Chaque cause racine référence le fichier/la ligne de code ou le champ de config concerné.
- Chaque source désactivée a une raison documentée, vérifiée par rapport à l'état réel du système (pas supposée).
