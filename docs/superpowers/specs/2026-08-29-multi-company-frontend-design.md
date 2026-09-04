# Multi-Company Frontend (chantier 5, sous-projet B) — Design Spec

**Date :** 2026-08-29
**Statut :** Approuvé (en attente de revue finale de la spec)
**Réfs :** Section 4 ("Frontend") de `docs/superpowers/specs/2026-08-23-multi-company-design.md` (spec d'origine, jamais implémentée) ; `docs/superpowers/plans/2026-08-29-multi-company-auth-api.md` (sous-projet A, backend, déjà mergé sur `tenderai-backend/staging`).

---

## Contexte

Le sous-projet A (backend Auth & API) est terminé et mergé : le JWT porte désormais un claim `company_id`, les rôles `User` ont été renommés `admin`→`company_admin`, `viewer`→`company_viewer` (`super_admin` inchangé), et un nouveau routeur `companies.py` expose la gestion complète des entreprises (CRUD, abonnements pays, paramètres, déclenchement de livraison).

Le frontend (`tenderai-frontend`, repo local `/home/yulcom/web/tenderai/tenderai-frontend`) n'a **jamais** été mis à jour pour ce modèle — il utilise encore partout les littéraux de rôle `"admin"`/`"viewer"` et n'a aucune notion de `company_id`. Concrètement, deux problèmes distincts :

1. **Rupture de compatibilité imminente** : une fois le nouveau backend redéployé sur staging, la boîte de dialogue "Nouvel utilisateur" (`components/users/create-user-dialog.tsx`) soumettra `role: "admin"` ou `role: "viewer"` — des valeurs que le backend rejette désormais (400, `VALID_ROLES` ne contient plus que `super_admin`/`company_admin`/`company_viewer`). Il devient impossible de créer un utilisateur `company_admin`/`company_viewer` depuis l'UI.
2. **Fonctionnalité manquante** : aucune UI n'existe pour créer/gérer des entreprises (`Company`), les abonner à des pays, configurer leurs paramètres par entreprise, ou filtrer les données par entreprise sélectionnée — bien que le backend supporte tout cela depuis le sous-projet A.

**Décision de séquencement** (confirmée avec l'utilisateur) : le backend et ce travail frontend seront déployés **ensemble** sur staging, une fois ce plan entièrement implémenté et revu — pas de déploiement backend seul, pour éviter une fenêtre où l'UI en production échoue contre un backend qui rejette les anciennes valeurs de rôle.

**Absence d'infrastructure de test** : `tenderai-frontend/package.json` ne définit que `dev`/`build`/`start`/`lint` — aucun test runner, aucun fichier de test dans le repo. La vérification de ce plan se fait donc via `next build` (erreurs TypeScript), `next lint`, et une revue manuelle dans le navigateur sous les 3 rôles (`super_admin`, `company_admin`, `company_viewer`) — même méthode déjà utilisée cette session pour la tâche 12 et le renommage `tenderai-bf`.

---

## Section 1 — Renommage des littéraux de rôle (correctif de compatibilité)

Remplacer `"admin"` → `"company_admin"` et `"viewer"` → `"company_viewer"` partout où ces littéraux apparaissent, avec les changements suivants recensés (recherche exhaustive `grep -rn '"admin"\|"viewer"'` effectuée pendant le brainstorming — liste fermée, ne pas chercher au-delà) :

| Fichier | Changement |
|---|---|
| `lib/api.ts:32,40` | Type `role: "admin" \| "viewer"` → `role: "company_admin" \| "company_viewer"` (dans les types partagés du client API — probablement une union `"super_admin" \| "admin" \| "viewer"` complète à corriger en `"super_admin" \| "company_admin" \| "company_viewer"`) |
| `contexts/country-context.tsx:28` | Valeur de repli par défaut du contexte `role: "viewer"` → `role: "company_viewer"` ; type de la prop `role` du provider (actuellement `"super_admin" \| "admin" \| "viewer"`) → `"super_admin" \| "company_admin" \| "company_viewer"` |
| `components/sidebar.tsx` (prop `role`) | Type `"super_admin" \| "admin" \| "viewer"` → `"super_admin" \| "company_admin" \| "company_viewer"` (la logique `role === "super_admin"` déjà présente reste inchangée — seul le type change) |
| `app/(dashboard)/layout.tsx` | Type du payload JWT décodé (`role: "super_admin" \| "admin" \| "viewer"`) → `"super_admin" \| "company_admin" \| "company_viewer"` |
| `components/users/create-user-dialog.tsx:70,120-121` | `setRole("viewer")` → `setRole("company_viewer")` ; options `<option value="viewer">Viewer</option>` / `<option value="admin">Admin</option>` → `<option value="company_viewer">Company Viewer</option>` / `<option value="company_admin">Company Admin</option>` |
| `app/(dashboard)/users/page.tsx:13,108-109` | Type `role: "super_admin" \| "admin" \| "viewer"` → nouveau triplet ; logique d'affichage du badge (`user.role === "admin" ? "secondary" : "outline"`) → comparer à `"company_admin"` |

Cette section est un pré-requis structurel pour tout le reste (Sections 2-4 introduisent du nouveau code qui utilise directement les nouveaux littéraux — pas de sens à écrire du nouveau code contre les anciens noms).

---

## Section 2 — `CompanyContext`

Nouveau fichier `contexts/company-context.tsx`, construit sur le modèle exact de `contexts/country-context.tsx` (même structure : `createContext`, provider avec `useState`/`useEffect`, hook `useCompany`).

```typescript
export type Company = {
  id: number;
  name: string;
  slug: string;
  active: boolean;
  logo_url: string | null;
  subject_prefix: string | null;
  signature: string | null;
};

type CompanyContextValue = {
  companies: Company[];
  selectedCompany: Company | null;
  setSelectedCompany: (c: Company) => void;
  loading: boolean;
  isSuperAdmin: boolean;
};
```

- **super_admin** : `fixedCompanyId` est `null` — `CompanyProvider` fetch `GET /api/proxy/companies` (toutes les entreprises), restaure la sélection depuis `localStorage["selectedCompanyId"]` ou prend la première, comme `CountryProvider` le fait aujourd'hui pour `selectedCountryId`.
- **company_admin / company_viewer** : `fixedCompanyId` vient du claim JWT `company_id` — sélection verrouillée sur cette seule entreprise (fetch limité à `GET /api/proxy/companies/{id}` plutôt que la liste complète, ou filtrage côté client après fetch de la liste complète si l'endpoint liste reste plus simple à réutiliser — **décision d'implémentation à trancher pendant l'exécution du plan, pas ici** : les deux approches sont fonctionnellement équivalentes puisque `require_company_scope` bloquera de toute façon l'accès à une autre entreprise côté backend).
- **Repli en échec** : si le `company_id` du JWT ne correspond à aucune entreprise renvoyée par l'API (entreprise supprimée entre-temps, désynchronisation), `selectedCompany` reste `null` — jamais de repli silencieux vers une autre entreprise. Le composant consommateur doit gérer cet état `null` (afficher un message plutôt que planter).

### `app/(dashboard)/layout.tsx`

Extrait `company_id` du JWT décodé de la même manière que `country_id` l'est déjà (le layout décode le JWT directement via `jwtVerify` — **pas** d'appel à `/api/v1/admin/me`, qui ne renvoie de toute façon pas encore `company_id` côté backend, un gap mineur déjà documenté séparément dans `docs/PROJECT_STATUS.md`). Passe `fixedCompanyId` au nouveau `CompanyProvider`, qui enveloppe le `CountryProvider` existant :

```tsx
<CompanyProvider isSuperAdmin={isSuperAdmin} fixedCompanyId={fixedCompanyId}>
  <CountryProvider isSuperAdmin={isSuperAdmin} fixedCountryId={fixedCountryId} role={payload.role}>
    ...
  </CountryProvider>
</CompanyProvider>
```

### Changement clé à `CountryProvider`

Aujourd'hui, `CountryProvider` fetch le catalogue complet des pays actifs (`GET /api/proxy/countries`, filtré `c.active`). Ce comportement change : il doit désormais fetch uniquement les pays **abonnés par l'entreprise sélectionnée** (`GET /api/proxy/companies/{selectedCompany.id}/countries`), et re-fetch quand `selectedCompany` change (nouvelle dépendance dans son `useEffect`). Ceci implique que `CountryProvider` doit lire `useCompany()` en interne — d'où le nesting `CompanyProvider > CountryProvider` ci-dessus (l'ordre est contraint, pas arbitraire).

