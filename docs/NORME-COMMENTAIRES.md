# Norme de commentaires du code iClub

> Copie de la norme commune aux trois dépôts d'iClub. La version de référence est `docs/collaboration/NORME-COMMENTAIRES.md` dans le dépôt `iclub-web`, avec la méthode de travail (`WAY-OF-WORKING.md`) et le registre des travaux. Une modification se fait d'abord là, puis est recopiée ici.

Adoptée le 14 novembre 2026 (fiche D1, tenue dans le dépôt `iclub-web`). Elle s'applique à tout le code d'iClub : application web (`iclub-web`), application iOS (`iclub-ios`) et site vitrine (`iclub-landing`). Elle vaut pour le code existant, repris par la passe D1, et pour tout code écrit ensuite.

## 1. Pourquoi

iClub doit pouvoir être repris sans la mémoire de ceux qui l'ont écrit : par un acquéreur et ses développeurs, par un auditeur technique, par un nouveau contributeur. Le code doit donc se lire seul. Chaque fichier dit ce qu'il fait, où il s'insère, quelles règles du club il applique, qui a le droit de s'en servir et ce qu'il ne faut pas casser.

Un changement de code dont les commentaires ne sont pas à jour est un changement incomplet. Il ne se commite pas.

## 2. Règles générales

1. **Français**, en phrases complètes, avec le vocabulaire du club : adhérent, extérieur, terrain, créneau, réservation, partie ouverte, séance, cours, stage, formule, adhésion, reçu, facture, wallet, profil d'accès. Les identifiants du code restent tels quels ; un identifiant anglais (`is_admin`, `courts`) est expliqué en français.
2. **Dire le pourquoi et la règle, pas la syntaxe.** Mauvais : `// on parcourt les terrains`. Bon : `// Un terrain fermé par l'administrateur reste affiché, grisé : l'adhérent doit voir qu'il existe sans pouvoir le réserver.`
3. **Exactitude d'abord.** Un commentaire faux est pire que pas de commentaire. Ne décrire que ce que le code fait réellement, vérifié en le lisant, et au besoin en lisant ses appelants et ce qu'il appelle. Quand l'intention n'est pas certaine, décrire le comportement observé sans inventer de raison.
4. **Défauts repérés.** Un défaut, une incohérence ou un risque vu en commentant est décrit factuellement dans le commentaire (« Attention : ... », « Limite connue : ... ») et consigné dans la fiche D en cours. Une passe de commentaires ne le corrige pas : la correction est un changement de code, avec sa propre fiche et ses propres tests.
5. **Ponctuation et ton.** Aucun tiret cadratin ni demi-cadratin comme ponctuation, ni de trait d'union entouré d'espaces qui en tiendrait lieu : couper la phrase, ou employer virgule, deux-points, point-virgule, parenthèses. Les listes à puces « - » restent permises. Pas d'emoji. Aucune mention d'outil d'intelligence artificielle ni de « code généré ». Pas de « TODO » ou « FIXME » nus : écrire « À faire : ... » ou « Limite connue : ... » avec la raison et la condition.
6. **Pas de code mis en commentaire** pour plus tard. S'il en existe, le signaler dans la fiche D ; le supprimer est un changement de code.
7. **Pas de secret ni de donnée personnelle** dans un commentaire : ni clé, ni mot de passe, ni jeton, ni adresse ou nom réel d'un adhérent. Pour un exemple, `adherent@example.com`.
8. **Les commentaires vivent avec le code.** Toute modification met à jour, dans le même commit, l'en-tête du fichier, la documentation des déclarations touchées et les commentaires de ligne concernés. La relecture d'un changement vérifie aussi ses commentaires.

## 3. Ce qui doit être commenté

### 3.1 En-tête de chaque fichier

Tout fichier de code commence par un bloc d'en-tête. Si le fichier débute par une directive (`"use client"`, `"use server"`, `import "server-only"` peut rester avec les imports), la directive reste sur la première ligne et l'en-tête vient juste après. Contenu attendu, rubrique par rubrique quand elle a lieu d'être :

