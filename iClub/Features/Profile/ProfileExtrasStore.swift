//
//  ProfileExtrasStore.swift
//  iClub
//
//  Rôle
//    Ce que l'onglet Profil lit en plus du profil de session : enfants, pièces
//    demandées et déposées, reçus et factures, sous-domaine du club.
//
//    Chaque lecture est indépendante et tolérante : une migration absente vide
//    une carte, elle ne casse jamais l'écran.
//
//  Place dans l'application
//    Créé en `@State` par ProfileView, chargé à l'ouverture de l'onglet et au
//    geste « tirer pour rafraîchir », puis passé aux sections famille
//    (FamilySection), pièces (DocumentsSection), reçus (ReceiptsSection) et
//    autres espaces (OtherSpacesRow).
//
//  Données (ActivityService, MemberDocumentsService)
//    - fonction SQL `mes_profils_geres` : le membre et ses enfants ;
//    - table `clubs` : le sous-domaine (`slug`) du club, pour les liens vers
//      le site web et le téléchargement des PDF ;
//    - table `types_documents` : pièces demandées par le club (actives, dans
//      l'ordre du club) ;
//    - table `documents_adherent` : pièces en cours (non remplacées) du membre
//      et de ses enfants ; la RLS les réserve à l'intéressé, à son responsable
//      et au club ;
//    - table `documents_comptables` : reçus, factures et avoirs du membre, du
//      plus récent au plus ancien.
//
//  Fil d'exécution
//    Classe `@Observable` isolée sur l'acteur principal (réglage du projet) ;
//    les quatre premières lectures partent en parallèle.
//

import Foundation
import Observation

/// Une personne dont on suit les pièces : le membre, ou l'un de ses enfants.
struct DocumentHolder: Identifiable, Hashable {
    /// Identifiant de son profil (`profiles.id`).
    let profileId: UUID
    /// Nom affiché : « Moi » pour le membre, le prénom pour un enfant.
    let name: String
    /// Âge en années, pour filtrer les pièces réservées aux mineurs ou aux
    /// majeurs ; `nil` si la date de naissance est inconnue.
    let age: Int?
    /// Vrai pour le membre lui-même.
    let isMe: Bool
    /// Identité de la ligne : le profil.
    var id: UUID { profileId }
}

/// Magasin des données complémentaires de l'onglet Profil.
@Observable
final class ProfileExtrasStore {

    /// Enfants dont le membre est responsable (sans lui-même).
    private(set) var children: [ManagedProfile] = []
    /// Types de pièces demandés par le club.
    private(set) var documentTypes: [DocumentType] = []
    /// Pièces en cours du membre et de ses enfants, les plus récentes d'abord.
    private(set) var documents: [MemberDocument] = []
    /// Reçus, factures et avoirs du membre.
    private(set) var receipts: [AccountingDocument] = []
    /// Sous-domaine du club (`demo` pour demo.iclubapp.fr), ou `nil` s'il n'a
    /// pas pu être lu.
    private(set) var clubSlug: String?
    /// Premier chargement terminé.
    private(set) var isLoaded = false
    /// Vrai si la lecture des pièces a échoué (table absente, réseau).
    private(set) var documentsUnavailable = false

    // MARK: - Lectures dérivées

    /// Le membre puis ses enfants, avec leur âge pour filtrer les pièces.
    /// - Parameter profile: profil de la session (le parent).
    /// - Returns: « Moi » en premier, puis un porteur par enfant.
    func holders(me profile: SessionProfile) -> [DocumentHolder] {
        // Âge du membre en années révolues, à partir de sa date de naissance.
        let myAge = profile.dateNaissance.flatMap {
            Calendar.current.dateComponents([.year], from: $0, to: .now).year
        }
        return [DocumentHolder(profileId: profile.id, name: "Moi", age: myAge, isMe: true)]
            + children.map { DocumentHolder(profileId: $0.profileId, name: $0.prenom ?? $0.displayName, age: $0.age, isMe: false) }
    }

    /// Types qui concernent cette personne, chacun avec sa pièce en cours.
    ///
    /// Le filtre d'âge suit les règles du web (`DocumentType.concerns`) ; la
    /// pièce retenue est la première trouvée, donc la plus récente.
    /// - Parameter holder: la personne.
    /// - Returns: un couple (type, pièce ou `nil` si aucune n'est déposée) par
    ///   type demandé.
    func lines(for holder: DocumentHolder) -> [(type: DocumentType, document: MemberDocument?)] {
        documentTypes
            .filter { $0.concerns(age: holder.age) }
            .map { type in
                (type, documents.first { $0.profileId == holder.profileId && $0.typeDocumentId == type.id })
            }
    }

    // MARK: - Chargement

    /// Charge tout l'onglet : enfants, sous-domaine, types de pièces et reçus
    /// en parallèle, puis les pièces de toute la famille.
    ///
    /// Les erreurs ne sont pas levées : une lecture qui échoue laisse sa liste
    /// vide. Un échec sur les types de pièces marque les pièces comme
    /// indisponibles (message dédié dans la carte).
    /// - Parameter profile: profil de la session (le parent).
    func load(profile: SessionProfile) async {
        async let kids = ActivityService.managedProfiles(clubId: profile.clubId)
        async let slug = MemberDocumentsService.clubSlug(clubId: profile.clubId)
        async let types = try? MemberDocumentsService.documentTypes(clubId: profile.clubId)
        async let docs = try? MemberDocumentsService.accountingDocuments(profileId: profile.id)

        let (loadedKids, loadedSlug, loadedTypes, loadedReceipts) = await (kids, slug, types, docs)

        children = loadedKids.filter { !$0.estMoi }
        clubSlug = loadedSlug
        receipts = loadedReceipts ?? []
        documentTypes = loadedTypes ?? []
        // Les pièces après les enfants : il faut connaître leurs profils.
        await reloadDocuments(profile: profile)
        documentsUnavailable = loadedTypes == nil
        isLoaded = true
    }

    /// Relit les pièces en cours du membre et de ses enfants.
    ///
    /// En cas d'échec, la liste déjà affichée est gardée.
    /// - Parameter profile: profil de la session (le parent).
    func reloadDocuments(profile: SessionProfile) async {
        let ids = [profile.id] + children.map(\.profileId)
        documents = (try? await MemberDocumentsService.currentDocuments(profileIds: ids)) ?? documents
    }

    /// Relit les enfants (après un ajout ou un retrait), puis leurs pièces.
    /// - Parameter profile: profil de la session (le parent).
    func reloadChildren(profile: SessionProfile) async {
        children = await ActivityService.managedProfiles(clubId: profile.clubId).filter { !$0.estMoi }
        await reloadDocuments(profile: profile)
    }
}