**Cas `super_admin` sans entreprise sélectionnée** (ex. juste après connexion, avant que `CompanyProvider` ait fini son fetch) : `CountryProvider` doit gérer l'absence temporaire de `selectedCompany` sans planter — retourner une liste de pays vide et `loading: true` jusqu'à ce que `selectedCompany` soit résolu, exactement comme le pattern de chargement déjà utilisé pour les pays eux-mêmes aujourd'hui.

---

## Section 3 — Nouvelle route proxy `companies`

Nouveau dossier `app/api/proxy/companies/`, construit sur le modèle exact de `app/api/proxy/countries/` (5 fichiers existants à mirorer) :

| Fichier existant (countries) | Nouveau fichier (companies) | Endpoint backend visé |
|---|---|---|
| `route.ts` | `route.ts` | `GET/POST /api/v1/admin/companies` |
| `[id]/route.ts` | `[id]/route.ts` | `GET/PUT/DELETE /api/v1/admin/companies/{id}` |
| — (pas d'équivalent countries) | `[id]/countries/route.ts` | `GET/POST /api/v1/admin/companies/{id}/countries` |
| — | `[id]/countries/[countryId]/route.ts` | `DELETE /api/v1/admin/companies/{id}/countries/{countryId}` |
| `[id]/settings/route.ts` | `[id]/settings/route.ts` | `GET /api/v1/admin/companies/{id}/settings` |
| `[id]/settings/[section]/route.ts` | `[id]/settings/[section]/route.ts` | `GET/PUT /api/v1/admin/companies/{id}/settings/{section}` |
| `[id]/run/route.ts` | `[id]/run/route.ts` | `POST /api/v1/admin/companies/{id}/run` |

Chaque route suit exactement le pattern déjà établi (`getToken()` depuis le cookie `auth_token`, 401 si absent, forward vers `${API_URL}` avec le header `Authorization`, retransmission du statut de la réponse backend telle quelle).

---

## Section 4 — Nouvelle page `/companies` + nav

### Page `app/(dashboard)/companies/page.tsx` + `app/(dashboard)/companies/new/page.tsx`

Construites sur le modèle exact de `app/(dashboard)/countries/page.tsx` + `.../countries/new/page.tsx` (liste avec actions, formulaire de création). Contenu :
- Liste des entreprises (nom, slug, statut actif, actions modifier/désactiver).
- Formulaire de création (`name`, `slug`, `logo_url`, `subject_prefix`, `signature` — champs optionnels sauf `name`/`slug`, cf. `CompanyCreate` côté backend).
- Section abonnement pays : cocher/décocher les pays du catalogue global pour l'entreprise sélectionnée (checklist), via `POST`/`DELETE .../countries`.
- Section assignation d'utilisateurs `company_admin` : lien vers la page Utilisateurs filtrée sur cette entreprise plutôt qu'un formulaire dupliqué (éviter la duplication de logique de création d'utilisateur déjà présente dans `create-user-dialog.tsx`).

**Accès : `super_admin` uniquement** — page et route proxy sous-jacente protégées de la même manière que `/countries` l'est déjà aujourd'hui (aucune protection route explicite trouvée dans `/countries` au niveau page — la protection actuelle vient uniquement du fait que le lien nav n'apparaît que pour `super_admin` dans `sidebar.tsx`, et le backend rejette de toute façon les rôles non-`super_admin` sur les endpoints d'écriture. Ce plan suit le même modèle de protection, pas de nouvelle couche à inventer).

### `components/sidebar.tsx`

Ajouter `{ href: "/companies", label: "Compagnies" }` à `superAdminLinks` (aux côtés de "Utilisateurs"/"Pays").

---

## Section 5 — Pages existantes impactées

| Page | Changement |
|---|---|
| **Sources** (`app/(dashboard)/sources/page.tsx`) | Aucune vérification de rôle n'existe actuellement dans ce fichier (confirmé par recherche) — les actions de création/modification/suppression sont actuellement ouvertes à tout utilisateur connecté. Ajouter : masquer/désactiver les contrôles d'écriture (bouton "Nouvelle source", actions modifier/supprimer par ligne) pour `company_admin`/`company_viewer`, visibles en lecture seule uniquement — miroir de la restriction déjà en place côté backend (`sources.py`, sous-projet A). Pas de nouvelle UI de filtrage par abonnement pays dans cette itération (le backend lui-même ne filtre pas encore la liste par abonnement — c'était un gap explicitement documenté comme non résolu dans le plan backend, hors périmètre ici). |
| **Destinataires** | Actuellement un onglet à l'intérieur de `settings-client.tsx` (pas de page dédiée trouvée). Filtrer les appels API existants par `selectedCompany.id` en plus de `selectedCountry.id` — le backend (`recipients.py`, déjà scoping `company_id` depuis le sous-projet A) applique déjà le filtre côté serveur pour `company_admin`/`company_viewer`, donc ce changement frontend concerne surtout `super_admin` (qui doit pouvoir choisir l'entreprise dont il veut voir/gérer les destinataires) et l'ajout de `company_id` au formulaire de création (visible seulement pour `super_admin`, mêmes principes que le nouveau champ `company_id` optionnel de `RecipientCreate` côté backend). |
| **Paramètres** (`app/(dashboard)/settings/settings-client.tsx`) | Le pattern actuel bascule déjà entre `/api/proxy/settings/{section}` (global) et `/api/proxy/countries/{countryId}/settings/{section}` (par pays) selon qu'un pays est sélectionné. Ajouter un troisième niveau : quand une entreprise est sélectionnée, utiliser `/api/proxy/companies/{companyId}/settings/{section}` pour les sections `classification`/`scheduler`/`email` (celles gérées par `CompanySettings` côté backend, cf. spec Section 3 du sous-projet A) — la logique de sélection d'URL existante (actuellement un simple `if/else` à deux branches) devient une résolution à trois niveaux : entreprise sélectionnée > pays sélectionné > global, selon la section concernée. |
| **Utilisateurs** (`app/(dashboard)/users/page.tsx`) | Couvert en Section 1 pour le renommage des littéraux ; ajout du champ `company_id` (requis si le rôle choisi est `company_admin`/`company_viewer`, miroir exact du champ `country_id` déjà présent) dans `create-user-dialog.tsx` et dans le formulaire de modification s'il existe. |
| **Reports / Runs / Logs** | Distinguer visuellement les runs de type `harvest` (visibles `super_admin` uniquement) des runs de type `delivery` (scopés par entreprise, cf. `Run.run_type`/`Run.company_id` déjà exposés par le backend scoping du sous-projet A). Détail d'implémentation exact (colonne supplémentaire, filtre, badge) laissé à l'exécution du plan — pas assez de contrainte backend/UX pour figer un choix précis ici sans revoir les endpoints `/runs`/`/reports` existants plus en détail pendant l'implémentation. |

---

## Hors périmètre (ce sous-projet)

- Filtrage de la liste des sources par abonnement pays de l'entreprise (le backend ne le fait pas encore non plus — gap documenté séparément).
- Ajout de `company_id` à l'endpoint `/api/v1/admin/me` côté backend (gap mineur déjà noté dans `docs/PROJECT_STATUS.md`, pas bloquant puisque le frontend décode le JWT directement).
- Le correctif de contrainte DB `uq_recipients_email_country` non scopée par `company_id` (dette backend déjà documentée, hors périmètre frontend).
- Tout travail de déploiement staging/prod — reste géré au niveau du plan d'exécution puis de la décision utilisateur explicite, comme pour tout le reste de ce projet.
