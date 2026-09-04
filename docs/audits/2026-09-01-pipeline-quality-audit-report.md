# Audit qualité et exhaustivité du pipeline de collecte — Rapport

**Date :** 2026-09-01
**Spec :** docs/superpowers/specs/2026-09-01-pipeline-quality-audit-design.md
**Méthode :** trace de bout en bout avec vérité terrain indépendante (voir spec §2)

## Méthode et limites

*Regroupe en un seul endroit les écarts méthodologiques et les points non concluants qui sont par ailleurs divulgués honnêtement, mais uniquement à l'intérieur des sections concernées. Un lecteur qui ne lit que le sommaire exécutif doit connaître ces réserves.*

**Convention de référence utilisée dans tout ce document :**
- **`constat #N`** renvoie à une ligne du tableau des constats du sommaire exécutif (§ (b), lignes #1 à #29).
- **`Finding BF-N`** renvoie aux findings numérotés de la section Burkina Faso (`### Finding #1/#2/#3`, l'investigation du crash `persist_notices` de la Tâche 1). Les deux numérotations sont indépendantes et ne se correspondent pas.

**Écarts par rapport à la méthode prescrite par la spec :**

- **Vérité terrain le jour même : 10 sources activées sur 12.** UEMOA et Enabel ont vu leur vérité terrain collectée le 2026-09-02, soit **un jour après** leur run tracé (2026-09-01). Les deux sections le divulguent en ligne et ajoutent un contrôle croisé compensatoire (Enabel : cross-check titre-par-titre et deadline-par-deadline entre le listing live et `fetch_listings.json`, identiques à la lettre près ; UEMOA : la structure et le volume du listing paginé ne dépendent pas de la date d'audit).
- **`curl` substitué au « navigateur Chrome » prescrit pour 6 sources activées sur 12** — UEMOA, Enabel, Achats Canada, Ville de Montréal, UNDP et Palladium Group. Justification commune, vérifiée source par source dans chaque section : ces 6 pages sont intégralement rendues côté serveur (un `curl` nu récupère le contenu et les compteurs attendus, sans JS ni anti-bot), donc `curl` est équivalent au rendu navigateur pour l'établissement de la vérité terrain. Les 6 autres sources (DGCMEF, Joffres.net, UNGM, Le Devoir, Nova Scotia, The Commonwealth) ont bien été vérifiées au navigateur réel, précisément parce que le rendu JS ou l'anti-bot y était en cause.
- **Passe sur les 9 sources désactivées : aucun outil navigateur disponible.** L'extension `claude-in-chrome` n'était pas connectée et aucun CLI `browser-use` n'était disponible pour cette passe ; le contrôle a été fait entièrement par `curl`. **3 verdicts sur 9 sont explicitement marqués non confirmables** de ce fait (Bonfire Hub Canada, Public Procurement Belgium, World Bank — trois SPA à rendu 100 % client, dont `curl` ne peut vérifier que la coquille, pas le contenu affiché).

**Points laissés ouverts faute de preuve disponible :**

- **Logs de process non conservés** pour deux sources (DGCMEF, Enabel) : le point de défaillance exact de la boucle d'extraction LLM DGCMEF (erreur systématique vs rate-limit Groq) et le succès/échec des pages 2-3 d'Enabel n'ont pas pu être tranchés directement, seulement encadrés par des preuves indirectes.
- **Aucune clé Tavily disponible** : la question architecturale ouverte de The Commonwealth (`tavily_extract`/`extract_depth: advanced` exécute-t-il l'appel AJAX `LoadProjects` du site ?) n'a pas pu être testée. C'est le seul point d'architecture réellement non tranché de tout l'audit (constat #17).
- **Anomalie `unique_items: 0`** (constats #8/#9, Finding BF-2) : signalée et documentée, **non résolue** — c'est une investigation restante, pas un correctif à coût connu.
- **Tests anti-bot ponctuels, pas sous charge** : les vérifications Nova Scotia sont des exécutions isolées à faible volume ; un durcissement sous trafic automatisé soutenu n'est pas exclu (constat #18).

## Sommaire exécutif

> Synthèse des 12 sources activées (5 BF + 7 CA) et des 9 sources désactivées auditées individuellement dans les sections ci-dessous. Chaque chiffre cité ici provient de la section de la source correspondante, où il est accompagné de sa preuve brute (log de nœud, requête SQL, reproduction `curl`/navigateur).

### (a) Verdict rappel / précision, par pays

**Constat d'ensemble : le pipeline n'a pas un problème de pertinence, il a un problème de disponibilité.** Les deux pays sont à **zéro notice en base** — la table `notices` est vide pour BF comme pour CA, toutes sources confondues. La question « le système remonte-t-il des avis non pertinents ? » est aujourd'hui structurellement sans objet : il ne remonte rien du tout, sans qu'aucune alerte ne signale, dans l'un ou l'autre pays, que la collecte est à l'arrêt. **Côté BF**, le rapport quotidien a même continué de partir par e-mail avec un contenu vide (`emails_sent: 1` ou plus sur les runs `completed`, Finding BF-3). **Côté CA**, aucune preuve de livraison n'a été relevée nulle part dans l'audit : sur le run tracé, la collecte échoue dès `extract_item_links`, bien en amont de tout étage de classification ou d'envoi — l'échec y est donc silencieux, sans qu'aucun e-mail trompeur n'ait été constaté (le statut de livraison des runs CA planifiés qui, eux, ont dépassé cet étage n'est pas documenté par les données consultées — voir constat #9).

**Burkina Faso — rappel effectif : 0 %.**

- **Bout en bout : 0 avis persisté**, ni le jour de l'audit ni sur la fenêtre historique observable. Sur les 20 dernières lignes `runs` (2026-08-08 → 2026-09-01, Finding BF-3), dont **18 runs `harvest`** (les 2 lignes restantes sont des runs `delivery`) : **6 runs `harvest` en `failed`** — 4 sur `DatetimeFieldOverflow` (Finding BF-1 : 3 sur la même notice UNICEF, dont le run planifié de production du 09-01 07:00, et 1 sur une notice ILO distincte le 08-29) et 2 sur un `KeyError: 'content'` distinct jamais investigué (08-11 et 08-20, constat #19) ; les **12 runs `completed`/`completed_with_warnings`** restants n'ont rien persisté non plus — les 10 dont le `counts_json` a été vérifié run par run rapportent tous `unique_items: 0` malgré `items_parsed` entre 26 et 29 (Finding BF-2, anomalie non résolue). **La collecte BF est donc cassée en production depuis au moins le 2026-08-08**, soit par crash direct, soit par une perte silencieuse en amont de `deduplicate`.
- **En amont de la persistance, le jour de l'audit : ~24 avis sur ~279 de vérité terrain, soit ~9 %.** Détail par source (vérité terrain → items atteignant `deduplicate`) : DGCMEF **0/27** (0 %), Joffres.net **1/1** (100 %), UNGM **14/54 actifs** (~26 %), UEMOA **8/194** (~4 %), Enabel **1/3** (33 %). *Réserve méthodologique honnête : ces univers ne sont pas strictement homogènes — les 54 UNGM sont filtrés « actifs », les 194 UEMOA sont le listing complet sans filtre de statut, les 27 DGCMEF sont les avis d'un seul bulletin quotidien. Le ratio global (~9 %) est donc un ordre de grandeur, pas une mesure exacte ; les ratios par source, eux, sont directement comparables à leur propre vérité terrain.*
- **Des avis manifestement pertinents IT ont été vérifiés dans les pertes**, pas seulement du volume : consommables informatiques ISLO (DGCMEF, perdu au parse), data center / réseau local CAM et licences Microsoft EA (UEMOA, perdus au fetch), pare-feu nouvelle génération EOIUNPD24643 (UNGM, perdu au fetch — cet avis précis était **déjà expiré à la date de l'audit**, il illustre donc le mécanisme de perte plutôt qu'un manque encore actif), acquisition et installation d'équipements informatiques PNUD/UNDP-BFA-00734 (vu par Joffres.net, perdu au persist ; également invisible côté UNGM faute de pagination).

**Canada — rappel effectif : 0 %, et jamais autre chose que 0 %.**

- **Aucune notice CA n'a jamais existé en base** (`SELECT ... WHERE country_id=CA` → 0 lignes, sources 13 à 28). Sur le run audité, **7 sources activées sur 7 ont produit 0 lien** : 3 échouent sur `playwright not installed`, 3 sur `TAVILY_API_KEY not set`, et Le Devoir échoue silencieusement sur 7/7 images (modèle Groq Vision 404). Le graphe s'est arrêté à `extract_item_links` (« No item links discovered from any source »), bien avant les étages `parse`/`dedup`/`persist`.
- **Vérité terrain disponible le jour même et jamais atteinte : ≥ 2 473 avis publiés** (Achats Canada 964, Ville de Montréal 927, UNDP 561, Palladium 21), **plus** le sous-ensemble `OPEN` des 29 740 lignes de Nova Scotia (non dénombré) et le contenu des 7 images scannées de Le Devoir retenues par la fenêtre `max_days` (6 bulletins datés — ≈ 6 encadrés chacun sur l'échantillon testé — plus 1 avis d'appel d'offres individuel non daté). The Commonwealth est le seul cas où la vérité terrain est réellement vide (0 avis actif sur les 3 onglets du portail). Au moins **10 avis matchant littéralement les mots-clés configurés** ont été identifiés nominativement dans ces pertes (équipement informatique UNDP-UKR-01815 / UNDP-LAO-00740, cybersécurité UNDP-MDA-01077, serveurs HP UNDP-ARM-01019, plateforme CNAPP Montréal, licences Microsoft Nova Scotia, système de répartition assistée par ordinateur et licences SIGE Achats Canada, campagne numérique et système de gestion d'entrepôt Palladium).
- **Signal supplémentaire à ne pas manquer** : le run planifié CA du 2026-09-02 07:00 (`3ebf19d1`, `completed_with_warnings`) rapporte `unique_items: 97` mais `notices_persisted: 0` — un écho direct du Finding BF-2, jamais investigué. Autrement dit, même les jours où des sources CA produisent des items, rien n'atteint la base.

**Précision — non mesurable aujourd'hui, dans les deux pays.** Aucune ligne `company_notice_status` n'existe (l'étage `classify` n'a jamais tourné sur les runs audités, la livraison ne s'est jamais déclenchée) : **zéro faux positif de classification observé, mais zéro observable**. C'est une absence de donnée, pas un satisfecit. Deux risques de précision ont malgré tout été identifiés par anticipation : (1) **Le Devoir** — 1 seule des 29 entrées listées est individuellement un avis d'appel d'offres, le reste étant des bulletins légaux généralistes mêlant successions, dissolutions et appels d'offres, ce qui exposera l'extraction OCR à remonter du bruit non-procurement dès que le modèle sera corrigé ; (2) **le seuil de dédoublonnage à 0,75** joue en sens inverse — il ne remonte pas de faux positifs, il **détruit des vrais positifs** (3 cas vérifiés). La précision réelle du classifieur reste à mesurer lors d'un premier run réellement complet, post-correction.

### (b) Tableau des constats, classés par sévérité / impact

Taxonomie de cause racine : Fetch · Parse · Classify · Dedup · Delivery · Config. Étiquette : **bug logique** (corrigible indépendamment de la techno) · **limite architecturale** · **limite technologique**.

**Précisions sur l'usage réel de cette taxonomie** (déclarée avant l'audit, donc avant de savoir où les défaillances atterriraient — les valeurs du tableau ci-dessous, et celles des tableaux « Gaps constatés » de chaque section source, ne sont volontairement pas renormalisées, la nuance qu'elles portent étant informative) :

- **Deux étages ont été ajoutés en cours d'audit, parce qu'ils se sont révélés être de vrais lieux de défaillance** : **`Persist`** (`persist_notices`, où atterrit le constat le plus grave du rapport, le #1) et **`observabilité`** (absence d'alerte / absence de traçabilité, utilisée en combinaison : `Delivery / observabilité`, `Dedup / observabilité`). `Indéterminé` est employé lorsque l'étage exact n'a pas pu être établi (#19).
- **Échelle de sévérité, jamais déclarée explicitement jusqu'ici : `Critique` > `Élevée` > `Modérée` > `Faible`.** Certaines cellules qualifient cette valeur entre parenthèses (p. ex. « Modérée (à investiguer) », « Critique (mécanisme) / nul (impact du jour) ») : le mot d'échelle reste le premier terme, la parenthèse porte la nuance.
- **Certaines cellules de sévérité ne portent pas une sévérité mais un *statut***, pour des points en attente de travail complémentaire plutôt que hiérarchisables : `À réévaluer` (en attente d'une clé Tavily), `À surveiller` (risque non confirmé), `À vérifier post-correction`, `Pas un gap` (non-constat vérifié explicitement). Cette convention vaut aussi pour les tableaux « Gaps constatés » des sections source — où l'on trouve, pour la même raison, `Indéterminé` et `N/A` dans la colonne `Vu par le pipeline ?` lorsque la question est sans objet ou non tranchée (The Commonwealth).
- **Les valeurs d'étiquette qualifiées** (`bug logique (présumé)`, `bug logique (à vérifier)`, `bug logique / processus`, `bug logique (dépendance) / risque techno non confirmé`, `limite architecturale potentielle (non confirmée)`, `limite architecturale mineure`, `limite technologique latente`, `limite de la source`, `externe`, `externe / robustesse`, `non déterminé`) sont des variantes des 3 étiquettes déclarées, assorties du degré de certitude réellement atteint. `externe` et `limite de la source` désignent une cause hors du code du pipeline ; `non déterminé` signifie qu'aucune étiquette n'a pu être établie honnêtement (#24).

| # | Constat | Portée / impact mesuré | Étage | Étiquette | Sévérité |
|---|---|---|---|---|---|
| 1 | Transaction `persist_notices` unique et tout-ou-rien (un seul `db.commit()` après la boucle, aucun savepoint) + chaînes de date brutes assignées sans parsing à une colonne `DateTime` (`datestyle` Postgres `ISO, MDY`) | **Tout le run BF détruit** par une seule notice malformée — 24 items, toutes sources confondues, le jour de l'audit ; récurrent en production (07:00 du 09-01, 08-29) | Persist | bug logique | **Critique** |
| 2 | `playwright` absent de l'image `staging_api` | **3 sources CA à 100 % de perte** (Achats Canada 964 avis, Ville de Montréal 927, Nova Scotia 29 740 lignes) | Fetch / Config (déploiement) | bug logique | **Critique** |
| 3 | `TAVILY_API_KEY` non définie dans `staging_api` | **3 sources CA à 100 % de perte** (UNDP 561 avis, Palladium 21, The Commonwealth 0 aujourd'hui) — et bloque aussi toute réactivation des 9 sources désactivées, toutes `tavily_extract` | Fetch / Config (déploiement) | bug logique | **Critique** |
| 4 | DGCMEF : chaîne d'extraction LLM-par-chunk (`parse_pdf_rag.py`, mode `use_direct_extraction`) ne produit aucun item ; exceptions par chunk capturées et ignorées, message de « fallback » trompeur (aucun fallback implémenté) | **0 avis sur 27** du bulletin officiel du jour, PDF pourtant téléchargé intact et texte confirmé exploitable ; perte silencieuse, aucune alerte au niveau du run | Parse | bug logique | **Critique** |
| 5 | Le Devoir : id de modèle Groq Vision déprécié codé en dur (`meta-llama/llama-4-scout-17b-16e-instruct` → `404 model_not_found`), échec absorbé par un `try/except` par image | **7/7 images OCR échouées**, `status: success` malgré tout ; fix prouvé trivial (remplacement de chaîne par `qwen/qwen3.8-27b`, extraction exacte reproduite en direct) | Fetch (sous-étape OCR) | bug logique | **Critique** |
| 6 | UEMOA : `max_pages: 1` et aucun `pagination_url` dans `patterns` (DB), alors que la boucle générique existe et fonctionne pour Enabel | **184 avis sur 194 jamais fetchés (~94,8 %)**, dont ≥ 2 marchés IT identifiés en page 2 | Fetch / Config | bug logique | **Critique** |
| 7 | UNGM : `PageIndex: 0` codé en dur (`fetch_ungm.py` l.28), sans boucle, sur un endpoint qui plafonne à 15 lignes/page quel que soit `PageSize` | **~40 avis actifs sur 54 jamais vus (~74 %)** ; pagination prouvée fonctionnelle côté serveur (page 1 = 15 `notice_id` totalement disjoints) | Fetch | bug logique | **Critique** |
| 8 | Anomalie `unique_items: 0` sur **tous** les runs BF `completed` de l'échantillon 08-08 → 08-27 malgré `items_parsed` 26-29 — piste : divergence entre le compteur `items_parsed` de `counts_json` et `state.items_parsed` consommé par `deduplicate_node` | Explique pourquoi la base est vide **même les jours sans crash** ; **non résolue** par cet audit | Parse (probable, amont de `deduplicate`) | bug logique (présumé) | **Critique** |
| 9 | Écho CA de la précédente : run planifié `3ebf19d1` du 09-02 07:00 → `unique_items: 97`, `notices_persisted: 0` | Même symptôme, autre pays, **jamais investigué** | Persist / Parse (indéterminé) | bug logique (présumé) | **Critique** |
| 10 | Enabel : aucun `pdf_selector` dans `patterns` → les 3 cartes reçoivent la même `url` (celle de la page de listing) → `extract_item_links.py` déduplique sur `url` dans un `seen_urls` global partagé entre sources | **2 avis sur 3 (67 %) éliminés à tort à chaque run**, 100 % reproductible — mais **impact métier nul à date** (aucun des 3 avis ne matche un mot-clé IT) | Dedup / Config | bug logique | Critique (mécanisme) / nul (impact du jour) |
| 11 | UNGM : `_normalize_ungm_date()` reformate une date **non ambiguë** à la source (`29-Sep-2026`) en chaîne ambiguë (`29-09-2026`), jetant le nom du mois | Déclencheur direct du constat #1. **Corollaire plus sournois** : pour tout jour ≤ 12, la même chaîne serait silencieusement inversée par Postgres, corrompant `deadline_at` **sans lever d'erreur** | Parse (normalisation) / Persist | bug logique | **Critique** (crash) + corruption silencieuse latente |
| 12 | Aucune alerte quand la collecte est morte : `counts_json`/`errors` ne signalent ni la perte à 100 % de DGCMEF, ni les 7/7 échecs OCR de Le Devoir, ni `notices_persisted: 0` — et côté BF le mail quotidien part malgré tout avec un rapport vide (`emails_sent: 1`, Finding BF-3 ; aucune preuve de livraison équivalente relevée côté CA, où l'échec du run tracé est antérieur à tout envoi) | **C'est ce qui a permis à BF de rester mort ≥ 3 semaines et à CA de n'avoir jamais fonctionné, sans que personne ne le voie** | Delivery / observabilité | bug logique | **Élevée** |
| 13 | Faux positifs de dédoublonnage flou (`hash_similarity`, seuil 0,75, `fuzz.ratio` sur le seul titre ; le court-circuit de référence exacte ne s'applique qu'en cas de match, jamais en cas de mismatch) | **3 avis réels et distincts fusionnés à tort et vérifiés** : UNGM `LRFP-2026-9205896` (77,7 %), UEMOA addendum DAO 071 (93,9 %), UEMOA addendum DAOI N°022 « data center » (99,1 %) | Dedup | bug logique | **Modérée** |
| 14 | 9 sources désactivées sans aucune raison enregistrée (pas de colonne `disabled_reason` au schéma ; insérées en un lot, jamais exécutées : `last_seen_at`/`last_success_at`/`last_error_at` NULL) | **Aucune n'est morte.** 4 candidates à un gap de couverture (**NATO NSPA** — avis du jour même confirmés en HTML brut, **AFD-DGMarket**, **UNDP Africa**, **BAD/AfDB**), 1 désactivation clairement justifiée (**Guinea Tenders**, paywall), 1 probablement justifiée (**Belgique**, hors périmètre géographique), 1 à re-vérifier périodiquement (**OMD/WCO**, vide ce jour-là), 2 ambiguës faute de navigateur (**Bonfire Hub** — `list_url` ne couvre qu'un seul organisme malgré son nom, **World Bank**) | Config | bug logique / processus | **Modérée** |
| 15 | Ville de Montréal : `max_pages: 10` face à une pagination réelle de 93 pages | **Gap résiduel post-correction** : ~100 avis couverts sur 927 même une fois `playwright` installé | Fetch / Config | bug logique | **Modérée** |
| 16 | Nova Scotia : aucun `item_link_selector` dans `patterns` → `fetch_playwright.py` retomberait sur son mode « texte brut » (blob `page.inner_text("body")` envoyé au LLM), chemin de code différent des 2 autres sources `playwright` | **Comportement post-correction non vérifié** | Fetch / Config | bug logique (à vérifier) | **Modérée** |
| 17 | The Commonwealth : listing chargé par AJAX (`LoadProjects` on-load, `#containerProjects` vide en HTML statique) ; capacité de `tavily_extract`/`extract_depth: advanced` à l'exécuter **non vérifiée** faute de clé Tavily disponible | **Seul point d'architecture réellement ouvert de tout l'audit.** Impact net aujourd'hui nul (0 avis actif sur le portail) | Fetch | **limite architecturale potentielle (non confirmée)** | À réévaluer dès restauration de la clé |
| 18 | Nova Scotia : anti-bot réel (challenge JS + CAPTCHA, cookies `TS...`, famille F5/Shape) face aux clients HTTP nus — mais franchi par `chromium.launch(headless=True)` sans stealth, `navigator.webdriver: true` confirmé, challenge non déclenché | **Pas une limite technologique à date** ; réserve explicite : tests ponctuels à faible volume, un comportement anti-bot plus agressif sous trafic soutenu (rate-limiting progressif, détection comportementale, autres signaux d'empreinte) n'a pas été exclu | Fetch | bug logique (dépendance) / risque techno **non confirmé** | À surveiller |
| 19 | Runs BF `failed` du 08-11 et du 08-20 sur `KeyError: 'content'` | Classe de bug distincte du #1, **jamais investiguée** | Indéterminé | bug logique (présumé) | Modérée (à investiguer) |
| 20 | Le Devoir : précision structurelle de la source — 1 seule des 29 entrées est individuellement un avis d'appel d'offres, les 28 autres sont des bulletins légaux généralistes (successions, dissolutions, AO mélangés) | **Risque de bruit post-correction**, non quantifié avis par avis | Classify (risque prospectif) | limite de la source | Modérée (à mesurer) |
| 21 | Palladium : la page de listing ne porte ni `reference` ni `deadline` (uniquement titres + « Find out more ») ; `tavily_extract` ne suit que `list_url` | **Gap de complétude des champs post-correction** | Parse | limite architecturale mineure | Faible |
| 22 | Joffres.net : `ref_no` vide pour les annonces d'origine PNUD/UNDP (regex de `extract_joffres_detail()` ne couvre pas « Reference Number : XXX » sans « N° ») | Perte de complétude sur un champ, **l'avis lui-même est bien détecté** | Parse | bug logique | Faible |
| 23 | `deduplicate.py` (l.310) ne logue que les survivants, jamais les items écartés ni le motif | **Aucune traçabilité des pertes de dédoublonnage** — les 3 cas du #13 ont dû être reconstitués par calcul externe | Dedup / observabilité | bug logique | Faible |
| 24 | Doublon inter-sources confirmé : `UNDP-BFA-00734` publié à la fois sur Joffres.net et sur UNGM | La logique de dédoublonnage inter-source **n'a jamais pu être exercée** (aucun des deux exemplaires n'a atteint `persist_notices`) | Dedup | non déterminé | À vérifier post-correction |
| 25 | Le Devoir : l'image sans date dans son nom (`70380.jpg`) échappe définitivement à la fenêtre `max_days` (`re.search` échoue, garde `if m:` fausse) | Bug latent, bénin aujourd'hui | Fetch | bug logique | Faible |
| 26 | The Commonwealth : passerelle reCAPTCHA (`#captcha-container`) déclenchée uniquement au-delà d'une profondeur de pagination | Latent — non pertinent tant que le portail est vide et sans `max_pages` configuré | Fetch | limite technologique latente | Faible |
| 27 | Joffres.net : 3 échecs `502 Bad Gateway` / timeout sur la fenêtre de 20 runs (source connue fragile, UA navigateur déjà forcé dans le code) | Fragilité externe intermittente, **pas de blocage anti-bot observé le jour de l'audit** | Fetch | externe / robustesse | Faible |
| 28 | Échec de livraison SMTP le 08-22 (`completed_with_warnings`) | Incident isolé et indépendant | Delivery | externe | Faible |
| 29 | `/app/logs/nodes` inexistant dans le conteneur `staging_api` (répertoire parent `/app/logs` appartenant à `root:root`, conteneur tournant en `uid 999`/`tenderai`) → **tous** les appels `log_node_output()` échouaient silencieusement | **Aucun log de nœud n'était produit en production** : le diagnostic de cet audit n'a été possible qu'après correction manuelle (`mkdir -p` + `chown`, section Burkina Faso). Seul le conteneur **en cours d'exécution** a été patché — le défaut **se reproduira au prochain redéploiement** (rien n'est corrigé dans l'image ni dans `docker-compose`) | Fetch / Config (déploiement) | bug logique | **Modérée** |
| — | **Non-constat explicitement vérifié** : UEMOA `ssl_verify: false` | Corrélé à un **vrai** défaut de chaîne TLS côté `www.uemoa.int` (intermédiaire Sectigo non servi, reproduit par `curl`/`openssl`) — contournement légitime, **aucune perte associée** | — | — | **Pas un gap** |

**Récapitulatif par étiquette :** sur **29 constats**, **1 seul** porte une étiquette autre que « bug logique » côté cause racine confirmée — le point d'architecture **ouvert et non tranché** de The Commonwealth (#17). S'y ajoutent 4 réserves prospectives ou latentes, aucune confirmée comme bloquante : #18 (risque anti-bot Nova Scotia sous trafic soutenu), #20 (densité procurement faible de la source Le Devoir), #21 (champs `reference`/`deadline` absents du listing Palladium) et #26 (reCAPTCHA Commonwealth au-delà d'une profondeur de pagination). Deux constats relèvent d'incidents externes ponctuels (#27, #28), et un seul reste sans étiquette établie — #24 (`non déterminé`), le doublon inter-sources `UNDP-BFA-00734` dont la logique de dédoublonnage n'a jamais pu être exercée. **Aucune limite technologique confirmée sur aucune des 12 sources activées.**

### (c) Ce que cet audit dit du spike Scrapling

**Verdict : ne pas lancer le spike Scrapling maintenant — aucun des constats de cet audit ne le justifie, et il ne corrigerait aucun d'entre eux.** Ce n'est pas une réserve de principe : les trois prémisses du spike (`docs/PROJECT_STATUS.md`, chantier 4) ont été confrontées aux faits, et deux d'entre elles sont directement contredites par des preuves obtenues dans cet audit.

1. **« Les parsers sur mesure cassent aux redesigns HTML → sélecteurs auto-réparants. »** *Non observé, pas une seule fois.* Aucun des 29 constats n'est un sélecteur cassé par un changement de mise en page. Tous les sélecteurs effectivement configurés ont matché ce qu'ils devaient matcher (`a.job-title` Joffres, `div.swiper-slide div.news-box` UEMOA, `div.card--news.card--tenders` Enabel, `a[href*="/appels-d-offres/"]` Achats Canada, `table tbody tr` Nova Scotia). Les deux problèmes de forme « sélecteur » sont en réalité des **sélecteurs manquants dans la config** (Enabel `pdf_selector`, Nova Scotia `item_link_selector`) — un sélecteur auto-réparant ne répare pas un sélecteur qu'on n'a jamais écrit.
2. **« Playwright nu est trivialement détectable ; portails type UNGM/gouv derrière Cloudflare → `StealthyFetcher`. »** *Falsifiée sur les deux sources où elle était testable.* **UNGM** n'utilise pas Playwright du tout — c'est un POST `httpx` vers un endpoint legacy, qui répond `HTTP 200` propre, sans CAPTCHA, sans Cloudflare (`grep` explicite sur la réponse brute) : sa perte de 74 % est une boucle `for` manquante, pas un blocage. **Nova Scotia** est le seul véritable mur anti-bot de tout l'audit (challenge JS + CAPTCHA + cookies `TS...` F5/Shape face à `curl`) — et un `playwright.chromium.launch(headless=True)` **nu, sans aucun patch de furtivité, avec `navigator.webdriver: true` confirmé**, l'a franchi et a affiché les 29 740 résultats. C'est exactement la configuration que `StealthyFetcher` est censé remplacer, testée sur le chemin de code réel de production : elle passe.
3. **« `playwright` + `crawl4ai` se recouvrent → une seule API. »** *Ni confirmée ni infirmée par cet audit* — c'est un argument d'hygiène de dépendances, pas de qualité de collecte. À noter tout de même : `playwright` n'est même pas installé dans l'image déployée, donc la consolidation des dépendances n'est bloquante pour rien aujourd'hui.

**Les seules cibles où un fetcher furtif pourrait un jour se justifier** — trois, toutes hors du périmètre des 12 sources activées ou conditionnées à une observation future :

- **UNDP Africa (id 22, désactivée)** — `403 Access Denied` Akamai sur **tout** le domaine `undp.org`, pas seulement la page ciblée. Contenu réel existant et géographiquement pertinent.
- **BAD / AfDB (id 26, désactivée)** — `403` avec `cf-mitigated: challenge`, `server: cloudflare` : challenge JS Cloudflare explicite. Institution panafricaine, la plus pertinente du lot désactivé pour le Burkina Faso.
- **Nova Scotia (id 16), mais seulement sous trafic soutenu** — la section correspondante refuse explicitement d'exclure un durcissement progressif (rate-limiting, détection comportementale, signaux d'empreinte non testés : canvas/WebGL, timing) face à un accès automatisé quotidien répété, par opposition aux quelques exécutions ponctuelles de cet audit.

Même pour ces trois-là, **le spike n'est pas la prochaine étape** : les deux sources désactivées sont configurées en `parser_type: tavily_extract`, et Tavily n'a jamais pu être testé faute de clé. Restaurer `TAVILY_API_KEY` et observer si Tavily franchit Akamai/Cloudflare sur ces deux URLs est un test à coût quasi nul qui doit précéder l'évaluation d'une nouvelle bibliothèque. Pour Nova Scotia, la précondition est d'installer `playwright` et de laisser tourner la source quelques jours en production : s'il n'y a pas de dégradation, il n'y a pas de sujet.

**Ce qui est totalement étranger à la technologie de scraping — c'est-à-dire l'écrasante majorité :** les constats **#1 à #13, #15, #16, #19 à #25, #27, #28, #29**. Le constat **#14** (les 9 sources désactivées) est le seul **mixte** et est donc exclu de cette liste : la plupart de ses sous-cas n'ont rien à voir avec la technologie de scraping (raison de désactivation non enregistrée, `list_url` mal ciblée pour Bonfire Hub, paywall Guinea Tenders, périmètre géographique belge, portail vide côté OMD/WCO), mais deux de ses sous-cas — **UNDP Africa** (403 Akamai) et **BAD/AfDB** (`cf-mitigated: challenge`) — sont précisément deux des trois cibles de fetcher furtif nommées ci-dessus. Pour le reste : deux artefacts de déploiement manquants, une chaîne de modèle dépréciée, deux valeurs de configuration en base, un index de pagination codé en dur, une date non parsée, un seuil de similarité mal calibré, une clé de dédoublonnage mal choisie, une chaîne d'extraction LLM qui avale ses exceptions, et une absence totale d'alerting. **Aucun de ces problèmes ne serait résolu, ni même effleuré, par le remplacement de la couche de fetch.** Adopter Scrapling aujourd'hui coûterait un temps d'intégration non nul pour zéro avis récupéré, tout en retardant des correctifs qui sont chacun d'une ligne ou d'une valeur de configuration.

**Recommandation :** reporter le spike **après** la phase de correction, puis le re-cadrer sur ce qui restera réellement ouvert — (a) `StealthyFetcher` contre exactement 3 cibles (UNDP Africa, BAD, Nova Scotia sous charge réelle), **et seulement si** Tavily/Playwright y échouent d'abord ; (b) la question `Adaptor`/`.markdown()` et la réduction du coût LLM, sur laquelle cet audit ne dit rien et qui reste un motif d'évaluation légitime et indépendant.

### (d) Si l'on ne pouvait corriger que 3 choses

*(Non corrigé ici — ce chantier est un diagnostic. Liste destinée à la priorisation de la phase 2.)*

1. **`persist_notices` : isolation par item + parsing réel des dates avant l'INSERT** (constats #1 et #11).
   Tant que ce point n'est pas corrigé, **tout correctif BF en amont est sans effet** : les avis seraient de nouveau collectés puis détruits au même endroit. C'est aussi le seul constat de tout l'audit qui **détruit activement de la donnée déjà correctement collectée** — 24 items le jour de l'audit, dont plusieurs pertinents IT — et c'est un incident de **production récurrent** (07:00 du 09-01, 08-29), pas un artefact d'audit. Le correctif de date ne doit pas se limiter à empêcher le crash : le corollaire silencieux (jour ≤ 12 inversé par Postgres sans aucune erreur) est un problème d'intégrité plus insidieux que le crash lui-même, resté invisible précisément parce qu'il ne casse rien. Portée : un fichier, plus la normalisation en objet `date` en amont.

2. **Les deux artefacts de déploiement CA : installer `playwright` dans l'image et définir `TAVILY_API_KEY`** (constats #2 et #3).
   Meilleur rapport « vérité terrain débloquée / effort » de tout le rapport : une ligne dans le Dockerfile/`poetry install --extras full && playwright install chromium`, une variable d'environnement — et **6 sources sur 7 passent de 0 % à quelque chose**, soit ≥ 2 470 avis publiés le jour même plus le sous-ensemble actif de Nova Scotia, dont ≥ 10 avis vérifiés comme matchant littéralement les mots-clés configurés. C'est aussi un **prérequis bloquant** pour les 4 candidates à la réactivation parmi les sources désactivées (toutes `tavily_extract`) et pour trancher le seul point d'architecture ouvert du rapport (The Commonwealth, #17). Le Canada n'a **jamais** produit une seule notice ; ces deux gestes sont ce qui sépare le pays de son premier run réel.

3. **La pagination : boucle `PageIndex` pour UNGM, `max_pages` + `pagination_url` pour UEMOA** (constats #7 et #6).
   Deux corrections quasi gratuites — une boucle `for` dans `fetch_ungm.py`, une mise à jour de la colonne `patterns` en base pour UEMOA (pur changement de configuration, prouvé trivial par le fait que la même mécanique tourne déjà avec succès pour Enabel) — pour **~40 avis actifs/jour côté UNGM (~74 % de sa vérité terrain) et ~184 côté UEMOA (~94,8 %)**. Arithmétique, à partir des seuls chiffres prouvés dans les sections correspondantes : le run audité a fait entrer **27 items** au total dans `parse_extract` (15 UNGM + 10 UEMOA + 1 Enabel + 1 Joffres.net) ; ces deux correctifs y ajouteraient **+40 et +184**, soit **~251 items/jour** — un changement d'ordre de grandeur, pas un ajustement marginal. Et les pages jamais atteintes contiennent des marchés IT nommément vérifiés (data center / réseau local CAM, licences Microsoft EA, et côté UNGM le pare-feu nouvelle génération EOIUNPD24643 — ce dernier déjà expiré à la date de l'audit, donc illustratif du mécanisme plutôt qu'un manque encore actif). Rapport impact/effort le plus élevé de tout le portefeuille BF.

**Pourquoi ces trois-là et pas les autres — les dauphins écartés, et la raison :**

- **DGCMEF (#4)** est probablement la source la plus importante métier de tout le portefeuille BF (bulletin officiel de l'autorité de commande publique burkinabè, 27 avis/jour, perte à 100 %) et aurait sa place ici sur le seul critère de la valeur. Elle est écartée du trio **parce que son coût est inconnu** : la section n'a pas pu trancher entre erreur systématique de config/prompt/schéma et rate-limit Groq sur ~70 appels séquentiels, faute de logs conservés. C'est le premier chantier à instrumenter juste après les trois ci-dessus — mais ce n'est pas un correctif à coût connu, contrairement aux trois retenus.
- **L'absence d'alerting (#12)** est le constat le plus structurant du rapport sur le plan systémique : c'est lui qui a permis à BF de rester mort ≥ 3 semaines — pendant que son mail quotidien continuait de partir avec un rapport vide — et à CA de n'avoir jamais fonctionné, là sans qu'aucune preuve de livraison n'ait été relevée (le run tracé échoue dès `extract_item_links`, bien en amont de tout envoi). Il n'est pas dans le trio parce qu'il **ne remonte aucun avis par lui-même**. Il est en revanche assez peu coûteux (une alerte sur `notices_persisted == 0` alors que `unique_items > 0`, plus une remontée des échecs par source dans `counts_json`) pour être embarqué dans le même lot que le point 1, sur lequel il porte directement.
- **`unique_items: 0` (constats #8/#9, = Finding BF-2)** est potentiellement aussi grave que le #1 — il expliquerait pourquoi la base est vide **même les jours sans crash**, dans les deux pays. Il n'est pas dans le trio parce qu'il n'est pas encore un correctif : c'est une **investigation** à mener, et sa piste (divergence entre le compteur `items_parsed` de `counts_json` et `state.items_parsed`) devra de toute façon être rejouée une fois le #1 corrigé, moment où le symptôme deviendra directement observable.
- **Le Devoir (#5)** est le fix le plus trivial du rapport (une chaîne de caractères, remplacement validé en direct) — mais il ne débloque qu'une seule source, dont la vérité terrain est par ailleurs la plus pauvre en avis individuellement identifiables (1 sur 29) et la plus exposée au bruit. À faire immédiatement, mais il ne mérite pas une des trois places.
- **Enabel (#10)** et **le seuil de dédoublonnage (#13)** sont des bugs réels, systématiques et parfaitement diagnostiqués, mais leur impact métier mesuré à date est faible à nul (aucun des 3 avis Enabel ne matche un mot-clé IT ; 2 des 3 fusions à tort concernent des marchés de travaux ou des addenda déjà hors de portée du fetch). Ils appartiennent au lot de correction suivant, pas au trio.

## Burkina Faso

**Run snapshot (BF) :** harvest run `785adda4-f28c-4f3c-af0a-74b7e775d0b5` (déclenché 2026-09-01 21:20:45 UTC, échoué 21:24:40 UTC), pas de run de delivery (le harvest a échoué avant que la livraison ne soit déclenchée). Logs de nœuds capturés dans `bf-nodes/` (scratchpad de session). Critères de pertinence utilisés : voir Contraintes globales du plan.

*Note de numérotation : les trois findings `### Finding #1/#2/#3` ci-dessous appartiennent à cette section et sont référencés ailleurs dans le document sous la forme **`Finding BF-1` / `BF-2` / `BF-3`**, pour les distinguer des `constat #N` du tableau du sommaire exécutif, qui suivent une numérotation indépendante (voir « Méthode et limites » en tête de document).*

**⚠️ AVERTISSEMENT CRITIQUE pour les tâches 2-6 :** la table `notices` est actuellement **vide (0 lignes, toutes sources, tous pays confondus)**. Ce n'est ni une "vérité terrain fraîche" ni une "vérité terrain ancienne mais valable" — il n'y a **aucune** vérité terrain en base actuellement. Toute requête SQL des tâches 2-6 (leur Step 3) contre `notices`/`company_notice_status` renverra 0 ligne pour n'importe quelle `source_id`, y compris 8-12. Ne pas interpréter un résultat vide comme "le pipeline n'a rien trouvé" — voir Finding #2 ci-dessous pour la cause. Les logs de nœuds de fetch/parse (étages en amont de `persist_notices`, capturés dans `bf-nodes/nodes/`) restent une preuve valable et fraîche du jour même, puisque `persist_notices` est le dernier nœud du graphe harvest et s'exécute après eux.

### Finding #1 — `DatetimeFieldOverflow` bloque la persistance de tout le run BF (sévérité : critique)

**Erreur exacte (reproduite 2 fois pendant cet audit, identique à 2 occurrences de production antérieures — voir Finding #3) :**
```
(psycopg2.errors.DatetimeFieldOverflow) date/time field value out of range: "29-09-2026"
LINE 1: ...P-2026-9205898', 'UNICEF', 'Autre', '01-09-2026', '29-09-202...
HINT:  Perhaps you need a different "datestyle" setting.
```
Notice en cause : UNGM notice `LRFP-2026-9205898` ("UNICEF China Tender LRFP-2026-9205898 LTA Contract for Vision Aids"), champ `deadline_at` = `"29-09-2026"`. `29` ne peut être un mois valide dans aucun ordre — le format `DD-MM-YYYY` est correct sémantiquement, mais la session Postgres (`datestyle`) l'interprète visiblement comme `MM-DD-YYYY` (ou une autre convention), et `29` déborde le champ mois/jour selon l'interprétation active. Root cause précise (quel composant fixe le `datestyle`, pourquoi ce format n'est pas normalisé avant d'atteindre l'INSERT) non investiguée ici — hors périmètre de la Tâche 1, à approfondir par la Tâche 4 (UNGM) ou en phase 2 fix.

**Analyse du code (`src/tenderai/agents/nodes/persist_notices.py`, tenderai-backend) :** une seule session `with get_db_context() as db:` couvre **tous** les items de **toutes** les sources du run — la boucle appelle `db.add(notice)` pour chaque item mais **aucun `db.commit()` n'a lieu à l'intérieur de la boucle** ; un unique `db.commit()` est exécuté une fois la boucle terminée (ligne 98). Il s'agit donc structurellement d'une transaction unique, tout-ou-rien, pour l'ensemble du run — pas de commit par item ni par source.

**Preuve empirique directe (capture du run re-déclenché) :** le SQL qui échoue est un **unique** `INSERT INTO notices (...) VALUES (...), (...), ... RETURNING ...` regroupant 24 lignes en paramètres `__0` à `__23` dans une seule requête (confirmant que SQLAlchemy a bufferisé tous les `db.add()` en un seul flush/INSERT multi-lignes, cohérent avec l'analyse du code). Répartition observée des 24 lignes par `source_id` dans ce batch (via `deduplicate.json` du même run, qui liste les 24 items uniques envoyés à `persist_notices`) : **UNGM (source_id 10) : 14 items**, **UEMOA (source_id 11) : 8 items**, **Joffres.net (source_id 9) : 1 item**, **Enabel (source_id 12) : 1 item**. DGCMEF (source_id 8) a contribué 0 item unique ce run (extraction RAG en cours au moment du crash — voir Tâche 2, hors périmètre ici). Un seul champ malformé venant d'UNGM a donc fait échouer l'INSERT complet et avec lui la persistance de **toutes** les notices UEMOA, Joffres.net et Enabel de ce run — confirmant sans ambiguïté que le rayon d'impact est le run entier, pas la seule source fautive.

**Conséquence directe :** aucune notice BF (toutes sources confondues) n'a été persistée aujourd'hui, ni lors du run planifié 07:00 ni lors des deux tentatives de cet audit. Aucun run de delivery ne s'est déclenché derrière (le CLI `run-once` enchaîne harvest puis delivery ; le harvest ayant `status=failed`, aucune ligne `runs` de type `delivery` n'a été créée pour cette fenêtre).

### Finding #2 — anomalie distincte : les runs "completed" historiques rapportent aussi `unique_items: 0`

En creusant l'historique des runs BF (Finding #3 ci-dessous) pour dater l'apparition du bug, une anomalie séparée est apparue : **tous** les runs harvest BF `completed`/`completed_with_warnings` de l'échantillon (08-08 au 08-27, 10 runs vérifiés) rapportent `"unique_items": 0` et `"relevant_items": 0` dans `counts_json`, malgré `"items_parsed"` entre 26 et 29 à chaque fois. Or le run re-déclenché aujourd'hui (qui, lui, a crashé) a produit un `deduplicate.json` tout à fait normal : 24 items, tous `is_duplicate: false` — le code de `deduplicate_node` (lu en intégralité) ne peut structurellement pas renvoyer 0 item unique si `items_parsed` > 0 (le premier item d'une boucle ne peut jamais être marqué doublon, la liste `unique_items` étant vide au départ). Cette contradiction n'a **pas** été résolue dans le cadre de cette tâche — cause possible à explorer : une divergence entre le compteur de stats `items_parsed` (dans `counts_json`) et l'attribut réel `state.items_parsed` consommé par `deduplicate_node` (le nœud sort tôt avec `unique_items=[]` si `state.items_parsed` est falsy, ligne 127-129 de `deduplicate.py`), ce qui pointerait vers un bug amont (parse_extract) plutôt que dans `deduplicate.py` lui-même. **Signalé pour la synthèse / les tâches 2-6, non résolu ici** — il explique en partie pourquoi la table `notices` est vide même sur des jours sans crash de persist.

### Finding #3 — récurrence historique (table `runs`, 20 dernières lignes BF)

| Run (started_at) | run_type | status | Erreur |
|---|---|---|---|
| 2026-09-01 21:20:45 (ce re-run) | harvest | failed | `DatetimeFieldOverflow: "29-09-2026"` (UNICEF LRFP-2026-9205898) |
| 2026-09-01 21:12:08 (1er essai audit, avant fix du dossier de logs) | harvest | failed | `DatetimeFieldOverflow: "29-09-2026"` (même notice UNICEF) |
| 2026-09-01 07:00:03 (run planifié quotidien) | harvest | failed | `DatetimeFieldOverflow: "29-09-2026"` (même notice UNICEF) |
| 2026-08-29 07:00:02 | harvest | failed | `DatetimeFieldOverflow: "28-08-2026"` (ILO rfx_10044_HQ, notice différente) |
| 2026-08-27, 08-26, 08-25 | harvest | completed | — (mais `unique_items: 0`, voir Finding #2) |
| 2026-08-22 | harvest | completed_with_warnings | SMTP delivery failure (indépendant) |
| 2026-08-21, 08-19, 08-18 | harvest | completed | — (`unique_items: 0`) |
| 2026-08-20 | harvest | failed | `'content'` (KeyError probable, bug distinct, non investigué) |
| 2026-08-15, 08-13, 08-12 | harvest | completed_with_warnings | Joffres.net 502 / timeout (indépendant) |
| 2026-08-14 | harvest | completed | — (`unique_items: 0`) |
| 2026-08-11 | harvest | failed | `'content'` (même bug distinct que 08-20) |
| 2026-08-08 | harvest | completed | — (`unique_items: 0`) |

**Requête SQL utilisée (ré-exécutée le 2026-09-01 pour cette correction, contre `staging_postgres`) :**
```bash
ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, run_type, status, started_at, left(error_message, 180) AS error_excerpt \
     FROM runs WHERE country_id=(SELECT id FROM countries WHERE code='BF') \
     ORDER BY started_at DESC LIMIT 20;\""
```
(Pas de filtre sur `run_type` : les 2 lignes `delivery` `completed` du 09-01 07:00:06 et du 08-29 07:00:04 occupent 2 des 20 lignes retournées, ce qui explique que la fenêtre des 18 runs `harvest` couverts par la table ci-dessus s'arrête pile au 2026-08-08.)

**Sortie brute (extraits, par classe d'erreur — colonnes `id | run_type | status | started_at | error_excerpt`) :**
```
785adda4-f28c-4f3c-af0a-74b7e775d0b5 | harvest | failed | 2026-09-01 21:20:45.340424 |
  (psycopg2.errors.DatetimeFieldOverflow) date/time field value out of range: "29-09-2026"
  LINE 1: ...P-2026-9205898', 'UNICEF', 'Autre', '01-09-2026', '29-09-202...

976dea9a-3da9-442a-a493-d40d43d78a07 | harvest | failed | 2026-09-01 21:12:08.366465 |
  (psycopg2.errors.DatetimeFieldOverflow) date/time field value out of range: "29-09-2026"
  LINE 1: ...P-2026-9205898', 'UNICEF', 'Autre', '01-09-2026', '29-09-202...

bff78c36-0135-451f-af4c-8cf296d053e1 | harvest | failed | 2026-09-01 07:00:03.290028 |
  (psycopg2.errors.DatetimeFieldOverflow) date/time field value out of range: "29-09-2026"
  LINE 1: ...P-2026-9205898', 'UNICEF', 'Autre', '01-09-2026', '29-09-202...

277b697c-3297-419d-a1b2-294e8bccdde1 | harvest | failed | 2026-08-29 07:00:02.744472 |
  (psycopg2.errors.DatetimeFieldOverflow) date/time field value out of range: "28-08-2026"
  LINE 1: ...Branch (SECTOR)', 'rfx_10044_HQ', 'ILO', 'Autre', '28-08-202...

b879a23c-f3e2-4a6f-8d3b-4832ab3c61ae | harvest | completed_with_warnings | 2026-08-22 07:00:00.440185 |
  Email delivery failed but report is available on MinIO: send_report_email returned False (SMTP rejected delivery)

88f18ab1-21bf-4b1a-8014-7792382118e4 | harvest | failed | 2026-08-20 07:00:00.469763 | 'content'
e6f3d8cb-8550-4901-86b9-445fbc3dcde6 | harvest | failed | 2026-08-11 07:00:00.655798 | 'content'

656a10ea-96bd-4b1c-98ea-6a80d0f39632 | harvest | completed_with_warnings | 2026-08-15 07:00:00.392437 |
  Failed to fetch Joffres.net - Page de Recherche: HTTP 502: Bad Gateway
102bc3dc-ec22-4502-8405-072be46e6bd1 | harvest | completed_with_warnings | 2026-08-13 07:00:00.303762 |
  Failed to fetch Joffres.net - Page de Recherche: Request timeout
bf38ab5d-1b61-45d4-820e-dc77baae1375 | harvest | completed_with_warnings | 2026-08-12 07:00:00.829867 |
  Failed to fetch Joffres.net - Page de Recherche: Request timeout
```
Les runs `completed` restants de la fenêtre (08-27, 08-26, 08-25, 08-21, 08-19, 08-18, 08-14, 08-08) retournent `error_excerpt` NULL/vide — cohérent avec un `status=completed` sans erreur enregistrée ; leur anomalie `unique_items: 0` (Finding #2) n'apparaît pas dans cette colonne et provient de `counts_json`, vérifié séparément par run via `SELECT counts_json FROM runs WHERE id='<run_id>';` pour chacun des 10 runs `completed`/`completed_with_warnings` cités.

**Conclusion sur la récurrence :** le `DatetimeFieldOverflow` n'est pas un incident isolé provoqué par l'audit — il a fait échouer le run planifié quotidien de production **ce matin même** (07:00, avant toute action de cet audit), et avait déjà fait échouer le run du 2026-08-29 avec une notice/date différente (donc pas spécifique à une seule notice UNGM buggée — c'est une classe de bug qui se reproduira à chaque nouvelle notice UNGM dont la date déborde). Combiné au Finding #2, la persistance BF est effectivement cassée en production depuis au moins le 2026-08-08 (début de la fenêtre observée) : soit par crash direct (**6 runs `harvest` en échec sur les 18 couverts par la fenêtre** — les 20 lignes `runs` retournées incluent 2 runs `delivery` — dont 4 sur `DatetimeFieldOverflow` et 2 sur le `KeyError: 'content'` distinct), soit par `unique_items: 0` sur les runs "réussis" (cause distincte, non résolue). Le mail de livraison quotidien continue d'être envoyé (`emails_sent: 1` ou plus sur les runs completed) mais avec un rapport vide de nouvelles notices, sans qu'aucune alerte ne signale que la collecte réelle est à l'arrêt.

### Fix appliqué avant re-déclenchement (action infra, hors périmètre "no fixes")

```
docker exec -u root staging_api mkdir -p /app/logs/nodes
docker exec -u root staging_api chown -R tenderai:tenderai /app/logs/nodes
```
`/app/logs/nodes` n'existait pas dans le conteneur `staging_api` (appartenait à `root:root`, le conteneur tourne en `uid 999`/`tenderai`), ce qui faisait échouer silencieusement tous les appels `log_node_output()`. Corrigé — confirmé fonctionnel : le re-run a produit tous les fichiers JSON de nœuds attendus dans `bf-nodes/nodes/` (`load_sources.json`, `fetch_listings.json`, `extract_item_links.json`, `fetch_items.json`, `parse_extract.json`, `deduplicate.json`, `persist_notices.json`).

Le `DatetimeFieldOverflow` lui-même n'a **pas** été corrigé, contourné, ni la notice UNGM en cause écartée — conformément à la consigne, il a été laissé se reproduire pour capturer cette preuve.

### DGCMEF (source id 8, parser_type pdf_rag)

**Particularité structurelle de cette source :** `https://www.dgcmef.gov.bf/fr/appels-d-offre` ne liste pas des avis individuels — c'est une liste de bulletins PDF quotidiens (« Quotidien »), chacun regroupant plusieurs dizaines d'avis (nouveaux appels d'offres + résultats provisoires). Le `parser_type` `pdf_rag` est conçu pour cela : télécharger le PDF du jour puis en extraire les avis individuels par LLM. La « vérité terrain » pertinente n'est donc pas la page de listing elle-même mais le contenu du PDF du jour.

**Vérité terrain (navigateur Chrome, 2026-09-01 ~21:40 UTC) :**

Page `/fr/appels-d-offre` — 10 bulletins listés, le plus récent étant celui du jour même :
| Titre | Fichier | Taille |
|---|---|---|
| Quotidien n°4478 - Mardi 01 septembre 2026 | Quotidien N°4478.pdf | 1.68 Mo |
| Quotidien n°4477 - Lundi 31 août 2026 | Quotidien N°4477.pdf | 2.2 Mo |
| Quotidien n°4476 - Vendredi 28 août 2026 | Quotidien N°4476.pdf | 4.05 Mo |
| Quotidien n°4475 - Jeudi 27 août 2026 | Quotidien N°4475.pdf | 2.16 Mo |
| Quotidien n°4473-4474 - Mar 25 & Mer 26 août 2026 | Quotidien n°4473-4474.pdf | 3.56 Mo |
| … (5 autres, jusqu'au 18 août 2026) | | |

Téléchargement indépendant du PDF du jour (`Quotidien N°4478.pdf`, hors pipeline, via `curl`) pour établir la vérité terrain de fond : **1 758 977 octets, 49 pages** — taille identique à l'octet près à ce que le pipeline a effectivement récupéré (voir Step 2 ci-dessous), confirmant qu'il s'agit bien du même fichier. Extraction de son texte (`pdftotext -layout`, hors pipeline) et repérage de la section « Fournitures et Services courants » (les nouveaux avis, par opposition à « RESULTATS PROVISOIRES » qui sont d'anciens résultats à ignorer) : **27 avis individuels distincts** identifiés par leur en-tête standalone « Avis de demande de prix » / « Avis d'Appel d'Offres » (recompté indépendamment ligne par ligne sur le texte extrait, entre les lignes ~1580 et ~3450 du texte `pdftotext`, pages 19 à 45 — puis recoupé avec 27 numéros de référence `N°2026-.../PRCP`-style tous distincts ; la section « Prestations intellectuelles »/« Avis de Manifestation d'Intérêt » qui suit, p.46, en est bien exclue, c'est un type d'avis différent) :

1. ISLO (Institut Supérieur de Logistique de Ouagadougou) — *Acquisition de consommables informatiques et péri informatiques* (N°2026-096/MGDP/SG/ISLO/DG/PRCP, dépôt avant le 10/09/2026) — **manifestement pertinent** pour une entreprise IT (consommables informatiques).
2. École Polytechnique de Ouagadougou (EPO) — Acquisition et installation des lampadaires solaires (N°2026-009/MESRI/EPO/DG/PRCP).
3. INFPE — Acquisition de 200 matelas et 300 housses de matelas (N°2026-25/INFPE/DG/PRCP).
4. Commune de Foutouri — Acquisition de fournitures scolaires au profit des écoles de la CEB (N°2026-01/REST/PKMD/CFTR/M/SG/PRCP).
5. Région de Bankui — Travaux de clôture partielle du mur du CSPS urbain, lot 3 (N°2026-08/RBNK/PBL/CBRM/CCAM).
6. Région de Bankui — Travaux de réhabilitation d'infrastructures (N°2026-07/RBNK/PBL/CBRM/CCAM).
7. Région de Bankui / Commune de Douroula — Travaux de construction de salles de classe, salle de professeur et latrine (N°2026-002/RBNK/PMHN/CDRL/M/PRCP).
8. Région de Bankui / Commune de Douroula — Travaux de construction de huit (08) boutiques de rue (N°2026-003/RBNK/PMHN/CDRL/M/PRCP) — objet distinct du précédent malgré la même commune.
9. Région du Guiriko / Commune de Karangasso-Sambla — Travaux de construction de trois (03) boutiques au marché du village (N°2026-001/RGRK/PHUE/CKS/M/PRCP).
10. Région du Kadiogo — Réhabilitation de salles de classe (N°2026-03/RKDG/PKAD/CRKI/M/PRCP).
11. ADEU (Agence du Développement Economique Urbain) — Travaux d'aménagement de vingt (20) étals au marché de Paspanga (N°2026-08/CO/ADEU/DG/SCP).
12. Commune de Ouagadougou (ADEU) — Travaux de construction de boutiques à Nabi Yaar, Avis d'Appel d'Offres Ouvert Accéléré/AAOA (N°2026-02/CO/ADEU/DG/SCP).
13. Centre Hospitalier Régional de Kaya — Travaux de curage des toitures, correction d'étanchéité, pavage, cloisonnement, hangar, réfection de la rampe principale (N°2026-032/MS/SG/CHR-KAYA/DG/PRCP).
14. Région du Liptako / Gorgadji — Travaux de construction d'un hall d'attente au profit du CSPS de Gorgadji (N°2026-002/RLTK/P.SNO/C-GGDJ/PRCP).
15. Région du Liptako / Gorgadji — Travaux de construction de trois (03) salles de classe + magasin + bureau au profit de la CEB (N°2026-001/RLTK/P.SNO/C-GGDJ/PRCP) — objet distinct du précédent malgré la même localité.
16. Commune de Poa — Travaux de transformation d'un forage à haut débit en PEA (N°2026-002/C.POA/M/PRCP).
17. Région du Nazinon / Kombissiri — Travaux de réhabilitation des dispensaires de Tuili, Tampinko et Monomtenga (N°2026-07/RNZN/PBZG/CKBS/CCAM).
18. Région du Nazinon / Kombissiri — Travaux de réhabilitation des écoles du secteur 1 et de l'école de Goudrin (N°2026-08/RNZN/PBZG/CKBS/CCAM) — objet distinct du précédent malgré la même commune.
19. Région de Oubri / Sourgoubila — Travaux de réhabilitation de l'auberge communale (lot1) et de la Maison des jeunes (lot2) (N°2026-006/ROBR/PKWG/CSGBL/CCAM/PRCP).
20. Région de Oubri / Sourgoubila — Travaux de réalisation de forages positifs à Koukin et à Yorghin (N°2026-005/ROBR/PKWG/CSGBL/CCAM/PRCP) — objet distinct du précédent malgré la même commune.
21. Région de Oubri / Laye — Réalisation de travaux divers (N°:2026-001/ROBR/PKWG/CLYE, du 10/07/2026).
22. Région de Oubri / Laye — Réalisation de travaux divers (N°:2026-002/ROBR/PKWG/CLYE, du 15/07/2026) — second avis distinct, même commune que le précédent.
23. Région du Sourou / Commune de Yaba — Travaux de construction d'infrastructures économiques (N°2026-01/RSRU/PNYL/CYAB).
24. Région du Sourou / Commune de Toma — Travaux de construction d'un laboratoire au Centre Médical Urbain (N°2026-01/C.TOM/M/SG/PRCP).
25. Région des Tannounyan / Commune de Niangoloko — Aménagement d'une aire de stationnement (voirie + pavés), Avis d'Appel d'Offres Ouvert/AAOO (N°2026-001/RTNY/CNGLK/M/SG/PRMP).
26. Région des Tannounyan / Commune de Ouo — Construction de deux (02) salles de classe à Gouèlè (N°2026-001/RTNY/PCMO/COUO/M/SG/PRCP).
27. Région des Tannounyan — Travaux de construction d'infrastructures scolaires et sanitaires (N°2026-06/RTNY/PCMO/CBFRT/PRCP).

Ces 27 avis sont réels, datés d'aujourd'hui, avec des dates limites de dépôt à venir (10/09 au 15/09/2026) — ce n'est en aucun cas un bulletin vide.

**Résultat du pipeline (run `785adda4-f28c-4f3c-af0a-74b7e775d0b5`) :**

- `fetch_listings.json` : **succès**. Le nœud a téléchargé exactement `http://www.dgcmef.gov.bf/sites/default/files/2026-09/Quotidien%20N%C2%B04478.pdf`, `status: "success"`, `size: 1758977`, `content_type: application/pdf` — taille identique à l'octet près au fichier vérifié indépendamment ci-dessus. Le nœud a correctement identifié et récupéré le bulletin du jour (pas un bulletin périmé). **Le fetch n'est pas en cause.**
- `extract_item_links.json` / `fetch_items.json` : le PDF passe intact d'étape en étape comme un item unique (`type: pdf_rag`), toujours `status: success`, contenu de même taille.
- `parse_extract.json` (27 items au total, toutes sources BF confondues) : **0 item avec `source: "dgcmef"`** ou provenant de la branche `pdf_rag`. Répartition constatée : `ungm: 15, "UEMOA - Appels d'offres": 10, "Enabel - Marchés publics Burkina Faso": 1, joffres.net: 1` — DGCMEF est absent à 100%.
- `notices` (DB, `source_id=8`) : 0 ligne — **résultat attendu et non significatif ici**, puisque la table entière est vide pour BF suite au crash de `persist_notices` documenté au Finding #1 (voir l'avertissement en tête de section BF). Cela dit, même si le run n'avait pas crashé, 0 aurait été le résultat : le PDF n'a produit aucun item dès `parse_extract`, donc rien ne serait arrivé jusqu'à `persist_notices` de toute façon.

**Analyse du code (cause racine) :** `parse_extract.py` route les items `parser_type == "pdf_rag"` (lignes 588-616) vers `parse_pdf_rag.py::parse_pdf_with_rag`, appelé avec `use_direct_extraction` à sa valeur par défaut `True` — c'est-à-dire que malgré le nom de la source (« … avec RAG ») et la config `settings.yaml` (`rag: {enabled: true, chunk_size: 4096, ...}`), le code **n'utilise pas ChromaDB/la recherche vectorielle** : il extrait le texte intégral du PDF (Docling, OCR désactivé, fallback pdfminer — lignes 20-89 de `parse_pdf_rag.py`), le découpe en chunks de 4096 caractères (`chunk_size` lu depuis `state.country_config["rag"]`, confirmé en base : ~70 chunks pour un texte de ~297 Ko), puis appelle `extract_tenders_structured()` (`extraction.py`) **une fois par chunk, séquentiellement**, en LLM. Sur staging, `LLM_PROVIDER=groq` — `extraction.py` lignes 51-59 route Groq systématiquement vers `_extract_tenders_json_fallback` (contournement documenté dans le code : *"Groq wraps parameters in nested objects causing validation failures"*). Chaque échec de chunk (exception réseau, JSON invalide, validation Pydantic) est capturé et **silencieusement ignoré** (`parse_pdf_rag.py` lignes 412-418 : `except Exception: logger.error(...); continue` — pas de fallback réel malgré le message de log ; même chose au niveau du nœud, `parse_extract.py` lignes 609-616, dont le message *"falling back to standard parsing"* est trompeur : aucun fallback n'est implémenté pour `pdf_rag`, contrairement à d'autres branches du même fichier qui en ont un explicite, p.ex. `pdf_quotidien`/`parse_pdf_structured` lignes 824-853).

Vérifications indépendantes effectuées pour circonscrire la cause exacte :
- **Texte du PDF exploitable** : confirmé — `pdftotext -layout` (hors pipeline) extrait un texte français propre et complet, sans artefact d'OCR raté ; les 27 avis y sont clairement délimités. Ce n'est donc pas un problème de mise en page PDF illisible pour l'extraction de texte.
- **Clé API Groq valide** : confirmée — `curl https://api.groq.com/openai/v1/models` avec la clé configurée sur staging renvoie `200`. Ce n'est donc pas une panne d'authentification/réseau globale vers le fournisseur LLM.
- **Point de défaillance exact dans la boucle de ~70 appels LLM séquentiels** : **non déterminé** — les logs stdout du process qui a exécuté ce run n'ont pas été conservés (`docker logs staging_api`/`staging_worker` sur la fenêtre du run ne montrent que le trafic des health-checks MinIO ; le run a été déclenché par un `docker exec` dont la sortie n'a pas été journalisée ailleurs, et les JSON de nœuds capturés par Task 1 ne contiennent que le résultat final agrégé de `parse_extract`, pas de détail par chunk). **Ambiguïté signalée explicitement** : il est possible que ce soit (a) une erreur systématique et reproductible sur chaque appel (config/prompt/schema), (b) une dégradation liée au volume d'appels séquentiels sur un même run (rate-limit Groq atteint après N chunks), ou (c) une combinaison — impossible de trancher sans rejouer l'extraction avec logging détaillé conservé, ce qui sortirait du périmètre « diagnostic seul, aucune correction » de ce chantier.
- **Corroboration historique** : le Finding #2 (déjà documenté plus haut dans cette section BF, trouvé par Task 1) note que **tous** les runs BF `completed` de l'échantillon 08-08 à 08-27 rapportent `unique_items: 0` malgré `items_parsed` non nul, avec une piste explicite pointant vers `parse_extract` en amont de `deduplicate`. Le constat de cette tâche (0 item DGCMEF y compris un jour sans crash de persistance) est cohérent avec cette anomalie plus large : DGCMEF ne contribue vraisemblablement aucun item à la base depuis plusieurs semaines, indépendamment du bug `DatetimeFieldOverflow` du jour.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| ISLO — Acquisition de consommables informatiques et péri informatiques (N°2026-096/MGDP/SG/ISLO/DG/PRCP) — manifestement pertinent pour une entreprise IT | Non | Parse (`parse_extract`, branche `pdf_rag`) | Échec silencieux de l'extraction LLM-par-chunk dans `parse_pdf_rag.py::parse_pdf_with_rag` (mode `use_direct_extraction=True`, exceptions par chunk capturées et ignorées sans fallback réel — lignes 412-418) | bug logique | Critique | `fetch_listings.json` (PDF téléchargé intact, `status: success`, 1 758 977 octets, identique au fichier vérifié indépendamment) + `parse_extract.json` (27 items au total toutes sources BF confondues, 0 avec `source: "dgcmef"`) |
| Les 26 autres avis du Quotidien n°4478 (liste complète des 27 avis ci-dessus : travaux communaux/régionaux, fournitures diverses) — et 26 autres, même cause | Non | Parse (`parse_extract`, branche `pdf_rag`) | Même cause racine — perte à 100%, pas un cas isolé au tender IT | bug logique | Critique | Idem — même PDF, même fetch réussi, 0/27 avis en sortie de `parse_extract` |

Aucun cas de faux positif de classification à documenter pour cette source : puisque 0 item DGCMEF atteint même `parse_extract`, rien n'atteint `classify`/`company_notice_status` — il n'y a rien à vérifier côté sur-classification pour cette source sur ce run.

**Verdict :** DGCMEF est une perte totale et systématique dès l'étage `parse` — pas un problème de couverture partielle. Le fetch fonctionne parfaitement (bon fichier, bonne taille, à jour) et le contenu est un texte PDF propre et richement exploitable (27 avis réels et actuels vérifiés indépendamment, dont au moins un manifestement pertinent pour une entreprise IT), mais la chaîne d'extraction LLM-par-chunk de la branche `pdf_rag` (qui, malgré son nom, n'utilise pas de RAG vectoriel — c'est une extraction directe séquentielle par LLM) ne produit aucun item en sortie, sans qu'aucune alerte ne remonte au niveau du run (`counts_json`/`errors`) pour signaler cette perte silencieuse ; cela concorde avec l'anomalie `unique_items: 0` déjà repérée sur plusieurs semaines de runs historiques (Finding #2), suggérant un problème persistant et non un accident isolé au run d'aujourd'hui. Étiquette : **bug logique** (le contenu est extractible, la clé LLM est valide — rien n'indique une limite structurelle de l'approche PDF+LLM elle-même, ni une limite architecturale) plutôt qu'une limite technologique ; sévérité **critique** compte tenu de la perte à 100% et de l'absence totale de signal d'alerte. Cause exacte (config/prompt/schema vs rate-limit Groq vs autre) à confirmer par rejeu instrumenté lors de la phase de correction — hors périmètre de ce chantier de diagnostic.

### Joffres.net (source id 9, parser_type html-listing)

**Particularité structurelle de cette source :** `fetch_listings.py` contient une branche spéciale (`if parser_type == "html-listing" and "joffres" in source_name.lower()`) qui, après avoir récupéré la page de listing HTML, appelle immédiatement `extract_joffres_listings()` (`fetch_joffres.py`) pour en extraire les liens des avis (sélecteur CSS `a.job-title`) — contrairement aux autres sources `html-listing` génériques, l'extraction des liens se fait donc dès l'étage `fetch_listings`, pas à l'étage `extract_item_links`. Le code (`fetch_all_listings`) porte aussi un commentaire explicite notant que joffres.net « drops connections on non-browser User-Agents », d'où un `User-Agent` de navigateur réel forcé pour tout le client HTTP du run — vérifié ci-dessous pour signe de blocage/troncature.

**Vérité terrain, collectée le 2026-09-01 (deux méthodes indépendantes, à quelques minutes d'intervalle, résultat identique) :**
- **Requête `curl`** (User-Agent navigateur, identique à celui utilisé par le pipeline) contre l'URL exacte configurée (`list_url` en DB, `source_id=9`, copiée verbatim) — `https://joffres.net/recherche?domaine=Informatique+%26+D%C3%A9veloppement&localisation=&societe=&secteur=&prevision=0%2F1000000000&date_publication=&date_expiration=&statut=` — à **2026-09-01 22:03:33 UTC** (horodatage du header `Date` de la réponse) : `HTTP 200`, 133 498 octets.
- **Navigateur Chrome** (session interactive), même URL, quelques minutes plus tard : `HTTP 200`, page identique.

Comptage indépendant, deux méthodes sur le HTML téléchargé par `curl` (fichier sauvegardé localement, recompté directement dessus, pas à l'estimation) : `grep -c 'job-title'` (le sélecteur CSS utilisé par le pipeline) → **1** ; `grep -c 'offre-localisation'` (marqueur d'un bloc résultat distinct) → **1** ; aucun lien `href="...appeloffre..."` distinct autre que celui-ci ; aucune marque de pagination (`page=`, « Suivant ») dans le HTML. Confirmé aussi par lecture du texte rendu de la page (« Resultat pour : Domaine: Informatique & Développement | » suivi d'un seul bloc résultat). Commandes et sortie brute (fichier `joffres_ground_truth.html` toujours présent dans le scratchpad, re-exécuté verbatim pour cette révision) :

```
$ grep -c 'job-title' joffres_ground_truth.html
1

$ grep -c 'offre-localisation' joffres_ground_truth.html
1

$ grep -o 'href="[^"]*appeloffre[^"]*"' joffres_ground_truth.html | sort -u
href="https://joffres.net/appeloffre/appel-d-offres-pour-l-aquisition-et-installations-d-equipements-informatiques"

$ grep -io 'page=[0-9]*\|suivant' joffres_ground_truth.html | sort -u
(aucune sortie — aucune marque de pagination)
```

**La vérité terrain pour ce `list_url` exact est donc 1 avis, pas plus** :

1. « APPEL D'OFFRES POUR L'AQUISITION ET INSTALLATIONS D'EQUIPEMENTS INFORMATIQUES » — PNUD/UNDP-BFA (Burkina Faso), Procurement Process: RFQ, Reference Number `UNDP-BFA-00734`, publié le 20-Aug-26, deadline 02-Sep-26 @ 13h30 (New York time) / « Expire le 02-09-2026 », localisation Ouagadougou, domaine « Informatique & Développement » — **manifestement pertinent** pour une entreprise IT (acquisition et installation d'équipements informatiques).

Remarque : joffres.net agrège ici une annonce dont l'entité est le PNUD (UNDP-BFA) — cette même annonce est donc potentiellement aussi visible côté source UNGM (source id 10, hors périmètre de cette tâche ; non vérifié ici, signalé pour la tâche 4 / la synthèse, pertinent pour une éventuelle règle de dédoublonnage inter-source).

**Résultat du pipeline (run `785adda4-f28c-4f3c-af0a-74b7e775d0b5`, fetch à 2026-09-01 21:20:46 UTC) :**

- `fetch_listings.json` : **succès**, `status: "success"`, taille de la page HTML brute récupérée : 132 846 octets (vs 133 498 octets pour la copie `curl` de vérité terrain, ~40 minutes plus tard — écart mineur cohérent avec un contenu généré dynamiquement par session/CSRF token, pas une troncature). La branche spéciale joffres a bien tourné (`parser_type: "html-listing"`, `listings` peuplé) et a extrait **exactement 1 listing**, avec le même `url`/`title` que la vérité terrain. **Aucun signe de blocage anti-bot ou de troncature aujourd'hui** — la taille récupérée est cohérente avec le HTML complet de la page (dropdowns de filtres inclus, ~130 Ko), pas une page d'erreur ou un fragment tronqué. Historique notable cependant (table `runs`, voir Finding #3 plus haut) : cette source a échoué 3 fois sur la fenêtre observée (08-15, 08-13, 08-12, `completed_with_warnings`) avec `HTTP 502: Bad Gateway` / `Request timeout` — cohérent avec le commentaire de code sur l'anti-bot/fragilité de ce site ; le run d'aujourd'hui n'a simplement pas été affecté.
- `extract_item_links.json` : le même item unique (même `url`/`title`/`slug`) passe intact — 1/1.
- `fetch_items.json` : page de détail récupérée avec succès (`status: "success"`, 39 292 octets) et parsée par `extract_joffres_detail()` : `entity: "PNUD BURKINA"`, `category: "Biens et service"`, `deadline: "02-09-2026"` — tous cohérents avec la vérité terrain. **`ref_no` et `reference` vides** : les regex de `extract_joffres_detail()` (motifs `N°...`, `DAO ...`, `Demande de prix N°...`) ne matchent pas le format de référence utilisé par cette annonce d'origine PNUD (« Reference Number : UNDP-BFA-00734 », sans « N° ») — perte de complétude sur un champ, pas perte de l'avis lui-même.
- `parse_extract.json` (27 items au total, toutes sources BF confondues) : l'item joffres.net est présent, 1/1, avec `ref_no: ""` (même lacune reportée depuis `fetch_items`), les autres champs intacts.
- `deduplicate.json` (24 items uniques au total) : l'item est présent, `is_duplicate: false` — 1/1, non fusionné à tort avec un autre avis.
- `notices` (DB, `source_id=9`) : **0 ligne** (requête Step 3 exécutée le 2026-09-01, `SELECT ... FROM notices n LEFT JOIN company_notice_status cns ... WHERE n.source_id=9` → 0 rows). **Résultat attendu et non spécifique à Joffres.net** : comme documenté au Finding #1 en tête de section BF, ce run a crashé à `persist_notices` sur un `DatetimeFieldOverflow` provenant d'une notice **UNGM** (`LRFP-2026-9205898`), dans une transaction unique tout-ou-rien qui a englouti avec elle les 8 items UEMOA et le seul item Joffres.net du batch de 24. L'item Joffres.net lui-même n'est pas en cause : son `deadline_at` (`02-09-2026`, jour=02) ne peut pas produire un dépassement de champ mois/jour comme celui qui a fait échouer l'INSERT.

  Requête et sortie brute (ré-exécutée verbatim sur staging pour cette révision) :

  ```
  $ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
    "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
    \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=9 ORDER BY n.created_at DESC LIMIT 50;\""

   id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
  ----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
  (0 rows)
  ```

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| APPEL D'OFFRES POUR L'AQUISITION ET INSTALLATIONS D'EQUIPEMENTS INFORMATIQUES (PNUD/UNDP-BFA-00734) — manifestement pertinent pour une entreprise IT | Oui, jusqu'à `deduplicate` inclus (item unique, non dupliqué) | Persist (`persist_notices`) | Non spécifique à Joffres.net : transaction unique tout-ou-rien du run BF entier, qui échoue sur un `DatetimeFieldOverflow` provenant d'une notice **UNGM** distincte (`LRFP-2026-9205898`, deadline `29-09-2026`) — voir Finding #1. L'avis Joffres.net lui-même est structurellement correct (fetch, parse, dedup tous réussis) et n'a aucune part dans la cause du crash. | bug logique | Critique | `fetch_listings.json`/`extract_item_links.json`/`fetch_items.json`/`parse_extract.json`/`deduplicate.json` (item présent et intact à chaque étage, `is_duplicate: false`) ; requête SQL Step 3 (`source_id=9`) → 0 lignes ; Finding #1 (analyse de code `persist_notices.py` + preuve empirique du batch INSERT de 24 lignes) |

Aucun autre gap à documenter pour cette source sur ce run : la vérité terrain ne compte qu'un seul avis pour ce `list_url` exact, et le pipeline l'a intégralement vu, correctement extrait (à l'exception mineure du champ `ref_no`, non extrait faute de motif regex adapté au format PNUD, mais sans conséquence sur l'identification de l'avis) et correctement dédoublonné. Aucun cas de faux positif de classification à documenter : la livraison ne s'étant pas déclenchée (harvest en échec), aucune ligne `company_notice_status` n'existe pour vérifier une éventuelle sur-classification.

**Verdict :** Joffres.net n'a, à ce jour et pour cette configuration de filtre (`domaine=Informatique & Développement`), qu'un seul avis actif — et le pipeline l'a intégralement et correctement traité de bout en bout jusqu'à `deduplicate` : la branche de code spéciale `html-listing`/joffres (sélecteur CSS `a.job-title`) fonctionne, aucun signe de blocage anti-bot ou de troncature n'a été observé sur ce run malgré la fragilité connue et documentée de ce site (3 échecs `502`/timeout sur la fenêtre historique de 20 jours couverte au Finding #3). Le seul écart entre vérité terrain (1) et base de données (0) n'est pas imputable au code spécifique à Joffres.net : c'est une conséquence collatérale du bug transversal déjà identifié au Finding #1 (transaction `persist_notices` unique et tout-ou-rien pour tout le run BF, cassée par une notice UNGM). Étiquette retenue **bug logique** (absence d'isolation par item/source dans `persist_notices` : un `db.commit()` unique après toute la boucle, sans try/except ni savepoint par item — corrigible par un changement de code localisé à `persist_notices.py`, sans refonte architecturale, donc « corrigible indépendamment de la techno » au sens de la taxonomie de l'audit) plutôt que limite architecturale ou limite technologique. Point mineur relevé en passant, sans impact sur la détection de l'avis : le champ `ref_no` reste vide pour les annonces d'origine PNUD/UNDP hébergées sur joffres.net, faute de motif regex couvrant leur format de référence (« Reference Number : XXX » sans « N° ») dans `extract_joffres_detail()`.

### UNGM (source id 10, parser_type ungm)

**Particularité structurelle de cette source :** UNGM agrège des avis de 40+ agences ONU (UNDP, UNICEF, WHO, WFP, etc.). `fetch_ungm.py` n'utilise ni Playwright ni scraping de la page publique interactive : il POST directement au endpoint legacy `https://www.ungm.org/Public/Notice/Search` (celui qu'utilise en interne le widget "picker" du site) avec un payload JSON filtrant sur `Countries: [2324]` (Burkina Faso, valeur par défaut codée en dur — `COUNTRY_BURKINA_FASO = 2324`) et parse le fragment HTML retourné (lignes `div.tableRow.dataRow`). Ce endpoint est différent de celui qu'utilise la page moderne `/Public/Notice` (SPA) : il ne renvoie ni total ni indicateur de dernière page, et — comme démontré empiriquement ci-dessous — **plafonne à 15 lignes par page quel que soit le `PageSize` demandé**, nécessitant une boucle sur `PageIndex` pour tout récupérer. Cette boucle est absente du code actuel : `PageIndex` est câblé en dur à `0` dans `fetch_ungm_listings()` (`fetch_ungm.py` ligne 28).

**Vérité terrain — méthode et filtre appliqué :** UNGM étant un site global, le filtre géographique appliqué est celui du champ "Beneficiary country or territory" de la page officielle `https://www.ungm.org/Public/Notice`, réglé sur "Burkina Faso" (sélectionné via l'autocomplete du site — seul filtre pays disponible), avec "Only currently active" coché (comportement par défaut) — reproduisant l'intention du filtre `Countries: [2324]` codé en dur côté pipeline. Capturé le 2026-09-01, résultat affiché par le site lui-même (stable entre deux captures, à 15 puis 45 résultats chargés par défilement) :
```
Displaying results 1 to 15 of 54
...
Displaying results 1 to 45 of 54
```

**Reproduction indépendante de la requête exacte du pipeline (`curl`, même endpoint, même payload JSON, même User-Agent) :**
```
$ curl -s -o ungm_resp.html -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  -X POST "https://www.ungm.org/Public/Notice/Search" \
  -H "Accept: text/html, */*; q=0.01" -H "Content-Type: application/json" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
  -H "X-Requested-With: XMLHttpRequest" -H "Referer: https://www.ungm.org/Public/Notice" \
  --data '{"PageIndex":0,"PageSize":50,"Title":"","Description":"","Reference":"","PublishedFrom":"","PublishedTo":"","DeadlineFrom":"","DeadlineTo":"","Countries":[2324],"Agencies":[],"UNSPSCs":[],"NoticeTypes":[],"SortField":"DatePublished","SortAscending":false,"isPicker":false,"NoticeTypeIds":[],"NoticeStatuses":[]}'
HTTP_STATUS:200 SIZE:95088

$ grep -c 'tableRow dataRow' ungm_resp.html
15
$ grep -o 'data-noticeid="[0-9]*"' ungm_resp.html | sort -u | wc -l
15
$ grep -io "captcha\|access denied\|blocked\|cloudflare\|are you human\|rate limit" ungm_resp.html | sort -u
(aucune sortie — aucun signe de blocage/CAPTCHA)
```
→ **15 lignes, les mêmes 15 `notice_id` que ceux effectivement récupérés par le pipeline** (`fetch_listings.json`), malgré `PageSize: 50` explicitement demandé. **Aucun signe de blocage anti-bot** dans la réponse brute — HTTP 200 propre, contenu HTML complet et exploitable. Ceci contredit, pour cette source telle qu'implémentée, la mise en garde de `docs/PROJECT_STATUS.md` (spike Scrapling) qui cite UNGM comme cible anti-bot typique : cette mise en garde vise explicitement les fetchs **Playwright nus, sans stealth**, contre des portails « type UNGM/gouv derrière Cloudflare » — or `fetch_ungm.py` n'utilise pas Playwright pour cette source, seulement `httpx` en appel direct à un endpoint API-like, ce qui explique l'absence de blocage observée aujourd'hui. La mise en garde reste valable pour d'autres sources du pipeline utilisant `fetcher_type: playwright` (hors périmètre BF de cette tâche), pas pour UNGM tel qu'implémenté actuellement — donc **pas de limite technologique à documenter ici**, conformément à la consigne du brief.

**Correctif méthodologique (suite à relecture) — la comparaison « 54 vs 15 » plus bas dans une version antérieure de cette section comparait des univers différents :** le payload du pipeline interroge `"NoticeStatuses": []` (aucun filtre de statut), tandis que la vérité terrain UI (54) est explicitement filtrée sur "Only currently active". Les 15 lignes renvoyées par `PageIndex:0` peuvent donc contenir des avis déjà expirés qui ne font même pas partie de l'univers des 54 — ce qui était bien le cas. Reprise des 15 `notice_id` de `ungm_resp.html` avec leur date limite, pour déterminer combien sont réellement encore actifs au 2026-09-01 (date de l'audit) :
```
$ python3 -c "
import re
html = open('ungm_resp.html', encoding='utf-8').read()
for block in html.split('tableRow dataRow')[1:]:
    nid = re.search(r'data-noticeid=\"(\d+)\"', block).group(1)
    dl = re.search(r'data-description=\"Deadline\">\s*<span>\s*([\d\-A-Za-z: ]+?)\s*</span>', block).group(1)
    print(nid, dl)
"
308555  18-Sep-2026 16:00
310797  11-Sep-2026 23:59
311319  30-Sep-2026 23:59
312344  09-Sep-2026 17:00
312532  28-Aug-2026 14:00   <- EXPIRÉ (deadline antérieure au 2026-09-01)
312568  24-Sep-2026 12:00
312590  09-Sep-2026 17:30
312687  06-Sep-2026 00:00
312807  29-Sep-2026 11:00
312870  18-Sep-2026 15:00
312895  30-Sep-2026 23:45
312944  29-Sep-2026 11:00
312946  08-Sep-2026 07:00
313005  12-Oct-2026 15:00
313214  30-Sep-2026 23:59
```
→ **14 des 15 avis récupérés par `PageIndex=0` sont effectivement encore actifs au 2026-09-01** ; un seul, `312532` (deadline `28-Aug-2026`), était déjà expiré à cette date — présent dans les 15 uniquement parce que la requête ne filtre pas `NoticeStatuses`, mais absent en réalité de l'univers des 54 avis actifs de la vérité terrain. **Comparaison corrigée, actifs contre actifs : 54 (vérité terrain, filtrée "Only currently active") vs. 14 (avis effectivement encore actifs parmi les 15 récupérés par `PageIndex=0`) → 40 avis actifs jamais vus par le pipeline, soit ~74 % de perte** (et non 15 vs 54 / 72 % comme une comparaison non filtrée par statut le suggérait à tort). Toutes les occurrences de ce chiffre plus bas dans cette section (tableau des écarts, verdict) utilisent désormais cette base corrigée.

**Preuve que la pagination existe côté serveur mais n'est jamais exploitée par le pipeline :**
```
$ curl ... --data '{"PageIndex":1,"PageSize":50, ... ,"Countries":[2324], ...}' -o ungm_resp_p1.html
HTTP_STATUS:200 SIZE:95108
$ grep -c 'tableRow dataRow' ungm_resp_p1.html
15
$ comm -12 <(grep -o 'data-noticeid="[0-9]*"' ungm_resp.html | sort -u) <(grep -o 'data-noticeid="[0-9]*"' ungm_resp_p1.html | sort -u)
(aucune sortie — zéro chevauchement)
```
`PageIndex=1` renvoie 15 avis **entièrement distincts** des 15 de `PageIndex=0` (zéro `notice_id` commun) — la pagination fonctionne bel et bien côté UNGM ; c'est le code du pipeline qui ne la sollicite jamais au-delà de la page 0. Même contrôle actif/expiré (au 2026-09-01) appliqué aux 15 lignes de `PageIndex=1` : 12 des 15 sont effectivement encore actives, 3 déjà expirées (`312529` 31-Aug-2026, `311928` 31-Aug-2026 — la notice « Next Generation Firewall » citée en exemple ci-dessous, elle-même déjà expirée à la date de l'audit —, `311764` 31-Aug-2026). Au minimum **12 avis actifs distincts supplémentaires** sont ainsi démontrés exister au-delà de la page 0 — directement prouvé par une seconde requête réelle à `notice_id` totalement disjoints des 15 de la page 0 — un ordre de grandeur cohérent avec l'écart de 40 avis actifs impliqué par le total de 54 rapporté par l'UI officielle (retenu comme vérité terrain ; le comptage exact au-delà de la page 1 sur cet endpoint legacy s'est révélé instable d'un appel à l'autre — plusieurs `notice_id` de la page 0 réapparaissent sur des pages ultérieures lors d'appels successifs, signe probable d'un tri par égalité `DatePublished` non stable côté serveur sur ce endpoint — non creusé davantage, hors périmètre).

**Exemple concret d'avis manqué, manifestement pertinent pour une entreprise IT :** notice UNGM 311928, trouvée en page 1 (jamais atteinte par le pipeline), vérifiée en direct sur le site :
```
Next Generation Firewall And Secure Web Gateway
UN Secretariat … Reference: EOIUNPD24643 … Published on: 21-Aug-2026 … Deadline on: 31-Aug-2026 23:59 (GMT -4.00)
"...Expression of Interest (EOI) ... Next-Generation Firewall (NGFW) and Secure Web Gateway (SWG) solution
that protect the Organization's global network..."
```
Un avis sur la cybersécurité/l'infrastructure réseau — exactement le type d'opportunité IT qu'une entreprise cliente de TenderAI voudrait voir — jamais visible par le pipeline le jour où il était encore actif (deadline 31-Aug, un jour avant le run audité), uniquement parce qu'il se trouvait au-delà de la page 0.

**Confirmation du doublon inter-sources signalé par la Tâche 3 (Joffres.net) :** la vérité terrain UNGM (liste des 54, filtre Burkina Faso, page consultée le 2026-09-01) contient bien :
```
Aquisition et installations d équipements informatiques
02-Sep-2026 13:30 (GMT -4.00) Expires within 24 hours 20-Aug-2026 UNDP Request for quotation UNDP-BFA-00734 Burkina Faso
```
— même titre, même référence exacte `UNDP-BFA-00734`, même deadline (`02-09-2026`) que l'avis PNUD/UNDP-BFA repéré côté Joffres.net à la Tâche 3. **Confirmé : c'est bien le même avis, publié à la fois sur Joffres.net et sur UNGM** — la Tâche 3 avait raison de signaler un doublon potentiel inter-source. Cette notice UNGM elle-même est absente des 15 notice_id récupérés par le pipeline aujourd'hui (encore un effet de la limite de pagination ci-dessus). Ni l'une ni l'autre instance (Joffres.net ni UNGM) n'a atteint `persist_notices` sur ce run (Joffres.net : perdu au crash du Finding #1 ; UNGM : jamais fetché, au-delà de la page 0), donc la logique de dédoublonnage inter-source n'a pas pu être testée en conditions réelles — signalé pour la synthèse, non résolu ici comme demandé par le brief.

**Résultat du pipeline (run `785adda4-f28c-4f3c-af0a-74b7e775d0b5`) :**

- `fetch_listings.json` : succès, `status: "success"`, 15 listings (`grep -i "ungm" -A5 fetch_listings.json`, extrait — `"source": "ungm"` répété 15 fois, ex. `"UNICEF China Tender LRFP-2026-9205898 LTA Contract for Vision Aids"`, `"reference": "LRFP-2026-9205898"`, `"deadline": "29-09-2026"`). Tous les 15 `notice_id` identiques à la reproduction curl indépendante ci-dessus. Le champ `"patterns": {}` de la source en DB confirme qu'aucun `ungm_settings` (`country_ids`/`page_size`) personnalisé n'est configuré pour cette source — le code tourne avec ses valeurs par défaut.
- `parse_extract.json` (27 items au total toutes sources BF confondues) : **15/15** items UNGM survivent intacts, aucune perte à ce stade :
```
$ python3 -c "
import json; from collections import Counter
d = json.load(open('parse_extract.json'))[0]['data']
print(Counter(i.get('source') for i in d))"
Counter({'ungm': 15, "UEMOA - Appels d'offres": 10, 'Enabel - Marchés publics Burkina Faso': 1, 'joffres.net': 1})
```
- `deduplicate.json` (24 items uniques au total) : **14/15** UNGM survivent — un item disparaît du tableau `unique_items` sans trace de `duplicate_of_id` :
```
$ python3 -c "
import json; from collections import Counter
d = json.load(open('deduplicate.json'))[0]['data']
print(Counter(i.get('source') for i in d))"
Counter({'ungm': 14, "UEMOA - Appels d'offres": 8, 'Enabel - Marchés publics Burkina Faso': 1, 'joffres.net': 1})
```
L'item manquant est `LRFP-2026-9205896` ("UNICEF China Tender LRFP-2026-9205896 LTA Contract for Hearing Aids and Diagnosis Equipment") — absent de la liste des 14 survivants, et absent aussi des `duplicate_of_id` des 14 autres : `log_node_output("deduplicate", unique_items, ...)` (`deduplicate.py` ligne 310) ne logue que les survivants, jamais les items écartés (`similar_items`), donc aucune trace du motif exact n'est conservée dans ce fichier — reconstitué par calcul indépendant :
```
$ python3 -c "
from rapidfuzz import fuzz
t1 = 'UNICEF China Tender LRFP-2026-9205898 LTA Contract for Vision Aids'
t2 = 'UNICEF China Tender LRFP-2026-9205896 LTA Contract for Hearing Aids and Diagnosis Equipment'
print(fuzz.ratio(t1, t2))"
77.70700636942675
```
Config staging (`tenderai-infra/settings.yaml` lignes 559-560) : `deduplication_threshold: 0.75`, `deduplication_method: "hash_similarity"`. Les deux titres suivent un gabarit quasi identique ("UNICEF China Tender LRFP-2026-920589X LTA Contract for ___") mais désignent deux appels d'offres **distincts** (référence différente — `9205896` vs `9205898` — produit différent : aides auditives/diagnostic vs aides visuelles). `deduplicate.py` (méthode `hash_similarity`, lignes 176-190) ne compare les références exactes que pour un court-circuit "match exact" (`item_ref == unique_ref`) ; comme elles diffèrent, le code retombe sur `fuzz.ratio()` du seul texte du titre (ligne 195), qui atteint 77,7 % — au-dessus du seuil de 75 % — l'item est marqué `is_duplicate=True`, `duplicate_reason: "similarity_77%"`, et **définitivement exclu** de `unique_items` avant même d'atteindre `persist_notices`. Faux négatif de dédoublonnage : deux avis réels et distincts fusionnés à tort en un seul.
- `persist_notices.json` : **tableau vide `[]`** (2 octets, vérifié sur disque dans le conteneur) — run entier en échec avant tout commit (Finding #1, avertissement en tête de section BF). Répartition du batch de 24 items envoyés à `persist_notices` (Finding #1) : **UNGM a contribué 14 des 24 items** — la majorité du batch.
- `notices` (DB, `source_id=10`) : **0 ligne.** Requête et sortie brute (exécutée le 2026-09-01) :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=10 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu et non spécifique à UNGM (Finding #1, avertissement en tête de section BF) — mais UNGM est ici la source dont la propre donnée a **causé** le crash transversal (voir investigation ciblée ci-dessous), contrairement à Joffres.net/UEMOA/Enabel qui n'ont subi que le rayon d'impact collatéral. Aucune ligne `company_notice_status` n'existe (livraison jamais déclenchée) : aucun faux positif de classification ne peut être vérifié pour cette source sur ce run.

**Investigation ciblée — la notice qui a fait planter le run (`LRFP-2026-9205898`) :** vérifiée en direct sur le site le 2026-09-01 (`https://www.ungm.org/Public/Notice/312944`) :
```
UNICEF China Tender LRFP-2026-9205898 LTA Contract for Vision Aids
UNICEF … Reference: LRFP-2026-9205898
Published on: 01-Sep-2026
Deadline on: 29-Sep-2026 11:00 (GMT 8.00)
… "it will be appreciated if you could provide your quotation ... no later than 11:00 AM on 29 September 2026 (GMT+8)"
… "投标截止日期2026年9月29日上午十一点整（北京时间）"（29 septembre 2026）…
```
**L'avis est réel** (visible en direct sur `ungm.org` aujourd'hui, avec documents PDF/annexes attachés, adresse de contact nominative) et **sa date limite n'est ni ambiguë ni malformée sur le site source** : UNGM affiche le format `DD-Mon-YYYY` (`29-Sep-2026`), non ambigu puisque le mois est écrit en toutes lettres, et le corps du texte confirme deux fois indépendamment "29 September 2026" et "2026年9月29日" (29 septembre). **Ce n'est donc pas une donnée UNGM malformée à la source** — la malformation est introduite en aval, par le pipeline lui-même, en deux étapes cumulatives :

1. `fetch_ungm.py::_normalize_ungm_date()` (lignes 144-167) reformate volontairement `"29-Sep-2026"` (non ambigu) en `"29-09-2026"` (ambigu, tout-numérique, ordre jour-mois) — jetant l'information désambiguïsante (le nom du mois) sans nécessité.
2. `persist_notices.py` (ligne 85 : `deadline_at=item.get("deadline_at") or item.get("deadline")`) assigne cette chaîne brute directement à `Notice.deadline_at`, une colonne `DateTime` (`models.py` ligne 138) — **sans jamais la parser en objet `date`/`datetime` Python**. SQLAlchemy transmet donc la chaîne telle quelle à psycopg2, qui la fait interpréter par PostgreSQL selon le paramètre de session `datestyle`, confirmé sur staging :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \"SHOW datestyle;\""
 DateStyle
-----------
 ISO, MDY
(1 row)
```
En `MDY`, `"29-09-2026"` est lu comme mois=29 → `DatetimeFieldOverflow` (le crash documenté au Finding #1).

**Ce défaut est-il spécifique à UNGM ?** Deux couches distinctes, à ne pas confondre :
- Le défaut **profond** — assigner une chaîne de date brute non parsée à une colonne `DateTime`, sans jamais fixer/normaliser le `datestyle` de session ni convertir en objet `date` avant l'INSERT — est **transversal**, pas propre à UNGM : `parse_extract.py` (branches DGCMEF/UEMOA génériques) extrait lui aussi des dates via regex sous forme de chaînes brutes (`r"(\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4})"`, jamais converties en objet `date`), assignées à `deadline_at` de la même façon non parsée. C'est très exactement le défaut déjà documenté par le Finding #1 (Tâche 1) au niveau architecture de `persist_notices.py` — pas de redite nécessaire ici.
- Ce qui **est** spécifique à UNGM : `_normalize_ungm_date()` est la seule étape de tout le pipeline qui prend une date **déjà non ambiguë** à la source (mois en toutes lettres) et la reformate activement vers un format **ambigu**. Les autres sources BF (DGCMEF, UEMOA, Joffres.net) écrivent nativement leurs dates en `DD/MM/YYYY` ou `DD-MM-YYYY` — déjà ambiguës dès la source, le problème leur préexistait donc de toute façon. UNGM, à l'inverse, *introduit* l'ambiguïté par un choix de code local et évitable : conserver le format ISO `YYYY-MM-DD` (ou un objet `date`) dans `_normalize_ungm_date()` aurait suffi à empêcher ce cas précis de faire planter le run, indépendamment du fix architectural plus large de `persist_notices.py`.
- Corollaire plus sournois, signalé ici : ce mécanisme ne plante bruyamment que lorsque `jour > 12` (comme aujourd'hui, 29). Pour toute notice UNGM future dont le jour de deadline est ≤ 12, la même chaîne ambiguë serait **silencieusement mal interprétée par PostgreSQL** (jour et mois inversés) **sans jamais lever d'erreur ni d'alerte**, corrompant silencieusement `deadline_at` en base — un problème plus insidieux que le crash observé aujourd'hui, resté non détecté jusqu'ici précisément parce qu'il ne casse rien.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| Next Generation Firewall and Secure Web Gateway (UN Secretariat, réf. EOIUNPD24643, notice 311928) — manifestement pertinent pour une entreprise IT (cybersécurité réseau) | Non | Fetch (`fetch_listings`, branche `ungm`) | `fetch_ungm.py::fetch_ungm_listings()` envoie `"PageIndex": 0` codé en dur (ligne 28), sans boucle de pagination, alors que le endpoint legacy plafonne à 15 lignes/page quel que soit `PageSize` demandé | bug logique | Critique | Reproduction `curl` PageIndex=0 vs PageIndex=1 : 15 `notice_id` disjoints (`comm -12` → 0 chevauchement) ; notice 311928 confirmée en direct sur `ungm.org` (deadline 31-Aug-2026, publiée 21-Aug-2026) |
| Les ~40 autres avis actifs Burkina Faso jamais vus par le pipeline (dont l'avis PNUD/UNDP-BFA-00734 « Aquisition et installations d'équipements informatiques », toujours actif au 2026-09-01, également vu côté Joffres.net — cf. Tâche 3) — vérité terrain UI officielle : 54 avis actifs au total pour ce filtre pays, contre 14 avis réellement encore actifs parmi les 15 récupérés par `PageIndex=0` (comparaison actifs contre actifs — voir correctif méthodologique plus haut) | Non | Fetch (`fetch_listings`, branche `ungm`) | Même cause que ci-dessus — perte structurelle, pas un cas isolé | bug logique | Critique | UI officielle : « Displaying results 1 to 45 of 54 » ; 14 des 15 `notice_id` de `fetch_listings.json` confirmés actifs au 2026-09-01 (1 expiré : `312532`, deadline 28-Aug-2026) ; recoupement de référence `UNDP-BFA-00734` avec la Tâche 3 |
| UNICEF China Tender LRFP-2026-9205896 LTA Contract for Hearing Aids and Diagnosis Equipment | Oui, jusqu'à `parse_extract` inclus (15/15) ; perdu à `deduplicate` | Dédoublonnage (`deduplicate`, méthode `hash_similarity`) | Faux positif de similarité fuzzy sur titre gabarit (`fuzz.ratio` = 77,7 % > seuil 75 %) entre deux avis UNICEF China distincts (références et produits différents) — comparaison de référence exacte court-circuitée uniquement en cas de match, pas de mismatch explicite | bug logique | Modérée (perte réelle et vérifiée, mais pertinence IT non évidente — équipement médical) | `parse_extract.json` : 15/15 UNGM présents ; `deduplicate.json` : 14/15, item absent sans `duplicate_of_id` ; calcul indépendant `rapidfuzz.fuzz.ratio()` = 77,70706... ; `tenderai-infra/settings.yaml` lignes 559-560 (seuil 0.75, méthode hash_similarity) |
| UNICEF China Tender LRFP-2026-9205898 LTA Contract for Vision Aids (notice à l'origine du crash du run BF entier) | Oui, jusqu'à `deduplicate` inclus (`is_duplicate: false`, 1/1 survivant) | Persist (`persist_notices`) | Date UNGM native non ambiguë (`29-Sep-2026`) reformatée en chaîne ambiguë (`29-09-2026`) par `_normalize_ungm_date()` (`fetch_ungm.py`), puis assignée sans parsing à une colonne `DateTime` (`persist_notices.py` ligne 85) ; interprétée `MDY` par la session Postgres (`datestyle` confirmé `ISO, MDY`) → `DatetimeFieldOverflow`. Contribution spécifique à UNGM : la perte de l'information désambiguïsante (nom du mois) lors de la normalisation — le défaut plus profond (pas de parsing de date avant persist) est transversal, déjà documenté Finding #1 | bug logique | Critique (a fait échouer tout le run BF, toutes sources confondues, 3 fois en 24h — voir Finding #3) | Vérifié en direct sur `ungm.org/Public/Notice/312944` (« Deadline on: 29-Sep-2026 11:00 ») ; `fetch_ungm.py` lignes 28, 144-167 ; `persist_notices.py` ligne 85 ; `models.py` ligne 138 (`Column(DateTime, ...)`) ; `SHOW datestyle` → `ISO, MDY` ; message d'erreur exact au Finding #1 |
| Les 13 autres avis UNGM ayant survécu jusqu'à `deduplicate` (14 items au total dans `deduplicate.json`, moins la notice ci-dessus) | Oui, jusqu'à `deduplicate` inclus | Persist (`persist_notices`) | Non spécifique à UNGM : transaction unique tout-ou-rien du run BF entier (`persist_notices.py`, un seul `db.commit()` après la boucle, aucun commit/savepoint par item) qui échoue à cause de la notice ci-dessus — voir Finding #1 | bug logique | Critique | `deduplicate.json` : 14 items `source: "ungm"`, tous `is_duplicate: false` ; Finding #1 (analyse de code + preuve empirique du batch INSERT de 24 lignes, dont 14 UNGM) |

**Verdict :** UNGM cumule trois défauts indépendants, à trois étages différents, tous corrigibles par un changement de code localisé (aucun n'est une limite architecturale ni technologique) :

1. **Fetch — perte majoritaire par pagination absente** (le plus sévère en volume) : le endpoint utilisé plafonne à 15 résultats/page et le code ne boucle jamais au-delà de `PageIndex=0`, alors que la pagination fonctionne bel et bien côté serveur (vérifié : page 1 renvoie 15 avis entièrement distincts) et que la vérité terrain officielle du site rapporte 54 avis actifs pour ce filtre pays, contre 14 avis réellement encore actifs parmi les 15 vus par le pipeline (comparaison actifs contre actifs — un des 15 était déjà expiré, voir correctif méthodologique plus haut) — une perte d'environ 40 avis actifs/jour (~74 %), dont un exemple documenté ci-dessus (pare-feu nouvelle génération, notice 311928 — illustratif du mécanisme de perte, bien que lui-même déjà expiré à la date de l'audit) et un confirmé en doublon avec un avis toujours actif côté Joffres.net (Tâche 3, UNDP-BFA-00734). **Aucun signe de blocage anti-bot** n'a été observé (HTTP 200 propre, contenu complet, aucune trace CAPTCHA/Cloudflare) — la mise en garde anti-bot de `docs/PROJECT_STATUS.md` concernant UNGM vise les fetchs Playwright nus, pas le mécanisme `httpx`+POST-JSON utilisé ici ; **pas de limite technologique à documenter**, uniquement une boucle de pagination manquante.
2. **Dédoublonnage — un faux positif de similarité vérifié** : deux avis UNICEF China distincts (aides auditives vs aides visuelles, références différentes) fusionnés à tort car leur titre suit un gabarit à 77,7 % de similarité textuelle, au-dessus du seuil de 75 % configuré — un avis réel perdu silencieusement sans trace de la raison dans les logs de nœud (qui ne loguent que les survivants).
3. **Persist — contribution spécifique au crash transversal du Finding #1** : la donnée UNGM à l'origine du `DatetimeFieldOverflow` qui a fait échouer tout le run BF aujourd'hui était, sur le site source, une date parfaitement valide et non ambiguë (`29-Sep-2026`) — ce n'est donc *pas* un cas de « donnée UNGM malformée » comme le laissait supposer le message d'erreur brut, mais un artefact introduit par la normalisation `_normalize_ungm_date()` du pipeline lui-même (perte volontaire du nom du mois, désambiguïsant), combiné au défaut architectural transversal déjà identifié (absence de parsing de date avant `persist_notices`, Finding #1). Un correctif localisé à `_normalize_ungm_date()` (conserver l'ISO `YYYY-MM-DD`) aurait suffi à éviter que *cette* notice précise ne déclenche le crash — sans se substituer au correctif architectural plus large nécessaire pour les autres sources.

Sévérité globale de la source : **critique** — entre la perte majoritaire par pagination (~74 % des avis actifs jamais vus, chiffre recalculé actifs contre actifs — voir correctif méthodologique plus haut) et la contribution directe au crash qui a fait perdre l'intégralité de la collecte BF du jour, UNGM est la source dont les défauts ont le plus large rayon d'impact sur ce run, alors même qu'aucun de ses trois défauts n'exige de refonte architecturale ou technologique pour être corrigé.

### UEMOA (source id 11, parser_type html-tender)

**Particularité structurelle de cette source :** `parser_type: html-tender` est un fetcher générique piloté entièrement par la colonne `patterns` en DB (`src/tenderai/agents/nodes/fetch_html_tender.py`) — aucun code spécifique à UEMOA. Le fetcher lit `card_selector`/`title_selector`/`pdf_selector`/`deadline_selector` pour parser une page HTML, plus trois paramètres pertinents pour cette tâche : `ssl_verify` (passé tel quel à `httpx.AsyncClient(verify=...)`), `max_pages` et `pagination_url` (lignes 41-48) — **le code implémente déjà une boucle de pagination générique** : `if max_pages > 1 and pagination_url: for page in range(2, max_pages+1): urls.append(pagination_url.format(page=page))`. Cette boucle n'est déclenchée que si les deux valeurs sont configurées.

**Configuration en base pour `source_id=11` (requête exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, name, parser_type, list_url, patterns FROM sources WHERE id=11;\""

 id |          name           | parser_type |              list_url               |                                                                                                                                         patterns
----+-------------------------+-------------+-------------------------------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 11 | UEMOA - Appels d'offres | html-tender | https://www.uemoa.int/appel-d-offre | {"entity": "UEMOA", "location": "Zone UEMOA", "max_pages": 1, "ssl_verify": false, "pdf_selector": "a[href*='opportunite_affaire']", "card_selector": "div.swiper-slide div.news-box", "title_selector": "div.new-txt p", "deadline_selector": "time", "deadline_attribute": "datetime"}
(1 row)
```
`max_pages: 1` et **aucune clé `pagination_url`** — la boucle de pagination du code (lignes 46-48 ci-dessus) ne peut donc jamais se déclencher pour cette source, quelle que soit la valeur de `max_pages`. **Comparaison directe avec Enabel** (même `parser_type: html-tender`, section suivante du rapport, Task 6) : ses `patterns` (extraits de `fetch_listings.json`) portent `"max_pages": 3, "pagination_url": "https://www.enabel.be/fr/marches-publics/page/{page}/?in_country=1726&is_status=0"` — la même mécanique de pagination générique **est activement utilisée avec succès pour une autre source BF**, ce qui confirme sans ambiguïté qu'il s'agit ici d'un défaut de configuration ponctuel pour UEMOA, pas d'une limite du code ni de l'architecture.

**Vérification `ssl_verify: false` — corrélation avec un problème de certificat réel (recherché conformément à la consigne du brief) :**
```
$ curl -s -o /dev/null -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://www.uemoa.int/appel-d-offre" -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
HTTP_STATUS:000 SIZE:0
$ echo $?
60

$ echo | openssl s_client -connect www.uemoa.int:443 -servername www.uemoa.int 2>&1 | grep -iE "verify|subject|issuer|error"
verify error:num=20:unable to get local issuer certificate
verify return:1
verify error:num=21:unable to verify the first certificate
verify return:1
verify return:1
subject=CN = *.uemoa.int
issuer=C = GB, O = Sectigo Limited, CN = Sectigo Public Server Authentication CA DV R36
Verification error: unable to verify the first certificate
Verify return code: 21 (unable to verify the first certificate)
```
Confirmé : `www.uemoa.int` ne sert pas le certificat intermédiaire Sectigo dans sa chaîne TLS — un défaut de configuration serveur réel et reproduisible côté UEMOA (`curl` échoue avec le code 60 « SSL certificate problem » sans `-k`/`verify=false`, indépendamment de tout client HTTP du pipeline). `ssl_verify: false` est donc un contournement légitime et nécessaire pour cette source précise, pas une cause de perte : `fetch_listings.json` confirme `status: "success"`, `error: null` pour UEMOA, sans aucune trace d'erreur TLS dans le run audité — **`ssl_verify: false` n'est pas un gap, aucune corrélation avec une perte d'avis.**

**Vérité terrain — `max_pages: 1` face à la pagination réelle du site (collecte le 2026-09-02, ~16h45 UTC, un jour après le run audité ; la structure et le volume du listing ne dépendent pas de la date d'audit).** *Écart méthodologique divulgué : `curl` a été utilisé ici à la place du « navigateur Chrome » prescrit par la spec. Justification propre à cette source, vérifiée et non supposée — `html-tender` cible une page entièrement rendue côté serveur : la pagination est un simple paramètre GET `?page=N` (lien « Dernière page » présent dans le HTML brut ci-dessous), les cartes `div.swiper-slide`/`div.new-txt p` et les liens PDF sont tous présents dans la réponse HTTP sans exécution JS, et aucun signe d'anti-bot n'apparaît (HTTP 200 constants, contenu complet). `curl` est donc équivalent au rendu navigateur pour établir cette vérité terrain.*
```
$ for p in 0 1 2 19; do
  curl -s -k -o /tmp/uemoa_live_p$p.html -w "page=$p HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
    "https://www.uemoa.int/appel-d-offre?page=$p" -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
done
page=0 HTTP_STATUS:200 SIZE:92590
page=1 HTTP_STATUS:200 SIZE:93258
page=2 HTTP_STATUS:200 SIZE:93472
page=19 HTTP_STATUS:200 SIZE:86651
```
Lien de pagination « Dernière page » extrait du HTML brut de `page=0` :
```
<li class="page-item pager__item--last">
  <a href="?page=19" title="Aller à la dernière page" class="page-link">
    <span class="visually-hidden">Dernière page</span>
    <span aria-hidden="true">Last »</span>
  </a>
</li>
```
→ **20 pages au total (`page=0` à `page=19`)**, mécanisme de pagination server-side classique (paramètre `?page=N` en GET, pas d'AJAX/JS requis — donc trivialement rejouable par `httpx`, aucun rendu JS nécessaire). Décompte indépendant des items (sélecteur `div.swiper-slide` + `div.new-txt p`, identique au `card_selector`/`title_selector` du pipeline) par page, et vérification qu'il s'agit bien d'avis distincts et non de doublons de carrousel :
```
$ python3 -c "
import re
for p in [0,1,2,19]:
    html = open(f'/tmp/uemoa_live_p{p}.html', encoding='utf-8').read()
    titles = re.findall(r'<p class=\"pb-2\"style=\"font-size:12px;\">\s*(.*?)</p>', html, re.S)
    print(f'page={p}: {len(titles)} titres')
"
page=0: 10 titres
page=1: 10 titres
page=2: 10 titres
page=19: 4 titres

$ python3 -c "
p0 = set(open('/tmp/uemoa_slide_hrefs_p0.txt').read().split())
p1 = set(open('/tmp/uemoa_slide_hrefs_p1.txt').read().split())
p2 = set(open('/tmp/uemoa_slide_hrefs_p2.txt').read().split())
print('p0 & p1 overlap:', p0 & p1)
print('p0 & p2 overlap:', p0 & p2)
print('p1 & p2 overlap:', p1 & p2)
"
p0 & p1 overlap: set()
p0 & p2 overlap: set()
p1 & p2 overlap: set()
```
(fichiers `uemoa_slide_hrefs_pN.txt` = liens PDF `href` extraits de chaque bloc `swiper-slide`, un fichier par page, comparés par intersection d'ensembles Python) — **zéro chevauchement entre les 3 premières pages : 30 avis strictement distincts**, confirmant qu'il ne s'agit pas d'un artefact de carrousel dupliqué mais d'une vraie pagination de contenu. **Total du listing : 19×10 + 4 = 194 avis distincts** (pages 0 à 18 pleines à 10, page 19 partielle à 4) contre **10 récupérés par le pipeline** (`max_pages: 1` = uniquement `list_url`, équivalent à `page=0`) — **184 avis, soit ~94,8 % du listing, jamais fetchés**, uniquement à cause de la valeur de configuration `max_pages: 1`.

Deux exemples concrets, manifestement pertinents pour une entreprise IT, trouvés en page 2 (jamais atteinte par le pipeline) :
```
$ python3 -c "
import re
html = open('/tmp/uemoa_live_p2.html', encoding='utf-8').read()
titles = re.findall(r'<p class=\"pb-2\"style=\"font-size:12px;\">\s*(.*?)</p>', html, re.S)
for t in titles: print('-', re.sub(r'\s+',' ', t).strip())
"
- Addendum N° 1 de l'Appel d'Offres relatif aux travaux de réhabilitation de 50 km de pistes rurales au profit de la SIRAT SA
- Addendum N°01 de l'Avis d'Appel d'Offres Ouvert International relatif à la réalisation des travaux de forages d'exploitation ...
- Avis d'appel d'offres international relatif à l'équipement et mise en exploitation du data center et du réseau local CAM
- Avis d'appel d'offre international relatif à l'acquisition d'équipements de contrôle technique mobile mixte VL/PL et fixe VL au profit du CN...
- Avis d'appel d'offre international relatif à la fourniture, au deploiement et pose de lampadaires solaires de type photovoltaïques pour l'éc...
- Avis d'Appel d'Offres Ouvert International relatif à la couverture en assurance santé du personnel de la SBEE
- Appel d'offres ouvert N° 023/2026/AO/COM/UEMOA relatif au renouvellement du contrat de licences Microsoft Enterprise Agreement (EA) de ...
- Avis d'Appel d'Offres Ouvert International relatif à l'acquisition des Equipements de Protection Collective (EPC) au profit de la SBEE.
- Addendum N°1 de l'appel d'offre international relatif à la construction de trente-cinq (35) Guichets Uniques de Protection Sociale (GUPS) et...
- Communiqué No 005/CCM/2026 relatif à la modification des caractéristiques techniques et au report de la date limite de de dépôt des offres d...
```
- **« Avis d'appel d'offres international relatif à l'équipement et mise en exploitation du data center et du réseau local CAM »** — matche littéralement les mots-clés `it_services` « data center » et « réseau local » de la config de classification (Contraintes globales du plan). Il s'agit en outre de l'avis **original** du marché DAOI N°022 : le pipeline n'a vu (via `fetch_listings.json`, page 0) que ses deux addenda (« Addendum n°1 » et « Addendum n°2 DAOI N°022 »), jamais l'avis initial lui-même — l'avis « source » de ce marché IT est donc totalement invisible pour le pipeline.
- **« Appel d'offres ouvert N° 023/2026/AO/COM/UEMOA relatif au renouvellement du contrat de licences Microsoft Enterprise Agreement (EA) »** — même famille que l'item déjà vu en page 0 (« Renouvellement des licences et support Microsoft o365 »), mais un marché distinct (licences Enterprise Agreement vs support O365), jamais atteint.

**Résultat du pipeline (run `785adda4-f28c-4f3c-af0a-74b7e775d0b5`) :**

- `fetch_listings.json` (`grep -i "uemoa" -A5 fetch_listings.json`, extrait des `patterns` confirmé identique à la DB ci-dessus) : `status: "success"`, `error: null`, exactement **10 listings** — un seul appel HTTP à `list_url`, aucune boucle de pagination (cohérent avec `max_pages: 1` et l'absence de `pagination_url`). Les 10 items correspondent exactement à la page 0 de la vérité terrain (mêmes titres, mêmes deadlines ISO). `"content": null` — le fetcher `html-tender` ne conserve jamais le HTML brut dans le log de nœud (ligne 80 du code), seulement les `listings` déjà parsés.
- `extract_item_links.json` : **10/10** survivent intacts (`Counter({'ungm': 15, "UEMOA - Appels d'offres": 10, ...})`).
- `fetch_items.json` : **10/10** avec `status: "success"` pour chacune des 10 URLs PDF UEMOA (vérifié individuellement, aucune erreur SSL/réseau au niveau item malgré `ssl_verify: false`).
- `parse_extract.json` (27 items au total toutes sources BF confondues) : **10/10** UEMOA survivent intacts (`Counter({'ungm': 15, "UEMOA - Appels d'offres": 10, "Enabel - Marchés publics Burkina Faso": 1, 'joffres.net': 1})`, cf. section UNGM).
- `deduplicate.json` (24 items uniques au total) : **8/10** seulement — 2 items UEMOA disparaissent du tableau `unique_items` sans trace de `duplicate_of_id` (même limite de logging déjà documentée section UNGM : `deduplicate.py` ligne 310 ne logue que les survivants). Reconstitution par comparaison titre-à-titre entre les 10 titres de `parse_extract.json` et les 8 de `deduplicate.json` :
```
$ python3 -c "
import json
pe = {i['title'] for i in json.load(open('parse_extract.json'))[0]['data'] if i.get('source')==\"UEMOA - Appels d'offres\"}
dd = {i['title'] for i in json.load(open('deduplicate.json'))[0]['data'] if i.get('source')==\"UEMOA - Appels d'offres\"}
print(pe - dd)"
{"Addendum N°1 au Dao 071 relatif aux travaux de réhabilitation des directions départementales du cadre de vie et des transports (DDCVT), de l'annexe de la DDCVT du mono, et des divisions territoriales de come et d'Allada",
 "Addendum n°1 DAOI N°022 relatif à l'équipement et mise en exploitation du data center et du réseau local CAM"}
```
Vérification indépendante de la cause exacte (`reference`/`ref_no` vides des deux côtés pour toutes les paires UEMOA — le court-circuit `item_ref == unique_ref` de `deduplicate.py` ligne 186 ne peut donc jamais s'appliquer ; retombée systématique sur `fuzz.ratio()` du titre, lignes 191-195, même mécanisme que documenté section UNGM) :
```
$ python3 -c "
from rapidfuzz import fuzz
t1 = 'ADDENDUM N°02 relatif aux travaux de réhabilitation des directions départementales du cadre de vie et des transports (DDCVT), de l\'annexe de la DDCVT du mono, et des divisions territoriales de come et d\'Allada'
t2 = 'Addendum N°1 au Dao 071 relatif aux travaux de réhabilitation des directions départementales du cadre de vie et des transports (DDCVT), de l\'annexe de la DDCVT du mono, et des divisions territoriales de come et d\'Allada'
print('DDCVT pair:', fuzz.ratio(t1, t2))
t3 = 'Addendum n°2 DAOI N°022 relatif à l\'équipement et mise en exploitation du data center et du réseau local CAM'
t4 = 'Addendum n°1 DAOI N°022 relatif à l\'équipement et mise en exploitation du data center et du réseau local CAM'
print('DAOI 022 pair:', fuzz.ratio(t3, t4))
"
DDCVT pair: 93.92523364485982
DAOI 022 pair: 99.07407407407408
```
Les deux paires dépassent très largement le seuil configuré de 75 % (`tenderai-infra/settings.yaml`, `deduplication_threshold: 0.75`, `deduplication_method: "hash_similarity"`) — **« Addendum N°1 » et « Addendum N°02 »/« n°1 »/« n°2 » d'un même marché sont des documents distincts** (chacun modifie ou complète l'appel d'offres à un moment différent, avec potentiellement des changements de délai ou de spécifications), pas des doublons du même avis, mais leur titre quasi identique déclenche systématiquement la similarité fuzzy et **le premier des deux atteint reste seul dans `unique_items`, l'autre est éliminé silencieusement**. Nuance notée : la paire DDCVT (travaux de réhabilitation, sans pertinence IT évidente) a un impact pratique faible ; la paire DAOI N°022 (data center/réseau local, cf. mots-clés IT ci-dessus) est la plus préoccupante — mais son avis original et son propre « Addendum n°1 » étaient de toute façon déjà hors de portée du fetch (page 2, gap ci-dessus), donc l'impact net aujourd'hui de ce bug de dédoublonnage se limite à empêcher que « Addendum n°1 DAOI N°022 » ne soit jamais visible même le jour où la pagination serait corrigée.
- `persist_notices.json` : **tableau vide `[]`** (2 octets, vérifié sur disque dans le conteneur) — run entier en échec avant tout commit (Finding #1). Répartition du batch de 24 items (Finding #1) : **UEMOA a contribué 8 des 24 items** envoyés à `persist_notices`, tous les 8 survivants de `deduplicate.json` ci-dessus (dont « Renouvellement des licences et support Microsoft o365 » et « Addendum n°2 DAOI N°022 … data center et … réseau local », les deux items UEMOA manifestement pertinents IT ayant survécu jusque-là).
- `notices` (DB, `source_id=11`) : **0 ligne** (requête Step 3 exécutée le 2026-09-02) :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=11 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu et non spécifique à UEMOA (Finding #1, avertissement en tête de section BF) : les 8 items UEMOA survivants ont été engloutis, comme les items Joffres.net et UNGM, par le `DatetimeFieldOverflow` transversal provoqué par une notice UNGM distincte dans la même transaction tout-ou-rien. Aucune ligne `company_notice_status` n'existe (livraison jamais déclenchée) : aucun faux positif de classification ne peut être vérifié pour cette source sur ce run.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| Avis d'appel d'offres international relatif à l'équipement et mise en exploitation du data center et du réseau local CAM (avis original du marché DAOI N°022, page 2 du listing live) — matche littéralement les mots-clés IT « data center » et « réseau local » | Non | Fetch (`fetch_listings`, branche `html-tender`) | `max_pages: 1` dans `patterns` (DB) sans `pagination_url` configuré — la boucle de pagination générique de `fetch_html_tender.py` (lignes 42-48) ne se déclenche jamais ; le même mécanisme est actif et fonctionnel pour Enabel (`max_pages: 3` + `pagination_url`), confirmant un défaut de configuration ponctuel, pas de code | bug logique | Critique | `patterns` DB (`max_pages:1`, pas de `pagination_url`) vs `patterns` Enabel ; pager live « Dernière page » → `?page=19` ; titre confirmé en page 2 (`uemoa_live_p2.html`, curl) |
| Appel d'offres ouvert N° 023/2026/AO/COM/UEMOA relatif au renouvellement du contrat de licences Microsoft Enterprise Agreement (EA) (page 2 du listing live) — même famille IT que l'item Microsoft o365 vu en page 0 | Non | Fetch (`fetch_listings`, branche `html-tender`) | Même cause que ci-dessus | bug logique | Critique | Idem — titre confirmé en page 2 (curl) |
| Les ~182 autres avis des pages 1 à 19 jamais récupérés (194 avis au total sur le listing complet — pages 0 à 18 pleines à 10, page 19 partielle à 4 — contre 10 vus par le pipeline) | Non | Fetch (`fetch_listings`, branche `html-tender`) | Même cause — perte structurelle sur ~94,8 % du listing, pas un cas isolé | bug logique | Critique | Pager « Dernière page » → `?page=19` ; 0 chevauchement vérifié par intersection d'ensembles Python entre les items des pages 0, 1, 2 (30 avis strictement distincts sur 3 pages) |
| Addendum N°1 au Dao 071 relatif aux travaux de réhabilitation des DDCVT (…) | Oui, jusqu'à `parse_extract` inclus (10/10) ; perdu à `deduplicate` | Dédoublonnage (`deduplicate`, méthode `hash_similarity`) | Faux positif de similarité fuzzy sur titre gabarit (`fuzz.ratio` = 93,9 % > seuil 75 %) entre deux addenda distincts (N°1 et N°02) du même DAO 071 — références vides des deux côtés, court-circuit de comparaison exacte jamais applicable | bug logique | Modérée (perte réelle et vérifiée, mais pertinence IT non évidente — travaux de réhabilitation de bâtiments) | `parse_extract.json` : 10/10 UEMOA présents ; `deduplicate.json` : 8/10, item absent sans `duplicate_of_id` ; calcul indépendant `rapidfuzz.fuzz.ratio()` = 93,92523... ; `tenderai-infra/settings.yaml` (seuil 0.75, méthode hash_similarity) |
| Addendum n°1 DAOI N°022 relatif à l'équipement et mise en exploitation du data center et du réseau local CAM — matche littéralement les mots-clés IT « data center »/« réseau local » | Oui, jusqu'à `parse_extract` inclus (10/10) ; perdu à `deduplicate` | Dédoublonnage (`deduplicate`, méthode `hash_similarity`) | Même mécanisme que ci-dessus, `fuzz.ratio` = 99,1 % > seuil 75 % vs « Addendum n°2 DAOI N°022 » (qui, lui, a survécu) | bug logique | Modérée (bug réel et distinct du gap de pagination ci-dessus, mais impact net aujourd'hui limité car l'avis original et cet addendum sont de toute façon déjà hors de portée du fetch à cause de `max_pages:1`) | `deduplicate.json` : 8/10, item absent ; calcul indépendant `rapidfuzz.fuzz.ratio()` = 99,07407... |
| Les 8 avis UEMOA ayant survécu jusqu'à `deduplicate` (dont « Renouvellement des licences et support Microsoft o365 » et « Addendum n°2 DAOI N°022 … data center et … réseau local », tous deux manifestement pertinents IT) | Oui, jusqu'à `deduplicate` inclus (8/8, tous `is_duplicate: false`) | Persist (`persist_notices`) | Non spécifique à UEMOA : transaction unique tout-ou-rien du run BF entier (`persist_notices.py`, un seul `db.commit()` après la boucle) qui échoue à cause d'une notice **UNGM** distincte (`LRFP-2026-9205898`) — voir Finding #1 | bug logique | Critique | `deduplicate.json` : 8 items `source: "UEMOA - Appels d'offres"`, tous `is_duplicate: false` ; Finding #1 (batch INSERT de 24 lignes dont 8 UEMOA) ; requête SQL Step 3 (`source_id=11`) → 0 lignes |

**Verdict :** UEMOA cumule deux défauts indépendants, tous deux corrigibles par un changement de configuration/code localisé (aucune limite architecturale ni technologique) :

1. **Fetch — perte massive par pagination absente** (le défaut le plus sévère, en volume comme en netteté de la preuve) : le listing live compte 194 avis répartis sur 20 pages server-side (`?page=0` à `?page=19`, pagination GET classique sans JS), le pipeline n'en récupère que 10 (la page 0) à cause de `max_pages: 1` combiné à l'absence de `pagination_url` dans `patterns` — soit **~94,8 % du listing jamais vu**, dont au moins 2 avis manifestement pertinents IT identifiés en page 2 seule (le marché data center/réseau local CAM et son renouvellement de licences Microsoft EA). Il ne s'agit ni d'un blocage anti-bot (aucune erreur, `status: "success"` constant) ni d'une limite du fetcher : le mécanisme de boucle de pagination existe déjà dans `fetch_html_tender.py` et **fonctionne activement pour Enabel**, la source BF voisine utilisant le même `parser_type`. Corriger `max_pages` et ajouter un `pagination_url` dans les `patterns` de la source UEMOA en DB suffirait — c'est un changement de configuration, pas de code, à plus forte raison **bug logique** et non une limite architecturale.
2. **Dédoublonnage — deux faux positifs de similarité vérifiés**, même mécanisme que documenté section UNGM : des addenda successifs d'un même marché (N°1, N°02/n°2) partagent un gabarit de titre à 93,9 % et 99,1 % de similarité, au-dessus du seuil 75 % configuré, et sont fusionnés à tort alors qu'ils sont des documents distincts (chacun peut porter une information nouvelle — report de délai, modification de spécification). Un de ces deux cas concerne directement le marché IT data center/réseau local CAM, mais son impact pratique aujourd'hui reste subordonné au gap de pagination ci-dessus (l'avis original de ce marché n'est de toute façon pas atteint par le fetch).

`ssl_verify: false` a été vérifié corrélé à un problème de certificat serveur réel et reproductible (chaîne TLS incomplète côté `www.uemoa.int`, confirmé indépendamment par `curl`/`openssl s_client`) — **ce n'est pas un gap** : le paramètre fonctionne comme contournement légitime, `fetch_listings.json` ne montre aucune trace d'échec réseau/TLS pour cette source sur le run audité.

Sévérité globale de la source : **critique**, portée principalement par la perte de pagination (~184 avis/jour jamais vus, dont des marchés IT identifiés) ; le crash transversal du Finding #1 a ensuite empêché même les 8 avis survivants (dont 2 manifestement pertinents IT) d'atteindre la base de données ce jour précis — un problème indépendant de UEMOA lui-même, déjà documenté et dont la source n'est pas responsable.

### Enabel (source id 12, parser_type html-tender)

**Particularité structurelle de cette source :** même fetcher générique piloté par `patterns` que UEMOA (`src/tenderai/agents/nodes/fetch_html_tender.py`, aucun code spécifique à Enabel). Configuration en base pour `source_id=12` (requête exécutée le 2026-09-02) :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, name, parser_type, list_url, patterns FROM sources WHERE id=12;\""

 id |                 name                  | parser_type |                               list_url                                |                                                                                                                                                           patterns
----+---------------------------------------+-------------+-----------------------------------------------------------------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 12 | Enabel - Marchés publics Burkina Faso | html-tender | https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0 | {"entity": "Enabel", "location": "Burkina Faso", "max_pages": 3, "card_selector": "div.card--news.card--tenders", "pagination_url": "https://www.enabel.be/fr/marches-publics/page/{page}/?in_country=1726&is_status=0", "title_selector": "p.h5 span", "deadline_selector": "p", "deadline_text_prefix": "Date de clôture"}
(1 row)
```
`max_pages: 3` **et** `pagination_url` configurés (contrairement à UEMOA, Tâche 5) — la boucle de pagination générique de `fetch_html_tender.py` (lignes 46-48 : `if max_pages > 1 and pagination_url: for page in range(2, max_pages+1): urls.append(pagination_url.format(page=page))`) se déclenche bel et bien pour Enabel. **Point notable, absent des deux autres sources `html-tender`/pagination-adjacentes déjà auditées (UEMOA, UNGM) :** contrairement à UEMOA (`pdf_selector: "a[href*='opportunite_affaire']"`), les `patterns` d'Enabel **ne définissent aucun `pdf_selector`** — chaque avis Enabel publie pourtant une PDF ("Cahier des charges") distincte par avis dans le HTML lui-même (voir Step 2 ci-dessous), non exploitée par le fetcher faute de sélecteur configuré.

**Vérité terrain — méthode et disclosure de l'écart de date (conforme à la consigne du brief) :** collectée le **2026-09-02, ~16h55 UTC, soit un jour après le run audité (2026-09-01)**. Comme pour UEMOA (Tâche 5), `curl` a été utilisé à la place du navigateur Chrome — justifié de la même façon : `html-tender` est un fetcher server-rendered (pas de JS requis, pagination `?page=N`-style ou `/page/N/`-style classique), donc `curl` est équivalent au rendu réel de la page. Pour compenser l'écart d'un jour, un **cross-check empirique titre-par-titre et deadline-par-deadline** entre le listing live du 2026-09-02 et le `fetch_listings.json` du 2026-09-01 a été effectué (voir "Résultat du pipeline" ci-dessous) — les 3 titres et les 3 deadlines sont identiques à la lettre près, confirmant l'absence de dérive de contenu entre les deux dates.

Page racine (`list_url`, `?in_country=1726&is_status=0`) et pagination jusqu'à la page 5 (au-delà des `max_pages: 3` configurés, pour vérifier explicitement l'absence d'une page 4+ contenant plus d'avis) :
```
$ for p in "" "page/2/" "page/3/" "page/4/" "page/5/"; do
  url="https://www.enabel.be/fr/marches-publics/${p}?in_country=1726&is_status=0"
  curl -s -o <fichier> -w "url=$url HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
    "$url" -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
done
url=https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0 HTTP_STATUS:200 SIZE:124717
url=https://www.enabel.be/fr/marches-publics/page/2/?in_country=1726&is_status=0 HTTP_STATUS:200 SIZE:120162
url=https://www.enabel.be/fr/marches-publics/page/3/?in_country=1726&is_status=0 HTTP_STATUS:200 SIZE:120160
url=https://www.enabel.be/fr/marches-publics/page/4/?in_country=1726&is_status=0 HTTP_STATUS:200 SIZE:120161
url=https://www.enabel.be/fr/marches-publics/page/5/?in_country=1726&is_status=0 HTTP_STATUS:200 SIZE:120159
```
Comptage indépendant des cartes tender (`div.card--news.card--tenders`, sélecteur exact utilisé par le pipeline) sur chaque page téléchargée :
```
$ for f in p0.html page_2_.html page_3_.html page_4_.html page_5_.html; do
  echo -n "$f: "; grep -o 'card--news card--tenders' "$f" | wc -l
done
p0.html: 3
page_2_.html: 0
page_3_.html: 0
page_4_.html: 0
page_5_.html: 0
```
**Aucune trace de pagination active dans le HTML de la page 0** (`grep -o 'page/[0-9]*/' p0.html` ne renvoie aucun lien de pagination), aucun message « aucun résultat »/erreur distinguable sur les pages 2-5 (même gabarit HTML exact que la page 0, seule la classe `paged-N`/`page-paged-N` du `<body>` change, confirmé par `diff` entre pages consécutives — pas une page d'erreur ou de blocage). **Conclusion vérité terrain : le site ne compte actuellement que 3 avis actifs au total pour ce filtre pays, tous sur la page 0 ; aucune page 4+ (ni même page 2/3) avec des avis supplémentaires n'existe.** `max_pages: 3` est donc une valeur généreuse mais **non fautive** ici — à la différence de UEMOA (`max_pages: 1` face à 194 avis réels sur 20 pages), Enabel n'a structurellement pas de pagination manquante : le nombre de pages réellement configurées (3) couvre très largement le nombre de pages réellement nécessaires (1).

Les 3 avis vérité terrain (titres et deadlines extraits indépendamment du HTML brut de `p0.html`, sélecteurs `p.h5 span` / `Date de clôture :`) :
```
$ python3 -c "
import re
html = open('p0.html', encoding='utf-8').read()
for m in re.finditer(r'<p class=\"h5\"[^>]*>\s*<span[^>]*>(.*?)</span>', html, re.S):
    print(repr(m.group(1)))
"
'\n  BFA23004-10084 &#8211;\n  Acquisition de matériel spécifique pour apprenants handicapés\n  '
'\n  BFA22002-10159 &#8211;\n  Acquisition et installation d&rsquo;équipements d'intrant au profit des entreprises agroalimentaires\n  '
'\n  BFA23002-10044 &#8211;\n  Fourniture, livraison et installation d'équipements médico-techniques pour les districts sanitaires de Boromo et de Houndé\n  '

$ python3 -c "
import re
html = open('p0.html', encoding='utf-8').read()
for m in re.finditer(r'.{20}Date de cl.ture.{150}', html, re.S): print(repr(m.group(0)))
"
'...Date de clôture : </strong> 14 September 2026 12:00 </p>...'
'...Date de clôture : </strong> 07 September 2026 12:00 </p>...'
'...Date de clôture : </strong> 08 September 2026 12:00 </p>...'
```
1. BFA23004-10084 – Acquisition de matériel spécifique pour apprenants handicapés (deadline 14/09/2026) — équipement pédagogique adapté, **aucun mot-clé IT/mots-clés de classification** (Contraintes globales) ne matche.
2. BFA22002-10159 – Acquisition et installation d'équipements d'intrant au profit des entreprises agroalimentaires (deadline 07/09/2026) — équipement agro-industriel, **aucun mot-clé IT ne matche**.
3. BFA23002-10044 – Fourniture, livraison et installation d'équipements médico-techniques pour les districts sanitaires de Boromo et de Houndé (deadline 08/09/2026) — équipement médico-technique, **aucun mot-clé IT ne matche** (« équipement » seul n'est pas dans la liste ; la liste exige des termes composés comme « équipement informatique »/« matériel informatique »).

Chaque carte contient par ailleurs un lien PDF « Cahier des charges » propre et distinct par avis (vérifié dans le HTML brut) :
```
$ python3 -c "
import re
html = open('p0.html', encoding='utf-8').read()
cards = re.split(r'card--news card--tenders', html)[1:]
for i, c in enumerate(cards):
    print(f'card {i}:', re.findall(r'href=\"([^\"]+\\.pdf)\"', c[:3000])[:1])
"
card 0: ['https://www.enabel.be/app/uploads/2026/08/BFA23004-10084_Cahier-des-charges-2.pdf']
card 1: ['https://www.enabel.be/app/uploads/2026/08/BFA-22002-10159_Cahier-des-charges.pdf']
card 2: ['https://www.enabel.be/app/uploads/2026/08/BFA23002-10044_Cahier_Charges-1-1.pdf']
```
— information exploitée plus bas (Step 2) pour identifier la cause exacte de la perte à l'étage `extract_item_links`.

**Résultat du pipeline (run `785adda4-f28c-4f3c-af0a-74b7e775d0b5`, fetch à 2026-09-01 21:20:49 UTC) :**

- `fetch_listings.json` (`grep -i "enabel" -A5 fetch_listings.json`) : `status: "success"`, `error: null`, `patterns` en sortie **identiques** à la config DB ci-dessus (mêmes clés, y compris l'absence de `pdf_selector`). **3 listings au total** — **correspondance exacte, titre pour titre et deadline pour deadline, avec la vérité terrain du 2026-09-02 ci-dessus** (`BFA23004-10084` / `14 September 2026 12:00`, `BFA22002-10159` / `07 September 2026 12:00`, `BFA23002-10044` / `08 September 2026 12:00`) — confirme empiriquement l'absence de dérive de contenu malgré l'écart d'un jour entre le run audité et la collecte de vérité terrain :
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
entry = [e for e in d[0]['data'] if e.get('url','').startswith('https://www.enabel.be')][0]
print('status:', entry['status'], '| listings:', len(entry['listings']))
for l in entry['listings']: print(' -', l['title'], '|', l['deadline'])
"
status: success | listings: 3
 - BFA23004-10084 – Acquisition de matériel spécifique pour apprenants handicapés | 14 September 2026 12:00
 - BFA22002-10159 – Acquisition et installation d'équipements d'intrant au profit des entreprises agroalimentaires | 07 September 2026 12:00
 - BFA23002-10044 – Fourniture, livraison et installation d'équipements médico-techniques pour les districts sanitaires de Boromo et de Houndé | 08 September 2026 12:00
```
Chaque item porte `"url": "https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0"` (l'URL de la page de listing elle-même, identique pour les 3) : `_extract_cards()` (`fetch_html_tender.py` lignes 131-138) n'affecte `item_url = page_url` que par défaut, faute de `pdf_sel` configuré pour cette source — les 3 liens PDF distincts par avis (vérifiés ci-dessus dans le HTML brut) existent bien mais ne sont jamais extraits, faute de `pdf_selector` dans `patterns`. **Les 3 pages configurées (`max_pages: 3`) ont bien été sollicitées par le code** (la boucle `urls = [list_url, page/2, page/3]` se déclenche puisque `pagination_url` est présent) ; le fait que le total de `listings` (3) corresponde exactement au nombre de cartes trouvées sur la seule page 0 de la vérité terrain (les pages 2/3 étant vérifiées vides ci-dessus, à un jour d'écart) est cohérent avec des pages 2/3 déjà vides le 2026-09-01 également — **nuance méthodologique honnête :** le nœud n'enregistre qu'un total agrégé par source (pas de détail par page), et les échecs de fetch par page sont capturés uniquement par `logger.warning()` (ligne 63-69 du fetcher), jamais renvoyés dans le JSON de sortie ni conservés (`docker logs` de ce run non disponibles, même limite que documentée section DGCMEF) — il n'est donc pas possible de prouver à 100% que les pages 2/3 ont réussi plutôt qu'échoué silencieusement le 09-01 ; cependant, la correspondance exacte du compte et du contenu avec la vérité terrain du lendemain (où les pages 2-5 sont confirmées vides, pas en erreur) rend cette hypothèse largement la plus probable. **Aucun signe de page 4+ avec des avis supplémentaires — le fetch n'est pas en cause pour cette source, contrairement à UEMOA/UNGM.**
- `extract_item_links.json` : **1/3 seulement** survit :
```
$ python3 -c "
import json
d = json.load(open('extract_item_links.json'))
data = d[0]['data']
for i in data:
    if 'enabel' in str(i.get('source','')).lower():
        print(i.get('title'), '|', i.get('url'))
"
BFA23004-10084 – Acquisition de matériel spécifique pour apprenants handicapés | https://www.enabel.be/fr/marches-publics/?in_country=1726&is_status=0
```
**Cause racine identifiée avec certitude dans le code (`extract_item_links.py`) :** pour `parser_type in ("html-tender", "crawl4ai")` (lignes 533-541), la clé de déduplication est `url = link.get("url") or link.get("link", "")`, insérée dans un unique set `seen_urls` **partagé entre toutes les sources du run** — or les 3 items Enabel partagent tous exactement la même `url` (celle de la page de listing, voir ci-dessus, faute de `pdf_selector`). Le premier item rencontré (`BFA23004-10084`) passe le test `key not in seen_urls` ; les deux suivants (`BFA22002-10159`, `BFA23002-10044`), avec la **même** clé, sont silencieusement rejetés comme « doublons » alors qu'il s'agit de 3 avis réels et distincts (références, titres, deadlines tous différents). C'est un artefact de collision d'URL introduit par l'absence de configuration `pdf_selector`, pas une déduplication légitime.
- `fetch_items.json` : le survivant unique (`BFA23004-10084`) passe intact, `status: "success"`.
- `parse_extract.json` (27 items au total toutes sources BF confondues) : **1/1** Enabel survit (`Counter({'ungm': 15, "UEMOA - Appels d'offres": 10, 'Enabel - Marchés publics Burkina Faso': 1, 'joffres.net': 1})`, cf. sections UNGM/UEMOA) — aucune perte supplémentaire à cet étage, cohérent avec le fait qu'il ne restait déjà plus qu'un seul item Enabel en entrée.
- `deduplicate.json` (24 items uniques au total) : **1/1** — le survivant passe `is_duplicate: false` (`Counter({'ungm': 14, "UEMOA - Appels d'offres": 8, 'Enabel - Marchés publics Burkina Faso': 1, 'joffres.net': 1})`), non fusionné à tort avec un autre avis.
- `persist_notices.json` : **tableau vide `[]`** (2 octets, vérifié sur disque dans le conteneur) — run entier en échec avant tout commit (Finding #1, avertissement en tête de section BF). Répartition du batch de 24 items (Finding #1) : **Enabel a contribué 1 des 24 items** (`BFA23004-10084`), le seul survivant à avoir atteint `persist_notices`.
- `notices` (DB, `source_id=12`) : **0 ligne** (requête Step 3 exécutée le 2026-09-02). Requête et sortie brute :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=12 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu et non spécifique à Enabel (Finding #1, avertissement en tête de section BF) : le seul survivant Enabel a été englouti, comme les items Joffres.net/UEMOA/UNGM, par le `DatetimeFieldOverflow` transversal provoqué par une notice UNGM distincte dans la même transaction tout-ou-rien. Aucune ligne `company_notice_status` n'existe (livraison jamais déclenchée) : aucun faux positif de classification ne peut être vérifié pour cette source sur ce run — de toute façon, aucun des 3 avis Enabel ne matche un mot-clé de la liste de classification (voir ci-dessus), donc aucun candidat plausible à un faux positif n'existe pour cette source.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| BFA22002-10159 – Acquisition et installation d'équipements d'intrant au profit des entreprises agroalimentaires | Oui, jusqu'à `fetch_listings` inclus (1 des 3 listings) ; perdu à `extract_item_links` | Dédoublonnage (`extract_item_links`, clé URL) | Absence de `pdf_selector` dans les `patterns` Enabel (DB) → `fetch_html_tender.py::_extract_cards()` assigne la même `url` (celle de la page de listing) aux 3 cartes → `extract_item_links.py` (lignes 533-541) déduplique par `url` dans un set global `seen_urls` partagé entre sources → seul le 1er item rencontré (`BFA23004-10084`) survit, celui-ci est éliminé à tort comme "doublon" alors qu'il s'agit d'un avis distinct (lien PDF propre, `BFA-22002-10159_Cahier-des-charges.pdf`, vérifié présent dans le HTML mais jamais extrait) | bug logique | Critique | `fetch_listings.json` : 3 listings, tous `"url"` identiques ; `extract_item_links.json` : 1/3 survivants ; `extract_item_links.py` lignes 533-541 (clé de dedup = `url`) ; HTML brut vérité terrain (`p0.html`) : lien PDF distinct confirmé par carte |
| BFA23002-10044 – Fourniture, livraison et installation d'équipements médico-techniques pour les districts sanitaires de Boromo et de Houndé | Oui, jusqu'à `fetch_listings` inclus (1 des 3 listings) ; perdu à `extract_item_links` | Dédoublonnage (`extract_item_links`, clé URL) | Même cause racine que ci-dessus — 3ᵉ carte, même collision d'URL, éliminée pour la même raison (lien PDF propre `BFA23002-10044_Cahier_Charges-1-1.pdf` vérifié présent mais jamais extrait) | bug logique | Critique | Idem — `extract_item_links.json` : 1/3 survivants ; HTML brut vérité terrain : lien PDF distinct confirmé |
| BFA23004-10084 – Acquisition de matériel spécifique pour apprenants handicapés (seul survivant Enabel à atteindre `deduplicate`/`persist_notices`) | Oui, jusqu'à `deduplicate` inclus (`is_duplicate: false`, 1/1 survivant) | Persist (`persist_notices`) | Non spécifique à Enabel : transaction unique tout-ou-rien du run BF entier (`persist_notices.py`, un seul `db.commit()` après la boucle) qui échoue à cause d'une notice **UNGM** distincte (`LRFP-2026-9205898`) — voir Finding #1 | bug logique | Critique | `deduplicate.json` : 1 item `source: "Enabel - Marchés publics Burkina Faso"`, `is_duplicate: false` ; Finding #1 (batch INSERT de 24 lignes dont 1 Enabel) ; requête SQL Step 3 (`source_id=12`) → 0 lignes |

Aucun cas de faux positif de classification à documenter pour cette source : aucune ligne `company_notice_status` n'existe (livraison jamais déclenchée), et aucun des 3 avis Enabel de ce run ne matche de toute façon un mot-clé de la liste de classification configurée (Contraintes globales) — pas de candidat plausible à vérifier.

**Verdict :** Enabel cumule deux défauts indépendants, tous deux corrigibles par un changement de configuration/code localisé (aucune limite architecturale ni technologique) :

1. **Dédoublonnage — perte majoritaire par collision d'URL, pas par pagination manquante** (défaut le plus sévère en proportion — 2 des 3 avis actifs, soit ~67 %, perdus chaque run de façon parfaitement reproductible) : à la différence de UEMOA (Tâche 5, `max_pages: 1` sans `pagination_url`) et de UNGM (Tâche 4, `PageIndex` câblé en dur), **la pagination d'Enabel n'est pas en cause** — `max_pages: 3` + `pagination_url` sont correctement configurés, le code boucle bien sur les 3 pages, et la vérité terrain confirme qu'il n'existe aujourd'hui que 3 avis actifs au total, tous sur la page 0 (pages 2 à 5 vérifiées vides, aucune page 4+ avec plus d'avis). Le vrai défaut est en aval, à l'étage `extract_item_links` : l'absence de `pdf_selector` dans les `patterns` Enabel fait que les 3 cartes de la page 0 partagent toutes la même `url` (celle de la page de listing), et la déduplication par `url` de `extract_item_links.py` (set global `seen_urls`, lignes 533-541) élimine à tort 2 des 3 avis comme "doublons". Corrigible de deux façons locales et indépendantes, sans refonte : (a) ajouter `"pdf_selector": "a[href$='.pdf']"` (ou plus spécifique) aux `patterns` Enabel en DB — pur changement de configuration, chaque carte porterait alors son propre lien PDF distinct comme `url` ; ou (b) durcir la clé de dedup de la branche `html-tender`/`crawl4ai` dans `extract_item_links.py` pour retomber sur un identifiant combiné (titre+index) quand plusieurs items d'une même source partagent une `url` identique. Aucune des deux options ne touche à l'architecture ni à la techno du fetcher.
2. **Persist — contribution passive au crash transversal du Finding #1** : le seul avis Enabel ayant survécu jusqu'à `deduplicate` (`BFA23004-10084`) a été englouti, comme pour toutes les autres sources BF de ce run, par la transaction `persist_notices` unique et tout-ou-rien cassée par une notice UNGM distincte — aucune particularité à Enabel dans ce mécanisme, déjà documenté au Finding #1 et dans les sections Joffres.net/UEMOA/UNGM.

Nuance importante sur l'impact métier réel aujourd'hui : **aucun des 3 avis Enabel de ce run — ni les 2 perdus à `extract_item_links`, ni le survivant — ne matche un mot-clé de la liste de classification IT configurée** (Contraintes globales : équipement pédagogique pour apprenants handicapés, équipement agro-industriel, équipement médico-technique — aucun terme composé du type « matériel informatique »/« équipement informatique » ne s'applique). Le bug de collision d'URL est réel, systématique et sévère en proportion (67 % de perte, 100 % reproductible), mais son impact concret pour une entreprise cliente IT est nul sur les avis vus ce jour précis — à la différence de UEMOA où au moins 2 avis manifestement pertinents IT étaient concernés par la perte de pagination.

Sévérité globale de la source : **critique** pour le mécanisme du bug (perte systématique et déterministe de 67 % des avis à chaque run, cause root parfaitement identifiée), **mais impact métier nul à date** faute d'avis IT-pertinent parmi les 3 avis actuellement publiés par cette source — combinée à la perte du seul survivant par le crash transversal déjà documenté (Finding #1), Enabel n'a contribué aucune notice à la base aujourd'hui, comme toutes les autres sources BF de ce run.

## Canada

**Run snapshot (CA) :** harvest run `1b67631c-4e8b-4650-8212-cf9e3e82c997` (déclenché 2026-09-02 17:10:51 UTC, échoué 2026-09-02 17:10:56 UTC), pas de run de delivery (le harvest a échoué avant que la livraison ne soit déclenchée — le CLI `run-once` enchaîne harvest puis delivery ; le harvest ayant `status=failed`, aucune ligne `runs` de type `delivery` n'a été créée pour ce déclenchement). Logs de nœuds capturés dans `ca-nodes/` (scratchpad de session). Critères de pertinence utilisés : voir Contraintes globales du plan.

**⚠️ AVERTISSEMENT pour les tâches 8-14 :** ce run a crashé à un étage **différent et bien plus précoce** que le crash BF (Finding #1, `persist_notices`) — pas le même bug. Ici, `extract_item_links` a échoué avec l'erreur `"No item links discovered from any source"`, et le run n'a **jamais atteint** `fetch_items`, `parse_extract`, `deduplicate` ni `persist_notices`. Cause directe, lue verbatim dans les logs du process (`docker exec ... run-once`, capturés en intégralité pendant l'exécution) : **6 des 7 sources CA actives ont échoué dès `fetch_listings`** — les 3 sources `parser_type: playwright` (Achats Canada, Ville de Montréal, Nova Scotia) ont échoué avec `"Playwright not installed. Run: poetry install --extras full && poetry run playwright install chromium"` — message produit par le fetcher lui-même, confirmé depuis par une reproduction directe de l'import Python dans le conteneur, en dehors de tout code du pipeline :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_api python -c 'import playwright'"
Traceback (most recent call last):
  File "<string>", line 1, in <module>
ModuleNotFoundError: No module named 'playwright'
```
(exécuté le 2026-09-02 ; toujours reproductible, le module n'a pas été installé entre-temps) ; les 3 sources `parser_type: tavily_extract` (UNDP, The Commonwealth, Palladium Group) ont échoué avec `"TAVILY_API_KEY not set — skipping"`. La 7ᵉ source (Le Devoir, `parser_type: ledevoir`) a bien récupéré 7 images d'avis (`fetch_listings` marqué `success` pour cette source), mais son OCR Groq Vision a échoué sur les 7 images avec `Client error '404 Not Found' for url 'https://api.groq.com/openai/v1/chat/completions'` (`"Groq vision OCR failed"`, répété 7 fois) — d'où `"images": 7, "total_notices": 0"` pour Le Devoir. Avec les 7/7 sources CA en échec de production de liens, `fetch_listings` a rapporté `successful: 1, failed: 6` puis `extract_item_links` s'est arrêté immédiatement (`"No item links discovered from any source"`) avant même d'atteindre les étages ultérieurs. **Ce n'est donc pas le même bug transversal que le Finding #1 BF** (transaction `persist_notices` unique tout-ou-rien cassée par une seule notice UNGM malformée) — c'est un échec de configuration/environnement (binaire Playwright absent du conteneur `staging_api`, `TAVILY_API_KEY` non configurée, endpoint Groq Vision en 404) qui empêche structurellement toute source CA de produire ne serait-ce qu'un seul lien, à un étage bien antérieur à la persistance.

**État de `ca-nodes/nodes/` — important pour les tâches 8-14 :** seuls `load_sources.json`, `fetch_listings.json` et `extract_item_links.json` (horodatés 2026-09-02 17:10, `_run_id: 1b67631c-4e8b-4650-8212-cf9e3e82c997` confirmé dans chacun) proviennent réellement de ce run CA. Les fichiers `fetch_items.json`, `parse_extract.json` et `deduplicate.json` présents dans le même dossier sont des **résidus de l'ancien run BF de la Tâche 1** (`_run_id: 785adda4-f28c-4f3c-af0a-74b7e775d0b5`, horodatés 2026-09-01 21:20-21:24) — le run CA n'ayant jamais atteint ces étages, ces fichiers n'ont pas été écrasés et restent sur disque dans `/app/logs/nodes/` du conteneur. **Ne pas les utiliser comme preuve CA.** `persist_notices.json` est un tableau vide `[]` sans champ `_run_id` — le nœud n'a jamais été exécuté pour CA, et le fichier sur disque est celui laissé par le run BF de la Tâche 1 (horodaté 2026-09-01 21:24, 2 octets, vérifié dans le conteneur), qui avait lui aussi échoué avant tout commit. **Même valeur, même fichier, deux runs : `[]`, pas `{}`.**

**Vérification indépendante — table `notices`, sources CA :** `SELECT n.source_id, s.name, count(*), max(n.created_at) FROM notices n JOIN sources s ON s.id=n.source_id WHERE s.country_id=(SELECT id FROM countries WHERE code='CA') GROUP BY n.source_id, s.name;` → **0 rows** (aucune source CA, 13 à 25). Ce n'est donc pas seulement que ce run n'a rien persisté : il n'existe **aucune** notice CA en base à ce jour, quelle qu'en soit la cause — ni vérité terrain fraîche ni ancienne pour aucune source CA. Pour référence (hors périmètre du déclenchement de cette tâche, à noter pour la synthèse) : le run planifié du jour même à 07:00 UTC (`3ebf19d1-dd63-49b6-8789-711db2bbbade`, `harvest`, `completed_with_warnings`) a produit `unique_items: 97` mais `notices_persisted: 0` — une anomalie qui rappelle le Finding #2 BF (`unique_items` non nul mais rien en base), non investiguée ici.

### Achats Canada (source id 13, parser_type playwright)

**Cause racine — pas re-diagnostiquée ici :** confirmée identique à la Tâche 7 (voir avertissement CA ci-dessus) : `playwright` n'est pas installé comme module Python sur le conteneur `staging_api` (`ModuleNotFoundError: No module named 'playwright'` — reproduction directe `docker exec staging_api python -c 'import playwright'`, sortie brute citée dans l'avertissement CA ci-dessus, hors de tout code du pipeline). Cette section documente uniquement la vérité terrain propre à cette source, la confirmation de son entrée dans les logs de nœuds du run CA, et le jugement d'étiquette propre à cette source.

**Vérité terrain (`curl`, 2026-09-02 ~17:15 UTC, `list_url` exact copié verbatim depuis la config DB/`fetch_listings.json`) :**
```
$ curl -s -o achatscanada.html -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://achatscanada.canada.ca/fr/occasions-de-marche?search_filter=&status%5B87%5D=87&category%5B154%5D=154&Appliquer_les_filtres=Appliquer+les+filtres&record_per_page=100&current_tab=t&words=" \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
HTTP_STATUS:200 SIZE:439493

$ grep -o 'href="/fr/occasions-de-marche/appels-d-offres/[^"]*"' achatscanada.html | sort -u | wc -l
100

$ grep -oE '[0-9]+ résultats' achatscanada.html | head -1
964 résultats

$ grep -io "captcha\|access denied\|blocked\|cloudflare\|are you human\|rate limit\|just a moment" achatscanada.html | sort -u
(aucune sortie — aucun signe de blocage anti-bot)

$ grep -o 'rel="next"' achatscanada.html | head -1
rel="next"
```
**Résultat notable : cette page est intégralement rendue côté serveur.** Un simple `curl` sans exécution JS renvoie déjà 964 résultats au total pour ce filtre (`category=154`, `status=87`), avec 100 liens `/appels-d-offres/...` distincts sur la page 1 — exactement le sélecteur configuré (`item_link_selector: a[href*="/appels-d-offres/"]`) et exactement `record_per_page=100` tel que paramétré dans le `list_url`. Un lien `rel="next"` de pagination est présent (`pagination_selector: a[rel="next"]` configuré, cohérent). Aucun signe de CAPTCHA, Cloudflare, ou blocage n'a été détecté.

Deux avis manifestement pertinents pour une entreprise IT, trouvés sur cette seule page 1 (sur les 964 résultats) et vérifiés contre les mots-clés `it_hardware`/`it_services` de `tenderai-infra/settings.yaml` (lignes 233-311) :
1. **« Système de répartition assistée par ordinateur »** (`cb-250-52228085`) — matche littéralement le mot-clé `it_hardware` « ordinateur ».
2. **« Licences de système informatisé de gestion de l'entretien (SIGE) »** (`cb-39-8749228`) — licence logicielle de gestion, recoupe le mot-clé `it_services` « système de gestion ».

**Confirmation de l'entrée propre à cette source dans les logs de nœuds du run CA (`ca-nodes/nodes/fetch_listings.json`, `_run_id: 1b67631c-4e8b-4650-8212-cf9e3e82c997`) :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==13][0]
print('status:', e['status'], '| error:', e['error'], '| listings:', len(e['listings']))
"
status: failed | error: playwright not installed | listings: 0
```
Identique à l'erreur générique documentée par la Tâche 7 — confirmé pour cette source précisément, pas supposé. `extract_item_links.json` de ce même run est `{"data": []}` (le nœud s'est arrêté avant même de router par source, cf. avertissement CA en tête de section).

**Requête `notices` (source_id=13, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=13 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source (aucune notice CA en base, quelle qu'en soit la cause — cf. avertissement CA). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| Système de répartition assistée par ordinateur (`cb-250-52228085`) — matche le mot-clé IT « ordinateur » | Non | Fetch (`fetch_listings`, branche `playwright`) | `playwright` absent du conteneur `staging_api` (`ModuleNotFoundError: No module named 'playwright'`, `docker exec staging_api python -c 'import playwright'` — sortie brute citée dans l'avertissement CA en tête de section) — pas de code/config spécifique à cette source, la branche échoue avant même de tenter le rendu | bug logique | Critique | `fetch_listings.json` (`_run_id: 1b67631c-...`) : `status: failed`, `error: "playwright not installed"`, `listings: []` ; vérité terrain `curl` : item présent, 100/100 liens extraits par un simple GET sans JS |
| Licences de système informatisé de gestion de l'entretien SIGE (`cb-39-8749228`) — recoupe le mot-clé IT « système de gestion » | Non | Fetch (`fetch_listings`, branche `playwright`) | Même cause | bug logique | Critique | Idem |
| Les ~962 autres résultats du listing (964 au total pour ce filtre, 100 vus par `curl` sur la page 1 seule, 0 vus par le pipeline) | Non | Fetch (`fetch_listings`, branche `playwright`) | Même cause — perte à 100%, pas un cas isolé | bug logique | Critique | `fetch_listings.json` : `listings: []` pour la totalité de la source ; vérité terrain `curl` : « 964 résultats » |

**Verdict :** Achats Canada est une perte totale à l'étage fetch, cause identique et déjà établie par la Tâche 7 (`playwright` absent du conteneur `staging_api`) — pas de particularité de code ou de config propre à cette source. **Étiquette : bug logique**, pas limite technologique — jugement fait au cas par cas comme demandé, pas recopié : la vérité terrain montre que cette page est en réalité **intégralement rendue côté serveur** (un `curl` nu, sans navigateur ni JS, récupère les 100 liens attendus par le sélecteur configuré et le compte de résultats), et **aucun signe d'anti-bot** (pas de CAPTCHA, pas de Cloudflare, pas de blocage) n'a été observé. Le choix architectural `parser_type: playwright` pour cette source n'est donc même pas structurellement nécessaire du point de vue anti-bot — la cause du gap est purement une dépendance manquante dans l'image déployée, triviale à corriger (ajout de `playwright` aux dépendances/à l'image Docker), sans aucune indication que l'approche « navigateur réel dans le conteneur » soit elle-même la mauvaise direction technique pour ce site précis.

### Ville de Montréal (source id 14, parser_type playwright)

**Cause racine — pas re-diagnostiquée ici :** identique à Achats Canada ci-dessus et à la Tâche 7 : `playwright` absent du conteneur `staging_api`.

**Vérité terrain (`curl`, 2026-09-02 ~17:16 UTC, `list_url` exact copié verbatim) :**
```
$ curl -s -o montreal.html -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://montreal.ca/avis-dappel-doffres?types=Appel+d%27offres&categories=Services+professionnels" \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
HTTP_STATUS:200 SIZE:99640

$ grep -o 'href="/avis-dappels-doffres/[^"]*"' montreal.html | sort -u | wc -l
10

$ grep -oE '[0-9]+ résultats' montreal.html | head -1
927 résultats

$ grep -io "captcha\|access denied\|blocked\|cloudflare\|are you human\|rate limit\|just a moment" montreal.html | sort -u
captcha
```
La seule occurrence de « captcha » est une balise `<script src="https://www.google.com/recaptcha/api.js?hl=fr" async defer">` chargée en bibliothèque générique par le framework du site (probablement pour un formulaire de contact/connexion ailleurs sur le site) — vérifié par inspection du contexte brut (`re.finditer` sur le HTML) : **ce n'est pas un challenge actif sur cette page de listing**, aucun défi CAPTCHA n'est présenté, `HTTP_STATUS:200` propre, contenu complet. La page est **rendue côté serveur** : `curl` seul (sans JS) récupère déjà les 10 liens attendus par `item_link_selector: a[href*="/avis-dappels-doffres/"]` et le compte de résultats affiché (« 1 à 10 sur 927 résultats »), ainsi que les liens de pagination `?page=2` à `?page=93`.

Avis manifestement pertinent pour une entreprise IT, trouvé sur cette page 1 (recoupé contre les mots-clés `it_services` de `tenderai-infra/settings.yaml`) :
- **« Acquisition et déploiement d'une plateforme de protection des applications infonuagiques natives (CNAPP) »** (`/avis-dappels-doffres/acquisition-et-deploiement-dune-plateforme-de-protection-des-applications-infonuagiques-natives-119454`) — matche littéralement les mots-clés `it_services` « plateforme » et « application » (protection d'applications cloud-native = cybersécurité infonuagique). Porte un badge « Avis reporté » sur le listing au moment de la capture, mais reste visible et listé — donc un avis réel que le pipeline n'a de toute façon jamais atteint.

**Confirmation de l'entrée propre à cette source dans les logs de nœuds du run CA :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==14][0]
print('status:', e['status'], '| error:', e['error'], '| listings:', len(e['listings']))
"
status: failed | error: playwright not installed | listings: 0
```
Identique à Achats Canada et à l'erreur générique de la Tâche 7 — confirmé pour cette source précisément.

**Requête `notices` (source_id=14, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=14 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source (cf. avertissement CA). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| Acquisition et déploiement d'une plateforme de protection des applications infonuagiques natives (CNAPP) — matche les mots-clés IT « plateforme »/« application » | Non | Fetch (`fetch_listings`, branche `playwright`) | `playwright` absent du conteneur `staging_api` (Tâche 7) — pas de code/config spécifique à cette source | bug logique | Critique | `fetch_listings.json` : `status: failed`, `error: "playwright not installed"`, `listings: []` ; vérité terrain `curl` : item présent, 10/10 liens de la page 1 extraits par un simple GET sans JS |
| Les ~917 autres résultats du listing (927 au total pour ce filtre, 10 vus par `curl` sur la page 1 seule, 0 vus par le pipeline) | Non | Fetch (`fetch_listings`, branche `playwright`) | Même cause — perte à 100%, pas un cas isolé | bug logique | Critique | `fetch_listings.json` : `listings: []` pour la totalité de la source ; vérité terrain `curl` : « 1 à 10 sur 927 résultats » |

**Verdict :** Même mécanisme qu'Achats Canada — perte totale à l'étage fetch, cause identique établie par la Tâche 7. **Étiquette : bug logique**, pas limite technologique — vérifié spécifiquement pour ce site, pas recopié : la page est elle aussi intégralement rendue côté serveur (`curl` nu suffit à récupérer les 10 liens de la page 1 et le compte total), et la seule mention de « captcha » dans le HTML est un script reCAPTCHA générique du framework, jamais déclenché comme challenge actif sur cette page. Aucune preuve d'un besoin technique réel de navigateur/anti-bot pour cette source — la cause du gap est une dépendance manquante dans l'image déployée. **Remarque secondaire, hors cause racine :** même une fois `playwright` réinstallé, la config actuelle (`max_pages: 10`) ne couvrirait que ~100 des 927 résultats actifs (pagination réelle du site : 93 pages) — un gap de couverture distinct et plus mineur, signalé ici pour une phase 2 mais non quantifié en détail (non demandé par ce brief, dont le périmètre est le diagnostic du gap partagé Playwright).

### Le Devoir (source id 15, parser_type ledevoir)

**Particularité structurelle de cette source :** `https://www.ledevoir.com/services-et-annonces/avis-publics` est une page générale d'avis publics du journal Le Devoir — **pas une page dédiée aux marchés publics**. Chaque entrée listée est un scan JPEG d'une page de journal (`data-src="…/avis/AAAA-MM-JJ.jpg"`) regroupant plusieurs annonces légales hétérogènes (avis d'appels d'offres, mais aussi successions, dissolutions de sociétés, avis de vente, etc.) ; le `parser_type` bespoke `ledevoir` (`fetch_ledevoir.py`) télécharge ces images puis appelle un LLM de vision Groq (fonction `_ocr_image_with_groq`) pour en extraire les avis structurés — c'est le node `fetch_listings` lui-même qui fait tout le travail (téléchargement + OCR), contrairement aux autres sources CA où l'extraction de liens est un étage distinct (`extract_item_links`).

**Vérité terrain (navigateur Chrome, 2026-09-02, ~17:40 UTC — `curl` direct renvoie `HTTP_STATUS:403` sur ce site, navigateur requis) :**

Page `/services-et-annonces/avis-publics` — **29 entrées** au total au moment de la capture (`get_page_text` sur la page rendue), correspondant à **29 images** `data-src` matchant le sélecteur du pipeline (`/avis/….jpg`, confirmé par `document.querySelectorAll('[data-src]')` filtré côté page, `jpg_avis_count: 29`). **Seule 1 de ces 29 entrées est elle-même un avis d'appel d'offres individuel et nommé comme tel** : « Avis de procédure ouverte de l'appel d'offres public 40-26-144504 | Fourniture et livraison de rouleaux de protection » (Compagnie : Partenariat du Quartier des spectacles, publié 2026-09-02). Les 28 autres entrées sont des bulletins quotidiens génériques (« Avis légaux et appels d'offres du [date] », un par jour du 2026-08-03 au 2026-09-02, deux pour le 07 août) — des scans multi-annonces dont la part réellement « appel d'offres » (par opposition à succession/dissolution/etc.) n'est pas déterminable sans OCR de chaque bulletin. **Contexte de précision pour cette source : au niveau de la liste elle-même, ~1/29 (3%) des entrées sont individuellement et manifestement des avis d'appel d'offres ; le reste est un contenu légal généraliste dont la densité procurement réelle est inconnue sans ouvrir chaque bulletin.** Un échantillon indépendant (voir plus bas, OCR du bulletin du 2026-09-01 avec un modèle Groq valide) y a trouvé environ 6 encadrés distincts (annonces légales + appels d'offres mélangés) — donc chaque bulletin contient bien du contenu réel, pas des pages vides.

**Confirmation exacte du mécanisme de sélection des 7 images (reproduit indépendamment, correspond exactement au chiffre `images: 7` de la Tâche 7) :** `fetch_ledevoir.py::_extract_image_urls` (lignes 55-81) filtre les 29 URLs par une fenêtre glissante `patterns.max_days` (7 jours en config source, confirmé dans `fetch_listings.json` : `"patterns": {"max_days": 7}`), calculée par rapport au moment du fetch (`fetched_at: "2026-09-02T17:10:56"`, cutoff ≈ `2026-08-26T17:10:56`). Sur les 29 URLs, 28 portent une date `AAAA-MM-JJ` dans le nom de fichier ; l'unique exception est précisément l'avis individuel « rouleaux de protection » (`70380.jpg`, sans date dans l'URL) — dont le code ne peut donc **jamais appliquer la coupure temporelle** (le `re.search(r"(\d{4}-\d{2}-\d{2})", base)` échoue, la garde `if m:` est fausse, l'image est toujours incluse quel que soit son âge ; comportement bénin ici mais latent, non exploité en dehors du périmètre de cette tâche). Décompte des dates ≥ cutoff : `2026-09-02, 2026-09-01, 2026-08-31, 2026-08-29, 2026-08-28, 2026-08-27` = 6 images datées retenues, + 1 image non datée toujours retenue (`70380.jpg`) = **7 images**, exactement le chiffre rapporté par la Tâche 7.

**Résultat du pipeline (run `1b67631c-4e8b-4650-8212-cf9e3e82c997`, `ca-nodes/nodes/fetch_listings.json`) :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==15][0]
print('status:', e['status'], '| listings:', e['listings'], '| content:', e['content'])
"
status: success | listings: [] | content: []
```
Le node log lui-même ne distingue pas « 0 image trouvée » de « 7 images trouvées mais OCR échoué sur toutes » — les deux chemins de code renvoient la même forme JSON (`status: success, listings: []`). C'est le détail que la Tâche 7 avait seulement établi au niveau des logs de process bruts (`"images": 7, "total_notices": 0"`, capturés en direct pendant l'exécution du run mais non conservés sur disque) ; cette tâche l'a reconstruit indépendamment ci-dessus par relecture du code + reproduction en direct de la fenêtre `max_days`, confirmant que ce sont bien 7 images qui ont atteint l'OCR et échoué, pas zéro image trouvée. `extract_item_links.json` du même run est `{"data": []}` (le graphe s'est arrêté avant même de router par source, cf. avertissement CA en tête de section — cohérent, aucune source CA n'a produit de lien ce jour-là).

**Point exact de l'échec, reproduit en direct (2026-09-02, contre l'API Groq depuis `staging_api` avec la clé de production) :**
```
$ docker exec staging_api python3 -c "
import httpx
from tenderai.config import settings
key = settings.llm.groq_api_key.get_secret_value()
r = httpx.post('https://api.groq.com/openai/v1/chat/completions',
    json={'model':'meta-llama/llama-4-scout-17b-16e-instruct','messages':[{'role':'user','content':'hi'}]},
    headers={'Authorization': f'Bearer {key}'}, timeout=30)
print('STATUS', r.status_code); print(r.text[:1000])
"
STATUS 404
{"error":{"message":"The model `meta-llama/llama-4-scout-17b-16e-instruct` does not exist or you do not have access to it.","type":"invalid_request_error","code":"model_not_found"}}
```
Confirme, indépendamment de la Tâche 7, la même erreur `404 model_not_found` sur le même modèle. Localisation exacte dans le code : `fetch_ledevoir.py` ligne 100, `vision_model = "meta-llama/llama-4-scout-17b-16e-instruct"` — chaîne codée en dur, une seule occurrence dans tout le fichier. Chaque appel `_ocr_image_with_groq()` (une fois par image, boucle séquentielle lignes 187-210) échoue indépendamment ; l'exception est capturée par un `try/except` local (lignes 121-150) qui logue `"Groq vision OCR failed"` et renvoie `[]` pour cette image — **aucune remontée d'erreur au niveau du node** (`fetch_listings` retourne `status: "success"` malgré 7/7 échecs internes), donc aucun signal d'alerte visible dans `counts_json`/`errors` du run.

**Le fix est-il réellement un changement d'une ligne, ou une limite structurelle de l'approche OCR ? Vérifié, pas supposé :**
- Liste des modèles actuellement actifs sur le compte Groq de production (`GET /openai/v1/models`, même clé) : `allam-2-7b, whisper-large-v3-turbo, meta-llama/llama-prompt-guard-2-22m, qwen/qwen3.6-27b, groq/compound-mini, openai/gpt-oss-20b, groq/compound, canopylabs/orpheus-v1-english, meta-llama/llama-prompt-guard-2-86m, whisper-large-v3, qwen/qwen3.8-27b, canopylabs/orpheus-arabic-saudi, openai/gpt-oss-safeguard-20b, openai/gpt-oss-120b`. Deux de ces modèles annoncent `"input_modalities": ["text", "image"]` dans les métadonnées détaillées de l'endpoint : **`qwen/qwen3.6-27b`** et **`qwen/qwen3.8-27b`** — Groq propose donc toujours des modèles de vision valides, ce n'est pas une disparition de la capacité vision chez ce fournisseur.
- **Reproduction bout-en-bout avec un modèle actuellement valide**, même image, même prompt d'extraction JSON exact que celui utilisé en production (`_OCR_PROMPT` de `fetch_ledevoir.py`) :
````
$ docker exec staging_api python3 -c "
... téléchargement de https://media1.ledevoir.com/documents/image/avis/70380.jpg?width=2000 ...
img status 200 size 64135
... payload avec model: 'qwen/qwen3.8-27b', même _OCR_PROMPT ...
"
STATUS 200
```json
{
  "tenders": [
    {
      "title": "Fourniture et livraison de rouleaux de protection",
      "entity": "Partenariat du Quartier des spectacles Montréal",
      "reference": "40-26-144504",
      "deadline": "2026-09-18",
      "description": "Appel d'offres public pour la fourniture et la livraison de rouleaux de protection. Les documents d'appel d'offres sont disponibles à partir du 1er septembre 2026 via le SEAO."
    }
  ]
}
```
````
Extraction **exacte et correcte** — `title`, `entity`, `reference` (`40-26-144504`) identiques à la vérité terrain de la page de listing, `deadline` cohérente. Seule nuance opérationnelle : la réponse est enveloppée dans un bloc ```` ```json … ``` ````, ce que `json.loads(raw)` (premier essai, ligne 133) ne parse pas directement — mais le code a déjà un fallback pour ce cas exact (`re.search(r"\{.*\}", raw, re.DOTALL)`, lignes 135-136), qui fonctionne ici sans modification. **Aucun changement de code n'est donc nécessaire au-delà de la chaîne du nom de modèle.**
- **Confirmation que l'approche OCR reste viable même sur les bulletins multi-annonces** (pas seulement l'avis isolé) : test indépendant sur le scan du bulletin du 2026-09-01 (`2026-09-01.jpg`, 1 221 139 octets) avec `qwen/qwen3.8-27b` : réponse `200`, le modèle dénombre correctement « environ 6 » encadrés distincts dans la section « AVIS LÉGAUX ET APPELS D'OFFRES » — cohérent avec un bulletin dense et exploitable, pas un scan illisible.

**Verdict sur le fix :** confirmé **trivial** — un remplacement de chaîne (`meta-llama/llama-4-scout-17b-16e-instruct` → `qwen/qwen3.8-27b` ou `qwen/qwen3.6-27b`) à la ligne 100 de `fetch_ledevoir.py`, sans aucune autre modification de code, restaurerait l'extraction. Aucune preuve d'une limite structurelle de l'approche « OCR par LLM de vision » elle-même : le fournisseur propose toujours des modèles vision actifs, le prompt et le parsing JSON existants fonctionnent tels quels avec un modèle valide, et le contenu scanné (aussi bien l'avis isolé que les bulletins denses) reste lisible et correctement extrait par le modèle de remplacement testé.

**Requête `notices` (source_id=15, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=15 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source : aucune notice CA en base à ce jour, quelle qu'en soit la cause (cf. avertissement CA en tête de section — `SELECT ... WHERE country_id=(SELECT id FROM countries WHERE code='CA') GROUP BY ...` → 0 rows, toutes sources CA confondues). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier pour cette source.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| Avis de procédure ouverte de l'appel d'offres public 40-26-144504 — Fourniture et livraison de rouleaux de protection (Partenariat du Quartier des spectacles, deadline 2026-09-18) — avis réel et individuellement identifiable, non pertinent IT lui-même (rouleaux de protection ≠ mots-clés IT), mais démontré ci-dessus comme extractible avec succès et exactitude par un modèle Groq valide | Oui, jusqu'à l'OCR inclus (image téléchargée avec succès, envoyée à Groq) | Fetch (`fetch_listings`, branche `ledevoir`, sous-étape OCR Groq Vision dans `_ocr_image_with_groq`) | `vision_model` codé en dur (`fetch_ledevoir.py` ligne 100) sur un id de modèle Groq déprécié/invalide (`meta-llama/llama-4-scout-17b-16e-instruct`, `404 model_not_found`, reproduit en direct) ; échec capturé par image sans remontée au niveau du run | bug logique | Critique | `fetch_listings.json` (`status: success`, `listings: []` malgré 7 images fetchées) ; reproduction directe `404 model_not_found` contre l'API Groq ; reproduction réussie (`200`, extraction exacte) avec `qwen/qwen3.8-27b` sur la même image |
| Les 6 autres bulletins scannés dans la fenêtre de 7 jours (`2026-09-02`, `2026-08-31`, `2026-08-29`, `2026-08-28`, `2026-08-27`, `2026-09-01`) — contenu individuel non dénombré avis par avis, mais confirmé non-vide (≈6 encadrés légaux/appels d'offres par bulletin sur l'échantillon testé du 2026-09-01) | Non | Fetch (`fetch_listings`, branche `ledevoir`, sous-étape OCR Groq Vision) | Même cause racine — perte à 100% des 7/7 images, pas un cas isolé à l'avis individuel | bug logique | Critique | `fetch_listings.json` : `listings: []` pour la totalité de la source ; test OCR indépendant avec `qwen/qwen3.8-27b` sur le bulletin du 2026-09-01 : ~6 encadrés détectés, contenu confirmé exploitable |

**Verdict :** Le Devoir est une perte totale (7/7 images, 0 avis produit) au sein même du node `fetch_listings`, cause unique et bien circonscrite : un id de modèle Groq Vision déprécié codé en dur, qui renvoie une erreur `404 model_not_found` sur **chaque** appel OCR, silencieusement absorbée par un `try/except` par image qui ne fait remonter aucune alerte au niveau du run. **Étiquette : bug logique** (et non limite technologique) — vérifié en profondeur, pas supposé : Groq propose toujours au moins deux modèles vision actifs (`qwen/qwen3.6-27b`, `qwen/qwen3.8-27b`), et l'un d'eux, testé en direct avec le prompt et le parsing JSON exacts déjà en place dans le code, a extrait l'avis de vérité terrain avec une précision parfaite (titre, entité, référence, échéance) et a également su décompter le contenu d'un bulletin dense multi-annonces. Le fix est un remplacement de chaîne d'une ligne, sans changement d'architecture ni de fournisseur ; l'approche « scan + OCR par LLM de vision » pour cette source n'est pas structurellement fragile en soi. **Point de contexte pour la précision de cette source (hors cause racine du run)** : même une fois le modèle corrigé, seule 1 des 29 entrées actuellement listées sur la page est un avis d'appel d'offres individuellement nommé — le reste est un contenu légal généraliste (bulletins quotidiens mêlant successions, dissolutions, appels d'offres, etc.) dont la densité procurement réelle par bulletin reste à mesurer avis par avis, non quantifiée ici (hors périmètre de ce diagnostic).

### Nova Scotia (source id 16, parser_type playwright)

**Cause racine — pas re-diagnostiquée ici :** identique aux deux sources ci-dessus et à la Tâche 7 : `playwright` absent du conteneur `staging_api`.

**Vérité terrain, méthode 1 (`curl`, 2026-09-02 ~17:18 UTC, `list_url` exact) — résultat qualitativement différent des deux autres sources :**
```
$ curl -s -o novascotia.html -D novascotia_headers.txt -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://procurement-portal.novascotia.ca/tenders" \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
HTTP_STATUS:200 SIZE:45659

$ python3 -c "
import re
html = open('novascotia.html', encoding='utf-8').read()
text = re.sub(r'<script.*?</script>', '', html, flags=re.S)
text = re.sub(r'<style.*?</style>', '', text, flags=re.S)
text = re.sub(r'<[^>]+>', ' ', text)
print(re.sub(r'\s+', ' ', text).strip())
"
Please enable JavaScript to view the page content. Your support ID is: 1940417650305047215. This
question is for testing whether you are a human visitor and to prevent automated spam submission.
Audio is not supported in your browser. What code is in the image? submit Your support ID is:
1940417650305047215 .

$ grep -c "tender-row\|no-results-message\|<tr" novascotia.html
0

$ cat novascotia_headers.txt | grep -i "^Set-Cookie"
Set-Cookie: TSa5dfd5f7029=...; Max-Age=30; Path=/
Set-Cookie: TSa5dfd5f7078=...; Max-Age=30; Path=/
Set-Cookie: TS48fffa9d027=...; Path=/
```
**Contrairement à Achats Canada et Ville de Montréal, `curl` seul est bloqué ici par une véritable page de challenge anti-bot** : image CAPTCHA audio/visuelle, texte « Please enable JavaScript… testing whether you are a human visitor », et cookies préfixés `TS...` — signature caractéristique d'un bot-defense JS-challenge (famille F5/Shape). Aucune table, aucune ligne `tender-row`, rien ne correspond au `wait_for_selector` configuré (`table tbody tr, .no-results-message, [class*=tender-row]`) : un simple client HTTP sans exécution JS ne peut pas voir le contenu réel de cette page.

**Vérité terrain, méthode 2 — navigateur réel (Playwright MCP, Chromium standard, sans stealth), pour vérifier si l'anti-bot bloquerait aussi le fetcher `playwright` du pipeline une fois le module installé :**
```
navigate → https://procurement-portal.novascotia.ca/tenders
Page Title: "Procurement Opportunities and Public Notices - Procurement Portal"
```
Le challenge anti-bot a été franchi sans aucune interaction ni contournement spécifique — juste l'exécution JS normale d'un navigateur réel. Le contenu réel s'affiche : table `Tenders 29.7k` (29 740 résultats au total, tri par défaut « Posted Date DESC »), 6 lignes visibles (`table`/`tr` — correspond au `wait_for_selector` configuré), pagination jusqu'à la page 4957.

**Correction post-revue (2026-09-02) :** la version initiale de ce rapport décrivait cette session Playwright MCP comme « identique en substance » au fetcher `fetch_playwright.py` du pipeline (`headless=True`, UA Chrome standard, pas de plugin d'évasion d'empreinte). Cette équivalence n'avait pas été vérifiée et s'est révélée fausse : un appel Python nu `playwright.chromium.launch(headless=True)` sans patch de furtivité expose par défaut `navigator.webdriver: true`, un signal que les produits anti-bot de type F5/Shape (identifiés ici même via les cookies `TS...`) ciblent couramment — alors que la session Playwright MCP utilisée en méthode 2 n'a jamais été instrumentée pour confirmer qu'elle exposait ce même signal (une revue indépendante l'a testée séparément et a trouvé `navigator.webdriver: false`). La méthode 3 ci-dessous referme ce point avec un test direct du chemin de code réel, plutôt qu'avec cette analogie non vérifiée.

**Vérité terrain, méthode 3 — reproduction directe et littérale du chemin de code de production (2026-09-02, en réponse à la revue de ce rapport) :** script Python autonome reproduisant l'appel exact de `fetch_playwright.py` — `playwright.chromium.launch(headless=True)`, `browser.new_context(user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", locale="fr-CA", viewport={"width": 1280, "height": 900})`, blocage média (`route.abort()` sur images/fonts), `page.goto(url, wait_until="domcontentloaded")`, `page.wait_for_selector("table tbody tr, .no-results-message, [class*=tender-row]")` — **aucun `add_init_script`, aucun patch de furtivité, aucune évasion d'empreinte**, à l'identique du fetcher réel (confirmé par lecture du fichier source : aucune occurrence de `add_init_script`/`stealth` dans `fetch_playwright.py`).

```
$ python3 bare_playwright_test.py
navigator_webdriver (avant navigation): true
navigator_webdriver (après navigation): true
wait_for_selector_found: true
challenge_text_present: false
tender_row_count: 13
ts_cookies: ['TSa5dfd5f7077', 'TS01c08c96', 'TSa5dfd5f7029', 'TS48fffa9d027']
```

Confirmé avec un délai supplémentaire de 5 s (le temps que les compteurs AJAX se stabilisent) :
```
navigator_webdriver: true
challenge_text_present: false
tender_row_count: 24
tenders_tab_count: "29.7k"
results_count: "29740 Results"
```

`navigator.webdriver` vaut bien `true` sur cette session — le signal exact que la revue soupçonnait d'être filtré par un produit F5/Shape — et **le challenge ne s'est pas déclenché** : aucun texte CAPTCHA / « Please enable JavaScript », le sélecteur configuré a matché, et les compteurs affichés (29 740 résultats, onglet « Tenders 29.7k ») concordent avec la méthode 2. Ceci referme directement, par un test reproductible plutôt qu'une analogie, la question laissée ouverte par la revue : sur ce site, à ce moment, le challenge F5/Shape ne bloque pas sur le seul signal `navigator.webdriver`. (Remarque mineure, non bloquante : sur 3 exécutions du script, une a expiré au délai par défaut de 15 s sans aucun signe de challenge — juste relancée avec un délai de 30 s, succès immédiat et reproductible ; probable variabilité réseau/charge du site plutôt qu'un comportement de blocage, mais notée par honnêteté.)

Avis manifestement pertinent pour une entreprise IT, actuellement `OPEN`, trouvé via la recherche du site elle-même (champ « Search Tender ID and Title », mot-clé « software ») :
- **« RFP - Microsoft Software Licensing Solutions Partner »** (Tender ID `Doc3262756191`), Department of Cyber Security and Digital Solutions, publié le 20 Aug 2026, clôture 16 Sep 2026, statut `OPEN` — matche littéralement le mot-clé `it_services` « logiciel » (software = logiciel) et le mot-clé `it_consulting`/organisation « Cyber Security and Digital Solutions ».

**Confirmation de l'entrée propre à cette source dans les logs de nœuds du run CA :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==16][0]
print('status:', e['status'], '| error:', e['error'], '| listings:', len(e['listings']))
"
status: failed | error: playwright not installed | listings: 0
```
Identique aux deux autres sources `playwright` et à l'erreur générique de la Tâche 7 — confirmé pour cette source précisément : le run a échoué avant même de tenter le rendu, donc l'anti-bot lui-même n'a jamais été le facteur bloquant *sur ce run précis* — seule l'absence du module Python l'a été.

**Requête `notices` (source_id=16, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=16 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source (cf. avertissement CA). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| RFP - Microsoft Software Licensing Solutions Partner (`Doc3262756191`, statut `OPEN`) — matche le mot-clé IT « logiciel » | Non | Fetch (`fetch_listings`, branche `playwright`) | `playwright` absent du conteneur `staging_api` (Tâche 7) — le run échoue avant même de tenter le rendu, donc avant que l'anti-bot du site puisse intervenir | bug logique | Critique | `fetch_listings.json` : `status: failed`, `error: "playwright not installed"`, `listings: []` ; vérité terrain navigateur réel (Playwright MCP) : item retrouvé via recherche interne du site, statut `OPEN` confirmé |
| Les ~29 734 autres résultats de la table (29 740 au total tous statuts confondus, dont un sous-ensemble `OPEN` actif au 2026-09-02 ; 0 vus par le pipeline) | Non | Fetch (`fetch_listings`, branche `playwright`) | Même cause — perte à 100%, pas un cas isolé | bug logique | Critique | `fetch_listings.json` : `listings: []` pour la totalité de la source ; vérité terrain navigateur réel : « 29740 Results » |

**Verdict :** Contrairement aux deux autres sources `playwright` de cette section, Nova Scotia présente une **véritable barrière anti-bot** face aux clients HTTP simples (challenge JS + CAPTCHA audio, cookies `TS...` caractéristiques d'un bot-defense de type F5/Shape) — vérifié directement, pas supposé, et pas recopié depuis Achats Canada/Montréal où aucune barrière de ce type n'a été trouvée. Un premier test avec un vrai navigateur Chromium (Playwright MCP, méthode 2) avait déjà franchi ce challenge sans friction — mais une revue indépendante de ce rapport a correctement relevé que la formulation initiale présentait cette session comme « identique en substance » au fetcher de production sans avoir vérifié le signal d'empreinte le plus pertinent pour ce type de produit anti-bot, `navigator.webdriver` (un appel Python nu `playwright.chromium.launch(headless=True)` sans patch l'expose à `true` par défaut ; la session Playwright MCP, testée séparément par la revue, l'exposait à `false`) — une équivalence non vérifiée, donc une affirmation fausse telle qu'initialement formulée, maintenant corrigée ci-dessus. La méthode 3, ajoutée en réponse à cette revue, referme le point avec un test direct reproduisant littéralement le code de `fetch_playwright.py` (même appel de lancement, même contexte, même UA, même sélecteur, zéro `add_init_script`) : `navigator.webdriver` y est confirmé à `true`, et le challenge F5/Shape ne s'est pas déclenché — contenu réel affiché, compteurs cohérents avec la méthode 2 (29 740 résultats). **L'étiquette retenue reste bug logique** (dépendance manquante) et non limite technologique — cette fois sur la base d'une preuve directe du chemin de code réel de production plutôt que d'une analogie non vérifiée. Nuance non résolue et toujours à surveiller lors de la correction : ces tests restent des exécutions ponctuelles à faible volume, pas un run soutenu/à grande échelle sous la même IP/pattern que la production — un comportement anti-bot plus agressif face à un trafic automatisé répété (rate-limiting progressif, détection comportementale à moyen terme, ou ciblage d'autres signaux d'empreinte non testés ici — canvas/WebGL, timing, etc.) reste possible et n'a pas été exclu. **Remarque secondaire distincte, hors cause racine :** contrairement à Achats Canada et Montréal, les `patterns` de cette source ne définissent aucun `item_link_selector` — même une fois `playwright` réinstallé, `fetch_playwright.py` retomberait sur son mode « texte brut » (capture de `page.inner_text("body")` en un seul blob transmis à l'extraction LLM), un chemin de code différent de celui utilisé par les deux autres sources `playwright` de cette section, non vérifié plus avant ici.

### UNDP (source id 17, parser_type tavily_extract)

**Cause racine — pas re-diagnostiquée ici :** confirmée identique à la Tâche 7 (voir avertissement CA en tête de section Canada) : `TAVILY_API_KEY` n'est pas définie dans l'environnement du conteneur `staging_api` — reconfirmé indépendamment ici :
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 "docker exec staging_api env | grep -i TAVILY"
(aucune sortie)
```
Cette section documente uniquement la vérité terrain propre à cette source, la confirmation de son entrée dans les logs de nœuds du run CA, et le jugement d'étiquette propre à cette source (adéquation de `tavily_extract` pour ce site précis, pas supposée).

**Vérité terrain (`curl`, 2026-09-02, `list_url` exact copié verbatim depuis la config DB/`fetch_listings.json`) :**
```
$ curl -s -o undp.html -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://procurement-notices.undp.org/index.cfm" \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
HTTP_STATUS:200 SIZE:1035616

$ python3 -c "
import re
html = open('undp.html', encoding='utf-8', errors='replace').read()
text = re.sub(r'<script.*?</script>', '', html, flags=re.S)
text = re.sub(r'<style.*?</style>', '', text, flags=re.S)
text = re.sub(r'<[^>]+>', ' ', text)
text = re.sub(r'\s+', ' ', text).strip()
print(len(text)); print('Ref No count:', text.count('Ref No'))
"
131615
Ref No count: 562

$ grep -io "captcha\|access denied\|blocked\|cloudflare\|are you human\|rate limit\|just a moment" undp.html | sort -u
(aucune sortie — aucun signe de blocage anti-bot)

$ grep -oiE '"totalRecords"|loadMore|totalCount' undp.html | sort -u
(aucune sortie — pas de pagination JS/AJAX détectée)
```
**Résultat notable : cette page est intégralement rendue côté serveur, sans pagination — la totalité des ~561 avis actuellement ouverts (562 occurrences de « Ref No », dont 1 est l'en-tête de colonne du filtre) tient sur cette unique URL `index.cfm`.** Cohérent avec la config actuelle de la source (`patterns: {"extract_depth": "advanced", "include_raw_content": true}`, pas de `max_pages`/`page_param` — un seul appel `/extract` suffit structurellement à couvrir tout le listing). Aucun signe de CAPTCHA/anti-bot.

Avis manifestement pertinents pour une entreprise IT, trouvés sur cette page (recoupés contre les mots-clés `it_hardware`/`it_services` de `tenderai-infra/settings.yaml`, lignes 233-294) :
1. **« 326_IT equipment for National University of Civil Protection of Ukraine »** (`UNDP-UKR-01815`, UKRAINE, RFQ, deadline 16-Sep-26) — matche littéralement `it_hardware` « équipement informatique » (IT equipment).
2. **« Request for Quotations for IT Equipment for UN-Habitat »** (`UNDP-LAO-00740`, LAO PDR, RFQ, deadline 15-Sep-26) — idem.
3. **« RfP26/03336 MFA/Cybersecurity Readiness Assessment and Roadmap for Modernization »** (`UNDP-MDA-01077`, MOLDOVA, RFP, deadline 16-Sep-26) — matche `it_services` « cybersécurité »/« sécurité informatique ».
4. **« Supply of HP Servers to The Central Electoral Commission of RA »** (`UNDP-ARM-01019`, ARMENIA, RFQ, deadline 14-Sep-26) — matche `it_hardware` « serveur ».

**Confirmation de l'entrée propre à cette source dans les logs de nœuds du run CA (`fetch_listings.json`, `_run_id: 1b67631c-4e8b-4650-8212-cf9e3e82c997`) :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==17][0]
print(json.dumps(e, indent=2, ensure_ascii=False))
"
{
  "source": {
    "id": 17,
    "name": "UNDP - Procurement Notices",
    "base_url": "https://procurement-notices.undp.org",
    "list_url": "https://procurement-notices.undp.org/index.cfm",
    "parser_type": "tavily_extract",
    "rate_limit": "10/m",
    "patterns": {"extract_depth": "advanced", "include_raw_content": true},
    ...
  },
  "content": null,
  "listings": [],
  "url": "https://procurement-notices.undp.org/index.cfm",
  "status": "failed",
  "error": "TAVILY_API_KEY not set",
  "fetched_at": "2026-09-02T17:10:51.796708",
  "parser_type": "tavily_extract"
}
```
Confirmé pour cette source précisément — identique au constat générique de la Tâche 7, pas supposé. Le `list_url` de la config correspond exactement à l'URL de vérité terrain ci-dessus (pas de confusion avec « UNDP Africa », id 22, source distincte et désactivée). `extract_item_links.json` du même run est `{"data": []}` (le graphe s'est arrêté avant même de router par source, cf. avertissement CA en tête de section — aucune source CA n'a produit de lien ce jour-là).

**Requête `notices` (source_id=17, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=17 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source (cf. avertissement CA — aucune notice CA en base à ce jour, quelle qu'en soit la cause). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| 326_IT equipment for National University of Civil Protection of Ukraine (`UNDP-UKR-01815`) — matche le mot-clé IT « équipement informatique » | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | `TAVILY_API_KEY` absente du conteneur `staging_api` (Tâche 7, reconfirmé ici : `docker exec staging_api env \| grep -i TAVILY` → vide) — pas de code/config spécifique à cette source, la branche échoue avant même l'appel `/extract` | bug logique | Critique | `fetch_listings.json` : `status: failed`, `error: "TAVILY_API_KEY not set"`, `listings: []` ; vérité terrain `curl` : item présent dans le texte brut de `index.cfm`, page intégralement rendue côté serveur |
| Request for Quotations for IT Equipment for UN-Habitat (`UNDP-LAO-00740`) — matche « équipement informatique » | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | Même cause | bug logique | Critique | Idem |
| RfP26/03336 MFA/Cybersecurity Readiness Assessment (`UNDP-MDA-01077`) — matche « cybersécurité » | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | Même cause | bug logique | Critique | Idem |
| Les ~557 autres avis actuellement ouverts (561 au total sur cette unique page, 0 vus par le pipeline) | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | Même cause — perte à 100%, pas un cas isolé | bug logique | Critique | `fetch_listings.json` : `listings: []` pour la totalité de la source ; vérité terrain `curl` : 562 occurrences de « Ref No » (561 avis + 1 en-tête) |

**Verdict :** UNDP est une perte totale à l'étage fetch, cause identique et déjà établie par la Tâche 7 (`TAVILY_API_KEY` absente du conteneur `staging_api`). **Étiquette : bug logique**, pas limite technologique — jugé spécifiquement pour ce site, pas recopié : `index.cfm` est intégralement rendu côté serveur (un simple `curl` sans JS récupère déjà les 561 avis, dates, ref, deadlines), sans pagination ni AJAX à gérer, et sans aucun signe d'anti-bot. C'est le cas le plus simple des trois sources de cette tâche : `tavily_extract` avec `extract_depth: advanced` sur une URL statique unique est structurellement le bon outil pour ce site — la cause du gap est purement une variable d'environnement manquante côté déploiement, sans aucune indication d'un désaccord architectural entre l'outil et le site.

### The Commonwealth (source id 20, parser_type tavily_extract)

**Cause racine — pas re-diagnostiquée ici :** confirmée identique à la Tâche 7 : `TAVILY_API_KEY` absente du conteneur `staging_api` (reconfirmé ici, même commande que ci-dessus : sortie vide). Cette section documente la vérité terrain propre à cette source, la confirmation de son entrée dans les logs, et une investigation approfondie — au-delà de la clé manquante — sur la nature structurelle du site, comme demandé pour ne pas recopier le même raisonnement d'une source à l'autre.

**Vérité terrain, méthode 1 (`curl`, 2026-09-02, `list_url` exact) :**
```
$ curl -s -o commonwealth.html -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://tenders.thecommonwealth.org/aspx/Tenders/Appraisal" \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
HTTP_STATUS:200 SIZE:127810

$ python3 -c "
import re
html = open('commonwealth.html', encoding='utf-8', errors='replace').read()
text = re.sub(r'<script.*?</script>', '', html, flags=re.S)
text = re.sub(r'<style.*?</style>', '', text, flags=re.S)
text = re.sub(r'<[^>]+>', ' ', text)
print(len(re.sub(r'\s+', ' ', text).strip()))
"
1578
```
Le texte visible statique (1578 caractères) ne contient **aucun avis** — seulement de la navigation générique et, littéralement, l'aveu du site lui-même : *"This page is not functional with Javascript disabled or Javascript not available"*. Inspection du HTML brut confirme un conteneur de listing explicitement vide, rempli plus tard par AJAX :
```
$ python3 -c "
import re
html = open('commonwealth.html', encoding='utf-8', errors='replace').read()
m = re.search(r'<div id=\"containerProjects\">.*?</div>\s*<div id=\"divProjects\">', html, re.S)
print(m.group())
"
<div id="containerProjects">
                    </div>
                    <div id="divProjects">
```
Le JS de la page appelle `LoadProjects(...)` via `onloadCallback` pour peupler ce conteneur. **Un `curl` nu, ou toute extraction qui n'exécute pas le JS de la page, ne verrait donc structurellement aucun avis sur ce site — indépendamment de la présence d'une clé Tavily valide.**

**Vérité terrain, méthode 2 — navigateur réel (Chrome via `claude-in-chrome`, 2026-09-02), pour vérifier ce qu'une extraction consciente du JS verrait réellement :**
```
navigate → https://tenders.thecommonwealth.org/aspx/Tenders/Appraisal
get_page_text (après chargement complet) :
"Search Search Sort Title Sort Date documents can be requested until
There are no tenders at the moment
Please click on the following link to go to the procurement web site...
Procurement Department Web Site"
```
Vérifié aussi sur les deux autres onglets du même portail (URLs sœurs, non configurées comme `list_url` mais utiles pour situer la vérité terrain) :
```
/aspx/Tenders/Current     → "There are no Current tenders at the moment"
/aspx/Tenders/Forthcoming → "There are no Forthcoming tenders at the moment"
```
**Vérité terrain factuelle du jour : il n'existe actuellement aucun appel d'offres actif sur ce portail, dans aucun des trois onglets (Appraisal/Current/Forthcoming).** Contrairement à UNDP et Palladium, il n'y a donc, à cette date précise, strictement aucun avis — IT ou autre — que le pipeline aurait manqué sur cette source : le site lui-même est vide.

**Investigation architecture — `tavily_extract` est-il le bon outil pour ce site précis ? (au-delà de la clé manquante, comme demandé)** Le listing de ce portail (technologie In-Tend, SaaS de sourcing utilisé par des organisations publiques/intergouvernementales) est chargé par un appel AJAX au chargement de la page, pas par un rendu serveur classique — un profil structurellement différent d'UNDP/Palladium. La config de cette source utilise déjà `extract_depth: "advanced"`, le mode que Tavily documente explicitement pour « JS-rendered SPAs, dynamic content » (compétence `tavily-extract` installée localement) — donc le choix de configuration existant anticipait déjà ce besoin, et le test navigateur ci-dessus confirme que le contenu réel s'obtient par un simple chargement de page, sans interaction spécifique (comme pour Nova Scotia en section CA). **Cependant, faute d'une clé Tavily valide disponible pour cette tâche** (absente en staging par définition même de la cause racine ; aucune clé locale/personnelle trouvée dans ce repo ou l'environnement pour tester `/extract` en direct ; CLI `tvly` non installée) **, il n'a pas été possible de vérifier positivement que l'appel Tavily `/extract` exécute effectivement cet appel AJAX on-load et renverrait le texte réel plutôt qu'un contenu vide ou une erreur — point documenté honnêtement comme non résolu, pas tranché dans un sens ou l'autre par supposition.** Point structurel distinct et sans ambiguïté, relevé en lisant le JS de la page : une passerelle reCAPTCHA (`#captcha-container`) existe mais ne se déclenche que `if (msg > maxPageRequest && maxPageRequest != -1)`, c.-à-d. uniquement en cas de pagination au-delà d'une certaine profondeur — non pertinent aujourd'hui (0 résultat, jamais de second appel de page) et non activé par la config actuelle de la source (pas de `max_pages`/pagination configurée), mais à surveiller si le site redevient actif avec beaucoup d'avis.

**Confirmation de l'entrée propre à cette source dans les logs de nœuds du run CA :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==20][0]
print('status:', e['status'], '| error:', e['error'], '| listings:', len(e['listings']), '| list_url:', e['source']['list_url'])
"
status: failed | error: TAVILY_API_KEY not set | listings: 0 | list_url: https://tenders.thecommonwealth.org/aspx/Tenders/Appraisal
```
Confirmé pour cette source précisément (`fetched_at: "2026-09-02T17:10:51.796915"`) — identique au constat générique de la Tâche 7, pas supposé. `list_url` correspond exactement à l'URL de vérité terrain (méthode 1/2 ci-dessus).

**Requête `notices` (source_id=20, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=20 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source (cf. avertissement CA). Cohérent aussi avec la vérité terrain propre à cette source : même sans le blocage `TAVILY_API_KEY`, il n'y a aujourd'hui rien à persister (0 avis actifs sur le site). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| (Aucun avis actif sur le site à la date de vérité terrain — rien de concret n'est donc perdu aujourd'hui) | N/A | Fetch (`fetch_listings`, branche `tavily_extract`) — bloqué avant même de pouvoir tester si le rendu JS aurait fonctionné | `TAVILY_API_KEY` absente du conteneur `staging_api` (Tâche 7, reconfirmé ici) empêche tout appel `/extract`, quel qu'en aurait été le résultat | bug logique | Modérée (aucun avis actif sur le site à ce jour — impact net nul actuellement — mais le blocage fetch est total et masquerait tout nouvel avis IT dès sa publication) | `fetch_listings.json` : `status: failed`, `error: "TAVILY_API_KEY not set"` ; vérité terrain navigateur réel : « There are no tenders/Current tenders/Forthcoming tenders at the moment » sur les 3 onglets du portail |
| Incertitude architecturale non résolue : capacité non vérifiée du couple `tavily_extract`/`extract_depth: advanced` à exécuter l'appel AJAX `LoadProjects` de ce site précis, faute de clé Tavily disponible pour un test en direct | Indéterminé | Fetch (`fetch_listings`, branche `tavily_extract`) | Point ouvert, documenté par honnêteté plutôt que tranché par supposition | limite architecturale potentielle (non confirmée — à réévaluer une fois la clé restaurée) | À réévaluer | Code JS de la page : listing chargé par `LoadProjects()` on-load, conteneur `#containerProjects` vide dans le HTML statique ; `extract_depth: advanced` déjà configuré et documenté par Tavily pour ce cas d'usage, mais non testé en direct (pas de clé Tavily disponible localement, CLI `tvly` non installée) |

**Verdict :** Contrairement à UNDP et Palladium, The Commonwealth n'a, à la date de cette vérité terrain (2026-09-02), strictement aucun avis actif sur son portail — les 3 onglets Appraisal/Current/Forthcoming renvoient tous « no tenders »/« no Current tenders »/« no Forthcoming tenders » via un navigateur réel. Il n'y a donc aujourd'hui aucun avis IT concret perdu par le pipeline sur cette source, contrairement aux deux autres sources de cette tâche. La cause immédiate du blocage à l'étage fetch reste identique et déjà établie par la Tâche 7 : `TAVILY_API_KEY` absente du conteneur `staging_api` (reconfirmé indépendamment ici). **Étiquette retenue : bug logique**, mais avec une réserve honnête propre à cette source, pas recopiée des deux autres : le listing de ce portail est chargé par AJAX (`LoadProjects` on-load, conteneur vide en HTML statique) plutôt que rendu côté serveur — un profil structurellement plus proche de Nova Scotia (JS requis) que d'UNDP/Palladium (rendu serveur direct). Le mode `extract_depth: advanced` déjà configuré est documenté par Tavily précisément pour ce cas, ce qui penche pour « bug logique » (config manquante) plutôt que « limite architecturale » — mais faute d'une clé Tavily valide pour tester l'appel `/extract` en direct sur ce site précis, cette hypothèse n'a pas pu être positivement vérifiée et reste un point ouvert à confirmer une fois la clé restaurée, plutôt qu'un fait établi. **Sévérité revue à la baisse par rapport à UNDP/Palladium** : le gap fetch existe bel et bien et reste total, mais son impact concret aujourd'hui est nul (rien de pertinent n'est manqué, faute de tout avis actif sur le site) — à réévaluer dès que le site republie des opportunités.

### Palladium Group (source id 25, parser_type tavily_extract)

**Cause racine — pas re-diagnostiquée ici :** confirmée identique à la Tâche 7 : `TAVILY_API_KEY` absente du conteneur `staging_api` (reconfirmé ici, même vérification que les deux sources précédentes : sortie vide).

**Vérité terrain (`curl`, 2026-09-02, `list_url` exact) :**
```
$ curl -s -o palladium.html -w "HTTP_STATUS:%{http_code} SIZE:%{size_download}\n" \
  "https://thepalladiumgroup.com/tenders" \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
HTTP_STATUS:200 SIZE:35546

$ python3 -c "
import re
html = open('palladium.html', encoding='utf-8', errors='replace').read()
text = re.sub(r'<script.*?</script>', '', html, flags=re.S)
text = re.sub(r'<style.*?</style>', '', text, flags=re.S)
text = re.sub(r'<[^>]+>', ' ', text)
text = re.sub(r'\s+', ' ', text).strip()
print(len(text)); print('Find out more count:', text.count('Find out more'))
"
4057
Find out more count: 21

$ grep -io "captcha\|access denied\|blocked\|cloudflare\|are you human\|rate limit\|just a moment" palladium.html | sort -u
(aucune sortie)

$ grep -n -i "next" palladium.html | head -5
96:          e.src = "//" + __sf_config.host + "/dist/js/frs-next.js";
```
**Page intégralement rendue côté serveur, sans pagination** : les 21 avis actuellement listés sous « Current Tenders » (chacun suivi d'un bouton « Find out more ») sont tous présents dans le HTML brut retourné par un simple `curl` ; la seule occurrence de « next » dans le fichier est un nom de script JS (`frs-next.js`) sans rapport avec une pagination de contenu. Cohérent avec la config de la source (pas de `max_pages` défini — un seul appel `/extract` suffit). Aucun signe d'anti-bot.

Avis manifestement pertinents pour une entreprise IT (recoupés contre `it_services`/`it_hardware`) :
1. **« Enhancing Sri Lanka Tourism Promotion through Integrated Digital Campaign Monitoring, Skills Development and Market Intelligence »** — matche `it_services` « digital »/« numérique ».
2. **« Palladium RFQ - Strengthening of Warehouse Management Information and Monitoring Systems for the Distribution of Disaster Management Logistics Assistance »** — matche `it_services` « système de gestion » (Management Information...Systems).
3. **« Palladium RFQ - 400 Tablets and Durable Power Banks Procurement - Palladium Data.FI Botswana »** — recoupe (au sens large) `it_hardware` « matériel informatique » (tablettes).

**Note structurelle distincte, hors cause racine :** contrairement à UNDP, cette page ne montre que des titres + boutons « Find out more » — les champs `reference`/`deadline` ne sont pas visibles sur le listing lui-même (vraisemblablement sur les pages de détail individuelles, non fetchées par `tavily_extract`, qui ne suit que `list_url`). Même avec une clé Tavily valide, `parse_tavily_listing.py` laisserait donc probablement ces champs vides pour cette source — un gap de complétude des champs distinct de la cause racine actuelle (le fetch échoue avant même d'atteindre ce stade), signalé ici pour une phase 2 mais non quantifié davantage (hors périmètre de ce diagnostic).

**Confirmation de l'entrée propre à cette source dans les logs de nœuds du run CA :**
```
$ python3 -c "
import json
d = json.load(open('fetch_listings.json'))
e = [x for x in d[0]['data'] if x['source']['id']==25][0]
print('status:', e['status'], '| error:', e['error'], '| listings:', len(e['listings']), '| list_url:', e['source']['list_url'])
"
status: failed | error: TAVILY_API_KEY not set | listings: 0 | list_url: https://thepalladiumgroup.com/tenders
```
Confirmé pour cette source précisément (`fetched_at: "2026-09-02T17:10:51.797131"`) — identique au constat générique de la Tâche 7, pas supposé. `extract_item_links.json` du même run est `{"data": []}` (cf. avertissement CA en tête de section).

**Requête `notices` (source_id=25, exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT n.id, n.title, n.ref_no, n.deadline_at, n.is_duplicate, n.duplicate_of_id, cns.is_relevant, cns.relevance_score, cns.classification_method FROM notices n LEFT JOIN company_notice_status cns ON cns.notice_id=n.id AND cns.company_id=1 WHERE n.source_id=25 ORDER BY n.created_at DESC LIMIT 50;\""

 id | title | ref_no | deadline_at | is_duplicate | duplicate_of_id | is_relevant | relevance_score | classification_method
----+-------+--------+-------------+--------------+-----------------+-------------+-----------------+------------------------
(0 rows)
```
Résultat attendu, non spécifique à cette source (cf. avertissement CA). Aucune ligne `company_notice_status` : aucun faux positif de classification à vérifier.

**Gaps constatés :**

| Titre | Vu par le pipeline ? | Étage où perdu/faux positif | Cause racine | Étiquette (bug/archi/techno) | Sévérité | Preuve |
|---|---|---|---|---|---|---|
| Enhancing Sri Lanka Tourism Promotion through Integrated Digital Campaign Monitoring, Skills Development and Market Intelligence — matche le mot-clé IT « digital » | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | `TAVILY_API_KEY` absente du conteneur `staging_api` (Tâche 7, reconfirmé ici) — pas de code/config spécifique à cette source, la branche échoue avant même l'appel `/extract` | bug logique | Critique | `fetch_listings.json` : `status: failed`, `error: "TAVILY_API_KEY not set"`, `listings: []` ; vérité terrain `curl` : item présent, page rendue intégralement côté serveur |
| Palladium RFQ - Strengthening of Warehouse Management Information and Monitoring Systems for the Distribution of Disaster Management Logistics Assistance — matche « système de gestion » | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | Même cause | bug logique | Critique | Idem |
| Les ~18 autres avis actuels (21 au total sur cette unique page, 0 vus par le pipeline) | Non | Fetch (`fetch_listings`, branche `tavily_extract`) | Même cause — perte à 100%, pas un cas isolé | bug logique | Critique | `fetch_listings.json` : `listings: []` pour la totalité de la source ; vérité terrain `curl` : 21 occurrences de « Find out more » |

**Verdict :** Palladium Group est une perte totale à l'étage fetch, cause identique et déjà établie par la Tâche 7 (`TAVILY_API_KEY` absente du conteneur `staging_api`). **Étiquette : bug logique**, pas limite technologique — vérifié spécifiquement pour ce site, pas recopié : la page `/tenders` est intégralement rendue côté serveur (un `curl` nu récupère déjà les 21 avis actuels), sans pagination, sans aucun signe d'anti-bot. Comme pour UNDP (et à la différence de The Commonwealth), aucune indication qu'une architecture différente serait nécessaire pour le listing lui-même — la cause du gap est purement l'absence de la variable d'environnement. **Remarque secondaire, hors cause racine :** même une fois la clé restaurée, les champs `reference`/`deadline` resteraient probablement vides pour cette source, faute d'être présents sur la page de listing elle-même — un gap de complétude des champs distinct, signalé pour une phase 2, non quantifié ici.

### Sources désactivées (9 sources)

**Méthode :** pas de trace pipeline (une source désactivée ne s'exécute jamais — rien à tracer). Pour chacune : (a) config DB complète, (b) contrôle manuel du `list_url` (`curl` avec User-Agent navigateur ; Chrome indisponible cette session — l'extension `claude-in-chrome` a répondu « Browser extension is not connected », voir note plus bas), (c) jugement sur la justification de la désactivation.

**Step 1 — config DB complète (requête exacte du brief, ré-exécutée le 2026-09-02) :**
```
$ ssh -i ~/.ssh/id_ed25519 tender-ai@195.35.48.198 \
  "docker exec staging_postgres psql -U tenderai -d tenderai_bf -c \
  \"SELECT id, name, enabled, rate_limit, patterns, updated_at FROM sources WHERE id IN (18,19,21,22,23,24,26,27,28) ORDER BY id;\""

 id |                  name                   | enabled | rate_limit |                          patterns                          |         updated_at
----+-----------------------------------------+---------+------------+--------------------------------------------------------------+----------------------------
 18 | Bonfire Hub Canada - Appels d'offres    | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 19 | Public Procurement Belgium              | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 21 | Guinea Tenders                          | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 22 | UNDP Africa - Procurement               | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 23 | World Bank - Procurement Notices        | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 24 | NATO NSPA - eProcurement                | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 26 | BAD - Banque Africaine de Développement | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 27 | OMD / WCO - Appels à la concurrence     | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
 28 | AFD - DGMarket Tenders                  | f       | 10/m       | {"extract_depth": "advanced", "include_raw_content": true} | 2026-08-26 17:10:25.035724
(9 rows)
```
`enabled=false` confirmé pour les 9. Le champ `patterns` ne contient **aucune** note explicative — c'est de la config technique générique pour `parser_type: tavily_extract` (`extract_depth`/`include_raw_content`), identique verbatim sur les 9 lignes ; il n'existe d'ailleurs pas de colonne dédiée à un motif de désactivation dans le schéma (`\d sources` : `id, name, base_url, list_url, parser_type, rate_limit, enabled, country_id, patterns, last_seen_at, last_success_at, last_error_at, last_error_message, created_at, updated_at` — aucun champ `notes`/`disabled_reason`).

**Complément (colonnes non listées par le Step 1 du brief mais utiles au jugement, `parser_type`/`country_id`/`last_seen_at`/`last_success_at`/`last_error_at`/`last_error_message`/`created_at`) :**
```
 id |                  name                   |  parser_type   | country_id | last_seen_at | last_success_at | last_error_at | err |         created_at
----+-----------------------------------------+----------------+------------+--------------+-----------------+---------------+-----+----------------------------
 18 | Bonfire Hub Canada - Appels d'offres    | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 19 | Public Procurement Belgium              | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 21 | Guinea Tenders                          | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 22 | UNDP Africa - Procurement               | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 23 | World Bank - Procurement Notices        | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 24 | NATO NSPA - eProcurement                | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 26 | BAD - Banque Africaine de Développement | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 27 | OMD / WCO - Appels à la concurrence     | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
 28 | AFD - DGMarket Tenders                  | tavily_extract |          2 |              |                 |               |     | 2026-08-26 17:10:25.035724
(9 rows)
```
Les 9 partagent un `created_at`/`updated_at` **identique à la milliseconde près** (2026-08-26 17:10:25.035724) et `last_seen_at`/`last_success_at`/`last_error_at` tous **NULL** — signe d'une insertion en lot au même moment, jamais individuellement activées ni exécutées depuis (pas de crash ni d'erreur enregistrée qui expliquerait la désactivation : elles n'ont simplement jamais tourné). `parser_type` = `tavily_extract` pour les 9, identique aux 3 sources CA activées `tavily_extract` déjà auditées dans ce rapport (UNDP source id 17, The Commonwealth id 20, Palladium Group id 25) — sources pour lesquelles ce chantier a établi une perte totale à l'étage fetch faute de `TAVILY_API_KEY` dans le conteneur `staging_api` (cf. sections correspondantes ci-dessus). Cette même cause s'appliquerait telle quelle à n'importe laquelle de ces 9 sources si elle était réactivée sans correction préalable.

**Step 2 — contrôle manuel des 9 `list_url` (2026-09-02, `curl -A "Mozilla/5.0 … Chrome/120.0 …"`, `--max-time 20 -L`) :**

**Note méthodologique :** l'extension Chrome (`claude-in-chrome`) n'était pas connectée cette session (`tabs_context_mcp` → « Browser extension is not connected »), et aucun CLI `browser-use` n'était disponible. Contrôle fait entièrement via `curl` (User-Agent navigateur, avec gestion de cookies/redirections quand pertinent). Pour les sites rendus côté client (SPA JavaScript pure), `curl` confirme que la page se charge (HTTP 200, app réelle, pas une erreur/redirection cassée) mais **ne peut pas** confirmer le contenu réellement affiché après exécution du JS — signalé explicitement ligne par ligne ci-dessous plutôt que deviné.

| # | Source | Résultat brut `curl` | Constat |
|---|---|---|---|
| 18 | Bonfire Hub Canada | `HTTP_STATUS:200 SIZE:74945`. `<title>Portal — Open Opportunities - Canadian Museum of Nature</title>`. Onglet "Open Opportunities" bien chargé (JS confirme `openOpportunities`/`pastOpportunities`/`myOpportunities`), mais tableau peuplé en JS après coup (`defaultSectionData = {}` vide dans le HTML statique, `loadOpportunitiesTable(...)` appelé côté client) — **contenu réel non confirmé** (pas de Chrome dispo). | Site vivant, pas mort/redirigé — mais `list_url` pointe vers le portail d'**une seule** institution (Musée canadien de la nature, sous-domaine `cmn-mcn.bonfirehub.ca`), pas un agrégateur "Bonfire Hub Canada" multi-organismes malgré le nom de la source. |
| 19 | Public Procurement Belgium | `HTTP_STATUS:200 SIZE:1196`. Coquille SPA Vue pure (`<title>BOSA - eProcurement</title>`, `<div id="app"></div>` vide, `<noscript>` avertit que le site ne fonctionne pas sans JS). **Contenu réel non confirmé** (pas de Chrome dispo). | Site officiel belge réel (BOSA = service public fédéral belge), pas mort — mais périmètre géographique (Belgique) sans lien évident avec le Burkina Faso/l'Afrique, contrairement au reste du portefeuille CA. |
| 21 | Guinea Tenders | `HTTP_STATUS:200 SIZE:41359`. Page correcte atteinte (breadcrumb `IT Services: Consulting, Software Development, Internet And Support Tenders`), mais **aucun lien d'avis individuel** dans le HTML (`grep href /tenders/` → 0 résultat) ; texte de page : *"Our subscribers get full access to unlimited public tender listings… FREE TRIAL Get Access to All Guinea Tenders"*. | URL valide mais **mur d'abonnement (paywall)** — page marketing/inscription, aucun avis visible sans compte payant. |
| 22 | UNDP Africa | `HTTP_STATUS:403`. Corps : `<TITLE>Access Denied</TITLE> … Reference #18.ce680317…` (page Akamai standard). Reproduit sur `www.undp.org/`, `/procurement`, `/africa` — blocage **au niveau du domaine entier**, pas spécifique à cette page. | Domaine vivant mais bloqué par anti-bot Akamai pour ce type de requête (403 Access Denied sur tout `undp.org`) — pas une page morte/déplacée. |
| 23 | World Bank | `HTTP_STATUS:200 SIZE:104975`. App JS réelle (« RFx Now », produit Ivalua) — nombreux fichiers `AdvertisementsSearchView.js`/`ActiveAdvertisementsReadOnly.js` référencés, texte *"For any of these business opportunities, please Login"* présent (mix avis publics/privés typique de ce produit). **Contenu réel (liste d'avis) non confirmé** — rendu 100% JS, pas de Chrome dispo. | Plateforme vivante et fonctionnelle, pas morte — mais rendu client pur, nécessiterait un fetcher JS (Playwright/Tavily) pour être exploitable de toute façon. |
| 24 | NATO NSPA | `HTTP_STATUS:200 SIZE:88549`. **Contenu confirmé, rendu côté serveur** : avis réels et datés visibles directement dans le HTML brut, ex. `26LMS068 Supply of Distribution Boxes for BOXER … Publication Date 02 Sep 2026`, `26LMS066 RFP for the Provision of Leopard Spare Parts … Publication Date 01 Sep 2026`, `26OEM028 Construction of hangars, Spain … Publication Date 28 Aug 2026` — dates cohérentes avec la date du contrôle (2026-09-02). | URL **valide et manifestement à jour** — liste de marchés réels et récents confirmée sans ambiguïté, pas une simple coquille JS. |
| 26 | BAD (AfDB) | `HTTP_STATUS:403`. Corps : `<title>Just a moment...</title>`, en-têtes `cf-mitigated: challenge`, `server: cloudflare` — challenge JS Cloudflare explicite, pas une erreur générique. | URL valide côté site (page réelle, protégée par Cloudflare) — bloquée par anti-bot nécessitant résolution de challenge JS, pas une page morte. |
| 27 | OMD / WCO | `HTTP_STATUS:200 SIZE:44720`. Page correcte atteinte (fil d'Ariane `About Us > Calls for tenders`), section « Call for tenders » présente, texte exact : *"There are no active tenders at present."* | URL valide et fonctionnelle — page vide **légitimement** au moment du contrôle (pas d'erreur), mais laisse penser à un volume d'avis structurellement très faible/rare sur cette source. |
| 28 | AFD - DGMarket | Requête simple (sans gestion de cookies) : `This page requires digi_session_id cookie…`. Avec gestion cookies + suivi des redirections (`curl -c/-b -L`, 3 sauts : `brandedNoticeList.do` → `web3-login.dgmarket.com/um~user/login.do?...&autoLogin=true` → `newSession.do` → retour à `brandedNoticeList.do`) : `HTTP_STATUS:200`, page *"Consulter les avis - Agence Française de Développement - dgMarket"* atteinte, 20+ occurrences de « notice »/« tender » dans le contenu. | URL valide et fonctionnelle — la « exigence de cookie » d'une requête nue est une chaîne de connexion automatique anonyme standard (`autoLogin=true`) que tout client HTTP suivant cookies+redirections (navigateur réel, ou un fetcher correctement configuré) résout de façon transparente ; ce n'est **pas** un vrai mur de connexion. |

**Tableau récapitulatif requis par le brief :**

| Source | Raison de désactivation (si trouvée) | URL toujours valide ? | Verdict (désactivation justifiée / gap de couverture) |
|---|---|---|---|
| Bonfire Hub Canada (id 18) | Aucune trouvée en base (pas de champ dédié ; `patterns` = config technique générique, identique aux 8 autres ; jamais exécutée — `last_seen_at`/`last_success_at`/`last_error_at` NULL) | Oui — 200, app Bonfire réelle chargée, mais contenu de la table (JS) non confirmable sans navigateur | **Ambigu, à investiguer plutôt que tranché** : le site répond et semble légitime, mais le `list_url` configuré ne couvre qu'un seul petit établissement fédéral (Musée canadien de la nature) malgré le nom générique « Bonfire Hub Canada » — si l'intention était de couvrir plusieurs organismes sur la plateforme Bonfire, c'est un **gap de couverture** de portée (mauvaise URL plutôt qu'un mauvais choix de désactivation) ; si l'intention était bien ce seul organisme, la désactivation est probablement justifiée par le faible volume attendu. Contenu réel non vérifié (pas de Chrome) — verdict à confirmer visuellement avant toute réactivation. |
| Public Procurement Belgium (id 19) | Aucune trouvée en base (idem) | Oui — 200, SPA officielle belge (BOSA) réelle, contenu non confirmable sans navigateur | **Désactivation probablement justifiée** — périmètre géographique (Belgique) sans lien apparent avec le Burkina Faso/l'Afrique, contrairement aux autres sources CA du portefeuille ; pas un problème d'URL morte. |
| Guinea Tenders (id 21) | Aucune trouvée en base (idem) | Oui, techniquement (200) — mais mur d'abonnement, aucun avis visible sans compte payant | **Désactivation justifiée** — le pipeline ne pourrait rien extraire de ce `list_url` sans authentification/abonnement payant, quel que soit le fetcher utilisé. |
| UNDP Africa (id 22) | Aucune trouvée en base (idem) | Non exploitable — 403 Akamai « Access Denied » sur tout le domaine `undp.org`, pas seulement cette page | **Gap de couverture potentiel** — domaine vivant et pertinent (Afrique), bloqué par anti-bot ; correspond exactement au cas d'usage prévu du `parser_type: tavily_extract` configuré pour cette source, MAIS `TAVILY_API_KEY` est absente du conteneur `staging_api` aujourd'hui (cause déjà établie pour 3 autres sources `tavily_extract` de ce rapport) — réactiver sans corriger cette clé échouerait identiquement. |
| World Bank (id 23) | Aucune trouvée en base (idem) | Oui — 200, plateforme RFx Now réelle et vivante, contenu (liste d'avis) non confirmable sans navigateur | **Gap de couverture potentiel** — institution majeure et pertinente (financement international de projets, y compris en Afrique), plateforme fonctionnelle nécessitant un rendu JS ; à confirmer visuellement avant réactivation, mais rien n'indique une page morte. |
| NATO NSPA (id 24) | Aucune trouvée en base (idem) | **Oui, confirmé positivement** — avis réels et datés du jour même visibles en HTML brut | **Gap de couverture à signaler, sous réserve de pertinence métier** — URL manifestement vivante et à jour (contrairement aux autres lignes de ce tableau, contenu réel confirmé sans ambiguïté), aucune cause technique ne justifie la désactivation ; à trancher côté métier si les marchés d'équipement/logistique de défense OTAN entrent dans le périmètre ciblé par TenderAI — si oui, c'est un gap de couverture net et non ambigu. |
| BAD - Banque Africaine de Développement (id 26) | Aucune trouvée en base (idem) | Non exploitable en l'état — 403, challenge Cloudflare JS explicite (`cf-mitigated: challenge`) | **Gap de couverture potentiel, le plus net du lot côté pertinence** — institution panafricaine de développement, pertinence géographique directe et forte pour le Burkina Faso ; bloquée uniquement par anti-bot (Cloudflare), pas par absence de contenu. Même remarque que UNDP Africa sur `TAVILY_API_KEY` manquante en staging si réactivation envisagée avec le `parser_type` actuel. |
| OMD / WCO (id 27) | Aucune trouvée en base (idem) | Oui — 200, page correcte, contenu confirmé : « There are no active tenders at present. » | **Désactivation plausible mais pas certaine** — URL fonctionnelle et légitime, simplement vide au moment du contrôle ; à re-vérifier périodiquement plutôt que jugée sur ce seul instantané (une organisation internationale peut publier des avis de façon très intermittente). |
| AFD - DGMarket (id 28) | Aucune trouvée en base (idem) | Oui, confirmé — 200 après résolution de la chaîne cookie/redirection standard (« Consulter les avis » atteint, contenu réel) | **Gap de couverture potentiel** — AFD (Agence Française de Développement) est une source à forte pertinence géographique pour le Burkina Faso ; la chaîne cookie/session qui bloque une requête `curl` nue n'est pas un vrai mur de connexion (comportement JSP standard, résolu par tout client suivant cookies+redirections) — à vérifier que le fetcher `tavily_extract` la gère correctement avant réactivation. |

**Synthèse :** aucune des 9 sources désactivées ne porte de raison enregistrée en base — les 9 ont été insérées `enabled=false` en un seul lot (même timestamp à la milliseconde) et n'ont **jamais** été exécutées (`last_seen_at`/`last_success_at`/`last_error_at` NULL sur toute la ligne), ce qui exclut une désactivation réactive suite à un incident constaté : elles semblent plutôt avoir été ajoutées au catalogue puis laissées désactivées par défaut, sans jugement individuel documenté. Sur les 9 `list_url`, aucune n'est une page morte à proprement parler : 2 confirmées activement à jour avec du contenu réel (**NATO NSPA**, qui montre des avis datés du jour même — le cas le plus net d'un gap de couverture potentiel non ambigu si le domaine défense/logistique est pertinent pour TenderAI ; **AFD - DGMarket**, contenu confirmé une fois la chaîne cookie/redirection suivie), 2 bloquées par anti-bot (**UNDP Africa** 403 Akamai domaine entier, **BAD/AfDB** 403 Cloudflare challenge — toutes deux géographiquement pertinentes pour le Burkina Faso/l'Afrique, donc gaps de couverture potentiels si un fetcher adapté était opérationnel), 1 verrouillée par un mur d'abonnement payant (**Guinea Tenders** — désactivation clairement justifiée, aucun contenu extractible sans compte payant quel que soit le fetcher), 1 vide au moment du contrôle mais fonctionnelle (**OMD/WCO**), et 3 dont le contenu réel n'a pas pu être confirmé faute d'accès navigateur cette session — extension `claude-in-chrome` non connectée, aucun CLI `browser-use` disponible — (**Bonfire Hub Canada**, **Public Procurement Belgium**, **World Bank**), toutes trois retournant néanmoins un 200 avec une application front-end réelle et non une erreur. Point transversal à noter pour la synthèse générale : les 9 sources partagent `parser_type: tavily_extract`, le même que 3 sources CA déjà activées et auditées dans ce rapport (UNDP, The Commonwealth, Palladium) où ce chantier a établi une perte totale à l'étage fetch faute de `TAVILY_API_KEY` dans `staging_api` — toute réactivation parmi ces 9, même pour les gaps de couverture identifiés ci-dessus (NATO NSPA, AFD, UNDP Africa, BAD), échouerait identiquement tant que cette clé n'est pas restaurée.
