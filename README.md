# iClub, application iPhone

Application iOS native des adhérents et des entraîneurs d'un club iClub : accueil, réservation d'un terrain, parties ouvertes, mes réservations, adhésion, cours et activités, espace entraîneur (agenda, appel, création de cours), messagerie, profil (informations, classements, famille, pièces justificatives, reçus, notifications) et suppression du compte.

L'application web et le back-office du club sont dans le dépôt `iclub-web`, qui contient aussi le schéma de la base et toute la documentation du projet (`docs/`). Les deux applications partagent **la même base Supabase** : mêmes tables, mêmes comptes, mêmes règles.

## Technologies

| Domaine | Choix |
| --- | --- |
| Interface | SwiftUI, cible iOS 27, matériau Liquid Glass, SF Pro et SF Pro Rounded |
| Langage | Swift 5, isolation par défaut sur l'acteur principal (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) : vues et magasins tournent sur l'acteur principal, ce qui doit en sortir est marqué `nonisolated` |
| Données | `supabase-swift` 2.55 (Swift Package Manager) : authentification, tables (PostgREST), fonctions SQL (`rpc`), stockage, temps réel, fonctions serveur |
| Système | Sign in with Apple, notifications (APNs), rappels locaux, EventKit (ajout au calendrier) |

## Organisation du code

```
iClub/
  iClubApp.swift   Point d'entrée
  Core/            Configuration, client Supabase unique, contrôleurs observables
                   (AuthController, ClubCatalog, AppRouter), AppDelegate, moteurs purs
                   (AvailabilityEngine, OpenGameEligibility), mises en forme (dates, prix, téléphone)
  Models/          Lignes décodées depuis la base (…Row), enveloppe Lenient qui écarte une ligne
                   illisible sans faire échouer la liste, SupabaseDate
  Services/        Seuls appelants du SDK : une enum de fonctions asynchrones par domaine
  Features/        Écrans et leurs magasins : Root, Home, Booking, OpenGames, Reservations,
                   Membership, Notifications, Auth, Profile, Coach, Messaging, Activities
  DesignSystem/    Couleurs (catalogue Assets.xcassets, valeurs claires reprises du thème
                   « iclub » du web), typographie, composants communs
docs/              Norme de commentaires, note sur le paiement d'adhésion
scripts/           Outil de preuve des passes de commentaires
```

Le chemin d'une donnée est toujours le même : vue, puis magasin, puis service, puis Supabase. Une écriture est en général suivie d'un `.select()`, car un refus de la RLS ne lève pas d'erreur.

## Configuration et sécurité

- `Core/AppConfiguration.swift` porte l'adresse du projet Supabase et sa clé publique (`anon`), publique par construction. **L'app n'embarque jamais la clé de service** : toute la sécurité repose sur la RLS et les fonctions `security definer` de la base.
- L'app écrit directement dans la base, sans passer par le serveur web : seules les règles de la base s'appliquent à elle. Les règles qui n'existent que dans le serveur web ne la protègent pas (voir les défauts connus).
- L'app sert un seul club à la fois : le club est déduit de l'appartenance du compte (`club_members`). Un compte sans club est rattaché par `join_club_as_member` au club fixé dans la configuration.
- La connexion Google est en sommeil par décision : le paquet n'est pas dans le projet, le code `#if canImport` est inactif.

## Parcours de connexion

`AuthController` écoute les changements de session. À l'ouverture, `ProfileService` assemble le profil (`profiles`, `club_members`, `clubs` et l'adhésion à jour qui couvre aujourd'hui). `RootView` aiguille ensuite : configuration absente, lancement, connexion (adresse et mot de passe, ou Apple), complétion du profil (téléphone, naissance, sexe), onglets, ou compte bloqué. En compte famille, un parent peut agir pour un enfant : c'est toujours le parent connecté qui écrit en base.

## Compiler

Ouvrir `iClub.xcodeproj` dans Xcode 27, schéma `iClub`. En ligne de commande :

```bash
xcodebuild -project iClub.xcodeproj -scheme iClub -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Au 14 novembre 2026, la compilation réussit avec 28 avertissements (isolation d'acteur, méthode `subscribe()` dépréciée du SDK), qui viennent du code et non de sa documentation.

## État et limites

- Les notifications push attendent la clé APNs, à créer dans App Store Connect : tant qu'elle manque, les messages arrivent dans l'app sans notification.
- Le paiement d'adhésion en ligne et la demande d'adhésion au club appellent des fonctions serveur qui n'existent pas encore (voir `docs/PAIEMENT_ADHESION.md`).
- Les défauts repérés en lisant tout le code sont décrits dans le dépôt `iclub-web`, `docs/defauts-connus.md`, section 2. Le plus grave : une réservation avec un invité payant est refusée par la base, car l'app écrit des valeurs de paiement que la table n'accepte plus.

## Développement et commentaires

Le code est écrit avec Claude dans Xcode, à partir de prompts rangés hors dépôt (dossier `ios-app` du propriétaire). Il est commenté en détail selon [la norme de commentaires](docs/NORME-COMMENTAIRES.md), commune aux trois dépôts : chaque prompt la rappelle. La méthode de travail et le registre des travaux sont dans `iclub-web` (`docs/collaboration/`). Une passe de commentaires se prouve sans effet sur le code avec :

```bash
node scripts/commentaires-seuls.mjs --base <commit de départ>
```