- **Rôle** : ce que fait le fichier, en une ou deux phrases.
- **Place dans l'application** : l'URL servie ou l'écran concerné, qui l'appelle, ce qu'il appelle (actions serveur, tables, fonctions SQL, API externes comme Resend ou le stockage).
- **Règles métier** appliquées.
- **Droits et sécurité** : qui peut y accéder, ce qui est vérifié ici, ce qui repose sur la RLS de la base, et, si la clé de service (`createAdminClient`) est utilisée, pourquoi c'est sûr à cet endroit.
- **Effets de bord** : écritures en base, courriels envoyés, fichiers stockés, cache invalidé (`revalidatePath`), journal des actions.
- **Points d'attention** : pièges, limites connues, dépendances fragiles (par exemple la limite de mille lignes par appel de l'API Supabase, voir `src/lib/supabase/pages.ts`).

### 3.2 Chaque déclaration

Chaque fonction, composant, hook, classe, type, interface et constante exportée a un bloc de documentation `/** ... */` (`///` en Swift, docstring en Python) qui donne :

- son objet, en une phrase ;
- chaque paramètre (`@param`) : sens, unité, valeurs admises, signification de `null` ou d'une valeur absente ;
- le résultat (`@returns`) : forme et sens. Pour une action serveur, la forme `{ ok, error }` et les messages possibles ;
- les effets de bord, les erreurs levées ou rendues, les droits requis.

Pour un composant React, chaque propriété est documentée sur son champ dans le type des propriétés, plutôt qu'avec `@param`. Les fonctions internes, non exportées, ont aussi leur bloc, plus court.

### 3.3 Types et interfaces

Chaque champ : son sens, son unité (centimes ou euros, minutes depuis minuit, date ISO, fuseau du club), son origine (colonne SQL, calcul) et ce que signifient `null` ou `undefined`.

### 3.4 Corps des fonctions

