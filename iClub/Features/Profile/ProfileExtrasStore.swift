//
//  ProfileExtrasStore.swift
//  iClub
//
//  Ce que l'onglet Profil lit en plus du profil de session : enfants, pièces
//  demandées et déposées, reçus et factures, sous-domaine du club.
//
//  Chaque lecture est indépendante et tolérante : une migration absente vide
//  une carte, elle ne casse jamais l'écran.
//

import Foundation
import Observation

/// Une personne dont on suit les pièces : le membre, ou l'un de ses enfants.
struct DocumentHolder: Identifiable, Hashable {
    let profileId: UUID
    let name: String
    let age: Int?
    let isMe: Bool
    var id: UUID { profileId }
}

@Observable
final class ProfileExtrasStore {

    private(set) var children: [ManagedProfile] = []
    private(set) var documentTypes: [DocumentType] = []
    private(set) var documents: [MemberDocument] = []
    private(set) var receipts: [AccountingDocument] = []
    private(set) var clubSlug: String?
    private(set) var isLoaded = false
    /// Vrai si la lecture des pièces a échoué (table absente, réseau).
    private(set) var documentsUnavailable = false

    // MARK: - Lectures dérivées

    /// Le membre puis ses enfants, avec leur âge pour filtrer les pièces.
    func holders(me profile: SessionProfile) -> [DocumentHolder] {
        let myAge = profile.dateNaissance.flatMap {
            Calendar.current.dateComponents([.year], from: $0, to: .now).year
        }
        return [DocumentHolder(profileId: profile.id, name: "Moi", age: myAge, isMe: true)]
            + children.map { DocumentHolder(profileId: $0.profileId, name: $0.prenom ?? $0.displayName, age: $0.age, isMe: false) }
    }

    /// Types qui concernent cette personne, chacun avec sa pièce en cours.
    func lines(for holder: DocumentHolder) -> [(type: DocumentType, document: MemberDocument?)] {
        documentTypes
            .filter { $0.concerns(age: holder.age) }
            .map { type in
                (type, documents.first { $0.profileId == holder.profileId && $0.typeDocumentId == type.id })
            }
    }

    // MARK: - Chargement

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
        await reloadDocuments(profile: profile)
        documentsUnavailable = loadedTypes == nil
        isLoaded = true
    }

    func reloadDocuments(profile: SessionProfile) async {
        let ids = [profile.id] + children.map(\.profileId)
        documents = (try? await MemberDocumentsService.currentDocuments(profileIds: ids)) ?? documents
    }

    func reloadChildren(profile: SessionProfile) async {
        children = await ActivityService.managedProfiles(clubId: profile.clubId).filter { !$0.estMoi }
        await reloadDocuments(profile: profile)
    }
}