- Chaque étape logique est annoncée par un commentaire de ligne.
- Chaque règle métier, cas limite, nombre ou chaîne « magique », et chaque choix non évident (performance, contournement d'une limite, ordre des opérations, idempotence, accès concurrents) est expliqué.
- Requêtes Supabase : ce qu'elles lisent ou écrivent, les filtres, les jointures (`clubs!inner`), la raison du `select` choisi, la pagination, l'effet de la RLS.
- Dates et heures : fuseau du club, bornes incluses ou exclues.
- Argent : unité, arrondis, TVA, numérotation des pièces comptables.

### 3.5 JSX

Des commentaires `{/* ... */}`, chacun sur sa propre ligne, délimitent les zones de l'écran (en-tête, filtres, liste, état vide, fenêtre de confirmation) et expliquent chaque affichage conditionnel. Jamais de commentaire au milieu d'un texte affiché : il couperait la phrase en deux à l'écran. Jamais de `//` dans le JSX : ce serait du texte visible.

### 3.6 SQL (migrations Supabase)

- **En-tête de migration** : objet, contexte (pourquoi), objets créés ou modifiés, effet sur les données existantes, migrations dont elle dépend, caractère rejouable ou non, retour arrière possible ou non.
- Chaque table : son rôle ; chaque colonne non évidente : unité, valeurs admises ; chaque contrainte.
- Chaque politique RLS : qui peut quoi, et pourquoi.
- Chaque fonction : objet, paramètres, valeur rendue, justification de `security definer` et de son `search_path`, étapes commentées dans le corps.
- Déclencheurs ; index (quelle requête ils servent).
- Une migration déjà appliquée n'est modifiée que par des commentaires `--` ou `/* */`. On n'y ajoute jamais d'instruction, pas même un `comment on` : ce serait un changement de schéma, qui demande sa propre migration.

### 3.7 CSS

En-tête du fichier, chaque section, chaque valeur non évidente (z-index, hauteur précise, variable de thème) et chaque contournement propre à un navigateur.

### 3.8 Scripts (`scripts/`)

En-tête avec la commande exacte, les prérequis (variables d'environnement), ce que le script écrit et où, et les précautions. Rappel : il n'existe qu'une base Supabase, partagée par le développement local et la production ; un script qui écrit, écrit dans les données réelles des clubs.

### 3.9 Swift (application iOS)

`///` pour la documentation, que Xcode affiche dans l'aide rapide. `// MARK: -` pour les sections : c'est la convention d'Xcode, le trait y trace un séparateur dans la barre de navigation, il est donc permis. Chaque vue : l'écran, la source des données (service), les états (chargement, erreur, vide), la navigation. Chaque service : tables et fonctions Supabase utilisées, gestion des erreurs, fil d'exécution (`@MainActor`). Chaque modèle : chaque propriété et sa colonne (`CodingKeys`).

### 3.10 Python et HTML (site vitrine)

Python : docstring de module et de fonction, commentaires `#` pour les étapes. HTML : commentaires `<!-- ... -->` sur leur propre ligne entre les blocs de la page. Ils sont publics, visibles dans le source de la page : rien d'interne (stratégie de prix, noms, accès). Les pages produites par `_sources/pages.py` se commentent dans le générateur, jamais dans le HTML produit, qui serait écrasé.

## 4. Exemples de référence

Deux fichiers commentés selon cette norme servent d'étalon :

- une action serveur : `src/lib/actions/accesTerrains.ts` du dépôt `iclub-web` (en-tête par rubriques, erreurs traduites, droits, étapes, idempotence, invalidation du cache) ;
- un composant d'interface : `src/components/ui/Button.tsx` du dépôt `iclub-web` (propriétés documentées une à une, styles expliqués, accessibilité, commentaire JSX).

Dans ce dépôt, les fichiers Swift commentés pendant la passe D1 suivent la même norme : par exemple `iClub/Services/ReservationService.swift` pour un service, `iClub/Features/Booking/BookingView.swift` pour une vue.

Pour le SQL, les en-têtes des migrations récentes, comme `supabase/migrations/20261030100000_acces_terrains_groupes.sql` du dépôt `iclub-web`, donnent le ton ; la passe D1 les complète par des commentaires sur chaque instruction.

## 5. Vérifier

Une passe de commentaires ne change aucun caractère de code : ni import, ni mise en page, ni ordre, ni texte affiché. La preuve, fichier par fichier :

```bash
node scripts/commentaires-seuls.mjs --base <commit de départ>
```

Le script compare chaque fichier modifié à sa version de référence de deux façons : la suite de ses jetons, une fois retirés commentaires et blancs, ce qui prouve que le comportement n'a pas changé ; puis ses lignes de code au caractère près, commentaires effacés, ce qui prouve que la mise en page n'a pas bougé non plus (fonctionnement détaillé dans son en-tête). Il doit répondre `IDENTIQUE` partout. `DIFFÉRENT` signale un changement de code ; `MISE EN PAGE`, une ligne de code retouchée sans effet sur le comportement (une espace perdue, une indentation changée). Les deux se corrigent en remettant le code exactement comme il était. Les outils d'édition retirent parfois une espace en fin de remplacement ou changent une espace insécable en espace ordinaire : le vérificateur le voit.

Il couvre TypeScript, JavaScript, SQL, CSS, Swift, Python et HTML, et il est présent dans chacun des trois dépôts (`scripts/commentaires-seuls.mjs`). Pour un changement de code ordinaire, il ne s'applique pas ; on vérifie alors, à la relecture, que les commentaires suivent le code.

## 6. Relire

Avant chaque commit, pour chaque fichier touché :

- l'en-tête décrit encore le fichier tel qu'il est ;
- toute déclaration nouvelle ou modifiée a sa documentation à jour ;
- les règles métier nouvelles sont expliquées là où elles s'appliquent ;
- aucun commentaire ne contredit le code ;
- la ponctuation suit la règle 5.
