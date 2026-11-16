//
//  DocumentsSection.swift
//  iClub
//
//  Rôle
//    « Mes pièces » : ce que le club demande, pour le membre et pour chacun de
//    ses enfants, et l'état de chaque pièce, avec le même vocabulaire que le
//    web (licence, certificat ou attestation de santé, etc.).
//
//    Une pièce sensible (attestation de santé) n'est jamais affichée en aperçu
//    ailleurs que dans l'écran de dépôt. En pratique, aucune pièce déposée
//    n'est jamais affichée : les listes ne montrent que le nom du fichier, et
//    l'indicateur `sensible` des types de pièces n'est lu nulle part.
//
//  Place dans l'application
//    - DocumentsSection : carte de résumé de l'onglet Profil, qui pousse
//      DocumentsScreen ;
//    - DocumentsScreen : l'écran complet, une personne à la fois ;
//    - DocumentListCard : les pièces d'une personne, réutilisée dans la fiche
//      d'un enfant (FamilySection) ;
//    - UploadPieceSheet : la feuille de dépôt (appareil photo, photothèque ou
//      Fichiers) ;
//    - CameraPicker : l'appareil photo d'iOS.
//
//  Données et écritures (ProfileExtrasStore, MemberDocumentsService,
//  migrations 20261019130000_documents_adherent et
//  20261023110000_pieces_depuis_mobile)
//    - lecture : `types_documents` (pièces demandées) et `documents_adherent`
//      (pièces en cours, non remplacées) ;
//    - dépôt : le fichier est envoyé dans le compartiment privé
//      `documents-adherents`, au chemin <club>/<profil>/<fichier>, puis
//      enregistré par la fonction SQL `deposer_piece`, qui calcule la date
//      d'expiration à partir de la durée de validité du type et marque la
//      pièce précédente comme remplacée ; si l'enregistrement échoue, le
//      fichier est retiré ;
//    - suppression : la ligne d'abord (la RLS ne l'autorise que tant que la
//      pièce n'est pas validée), puis le fichier.
//
//  Droits et sécurité
//    Le membre ne dépose, ne lit et ne supprime que ses fichiers et ceux des
//    enfants dont il est responsable (`est_responsable_de`), dans le
//    compartiment comme dans la table. La validation et le refus sont faits
//    par le club, sur le web. Formats admis : PDF, JPEG, PNG, HEIC, HEIF ;
//    10 Mo au plus (vérifié ici et par `deposer_piece`).
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Dans le profil, une seule ligne qui résume l'état des pièces et mène à
/// l'écran complet.
struct DocumentsSection: View {
    /// Le compte connecté (le parent).
    let profile: SessionProfile
    /// Données complémentaires : types de pièces, pièces, enfants.
    let store: ProfileExtrasStore

    /// Carte repliée si le club ne demande rien (ou si la lecture a échoué),
    /// sinon la ligne de résumé, avec une icône orange s'il y a quelque chose
    /// à faire et verte sinon.
    var body: some View {
        if store.documentTypes.isEmpty {
            CollapsedProfileCard(
                title: "Mes pièces",
                message: store.documentsUnavailable ? "Les pièces ne sont pas disponibles pour l'instant." : "Le club ne demande aucune pièce."
            )
        } else {
            NavigationLink {
                DocumentsScreen(profile: profile, store: store)
            } label: {
                SurfaceCard(padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: needsAttention ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(needsAttention ? Brand.warning : Brand.success)
                            .frame(width: 36, height: 36)
                            .background((needsAttention ? Brand.warning : Brand.success).opacity(0.12), in: .circle)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.children.isEmpty ? "Mes pièces" : "Pièces de la famille").metaLabelStyle()
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(Brand.textSecondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// États de toutes les pièces qui comptent : membre et enfants. Les pièces
    /// « compétiteurs » ne comptent jamais comme manquantes, comme sur le web.
    ///
    /// Une pièce facultative ne compte que si elle a été déposée.
    private var states: [DocumentState] {
        store.holders(me: profile).flatMap { holder in
            store.lines(for: holder)
                .filter { $0.type.concerne != .competiteurs || $0.document != nil }
                .filter { $0.type.obligatoire || $0.document != nil }
                .map { DocumentState(document: $0.document) }
        }
    }

    /// Quelque chose à faire : une pièce manquante, expirée, refusée ou qui
    /// expire dans les 30 jours. Une pièce en cours de vérification n'en est
    /// pas une.
    private var needsAttention: Bool {
        states.contains { state in
            switch state {
            case .missing, .expired, .refused, .expiringSoon: true
            case .pending, .valid: false
            }
        }
    }

    /// « 2 à déposer · 1 en cours de vérification », ou « Tout est à jour ».
    ///
    /// Compte les états par catégorie (expirées et refusées ensemble, « à
    /// refaire ») et ne cite que les catégories non vides.
    private var summary: String {
        var missing = 0, pending = 0, toRedo = 0, soon = 0
        for state in states {
            switch state {
            case .missing: missing += 1
            case .pending: pending += 1
            case .expired, .refused: toRedo += 1
            case .expiringSoon: soon += 1
            case .valid: break
            }
        }
        var parts: [String] = []
        if missing > 0 { parts.append("\(missing) à déposer") }
        if toRedo > 0 { parts.append("\(toRedo) à refaire") }
        if soon > 0 { parts.append("\(soon) bientôt expirée\(soon > 1 ? "s" : "")") }
        if pending > 0 { parts.append("\(pending) en cours de vérification") }
        return parts.isEmpty ? "Tout est à jour" : parts.joined(separator: " · ")
    }
}

/// L'écran complet : le membre et chacun de ses enfants, pièce par pièce.
struct DocumentsScreen: View {
    /// Le compte connecté (le parent).
    let profile: SessionProfile
    /// Données complémentaires : types de pièces, pièces, enfants.
    let store: ProfileExtrasStore

    /// Personne affichée ; `nil` : le membre lui-même.
    @State private var selectedHolder: UUID?

    /// Sélecteur de personne (s'il y a des enfants), puis les pièces de la
    /// personne choisie.
    var body: some View {
        let holders = store.holders(me: profile)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // « Moi », puis un segment par enfant (prénom).
                if holders.count > 1 {
                    Picker("Personne", selection: holderBinding) {
                        ForEach(holders) { Text($0.name).tag($0.profileId) }
                    }
                    .pickerStyle(.segmented)
                }

                // Personne choisie, ou la première si elle n'existe plus
                // (enfant retiré entre-temps).
                if let holder = holders.first(where: { $0.profileId == (selectedHolder ?? profile.id) }) ?? holders.first {
                    DocumentListCard(holder: holder, profile: profile, store: store)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationTitle(holders.count > 1 ? "Pièces de la famille" : "Mes pièces")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reloadDocuments(profile: profile) }
    }

    /// Lien du sélecteur : le membre lui-même tant que rien n'est choisi.
    private var holderBinding: Binding<UUID> {
        Binding(get: { selectedHolder ?? profile.id }, set: { selectedHolder = $0 })
    }
}

/// Les pièces d'une personne. Réutilisée dans la fiche d'un enfant.
struct DocumentListCard: View {
    /// La personne dont on affiche les pièces.
    let holder: DocumentHolder
    /// Le compte connecté (club du dépôt, relecture).
    let profile: SessionProfile
    /// Données complémentaires : types de pièces et pièces.
    let store: ProfileExtrasStore

    /// Type de pièce dont la feuille de dépôt est ouverte.
    @State private var uploadingType: DocumentType?
    /// Pièce dont la suppression attend confirmation.
    @State private var documentToDelete: MemberDocument?
    /// Refus ou échec de la suppression.
    @State private var errorMessage: String?

    /// Une ligne par type de pièce demandé, l'erreur éventuelle, la feuille de
    /// dépôt et la confirmation de suppression.
    var body: some View {
        let lines = store.lines(for: holder)

        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                ProfileCardHeader(title: holder.isMe ? "Mes pièces" : "Pièces de \(holder.name)")

                // Aucune pièce ne concerne cette personne (filtre d'âge).
                if lines.isEmpty {
                    Text("Aucune pièce demandée pour \(holder.isMe ? "vous" : holder.name).")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }

                ForEach(lines, id: \.type.id) { line in
                    row(type: line.type, document: line.document)
                    if line.type.id != lines.last?.type.id { Divider().opacity(0.4) }
                }

                if let errorMessage {
                    InlineMessage(kind: .error, message: errorMessage)
                }
            }
        }
        // Dépôt ou remplacement, puis relecture des pièces.
        .sheet(item: $uploadingType) { type in
            UploadPieceSheet(type: type, holder: holder, profile: profile) {
                await store.reloadDocuments(profile: profile)
            }
        }
        // Confirmation de suppression d'une pièce non validée.
        .confirmationDialog(
            "Supprimer cette pièce ?",
            isPresented: Binding(get: { documentToDelete != nil }, set: { if !$0 { documentToDelete = nil } }),
            titleVisibility: .visible,
            presenting: documentToDelete
        ) { document in
            Button("Supprimer", role: .destructive) { delete(document) }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Le fichier sera effacé. Vous pourrez en déposer un autre.")
        }
    }

    /// Ligne d'un type de pièce : libellé, mention (compétition ou
    /// facultatif), pastille d'état, motif de refus, nom du fichier et date de
    /// fin de validité, puis « Déposer » ou « Remplacer » et « Supprimer ».
    /// - Parameters:
    ///   - type: le type de pièce demandé.
    ///   - document: la pièce en cours, ou `nil` si aucune n'est déposée.
    /// - Returns: la ligne.
    private func row(type: DocumentType, document: MemberDocument?) -> some View {
        let state = DocumentState(document: document)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.libelle)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    // Pièce de compétiteur, ou pièce facultative.
                    if type.concerne == .competiteurs {
                        Text("Si vous jouez en compétition").font(.caption).foregroundStyle(Brand.textSecondary)
                    } else if !type.obligatoire {
                        Text("Facultatif").font(.caption).foregroundStyle(Brand.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                BrandChip(title: state.label, tint: tint(state))
                    .fixedSize()
            }

            // Pièce refusée par le club, avec son motif s'il a été donné.
            if case .refused(let reason?) = state {
                Text("Motif : \(reason)").font(.caption).foregroundStyle(Brand.error)
            }

            if let document {
                // Le nom du fichier, jamais son contenu : pas d'aperçu ici.
                Text([document.nomFichier,
                      document.dateExpiration.map { "valable jusqu'au \($0.shortFrenchDate)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Actions : déposer (ou remplacer, ce qui marque l'ancienne pièce
            // comme remplacée), et supprimer tant que la pièce n'est pas
            // validée.
            HStack(spacing: 14) {
                Button(document == nil ? "Déposer" : "Remplacer") {
                    uploadingType = type
                }
                if let document, document.isDeletable {
                    Button("Supprimer", role: .destructive) { documentToDelete = document }
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Brand.navy700)
        }
    }

    /// Couleur de la pastille d'état.
    /// - Parameter state: état de la pièce.
    /// - Returns: vert (à jour), bleu marine (en vérification), orange (à
    ///   déposer, expire bientôt), rouge (expirée, refusée).
    private func tint(_ state: DocumentState) -> Color {
        switch state {
        case .valid: Brand.success
        case .pending: Brand.navy700
        case .expiringSoon, .missing: Brand.warning
        case .expired, .refused: Brand.error
        }
    }

    /// Supprime une pièce non validée (ligne puis fichier), puis relit les
    /// pièces ; un refus (pièce validée entre-temps) s'affiche dans la carte.
    /// - Parameter document: la pièce à supprimer.
    private func delete(_ document: MemberDocument) {
        errorMessage = nil
        Task {
            do {
                try await MemberDocumentsService.delete(document)
                Haptics.destructive()
                await store.reloadDocuments(profile: profile)
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
        }
    }
}

// MARK: - Dépôt

/// Le seul écran où le fichier se voit en aperçu, sensible ou non.
///
/// L'aperçu est celui du fichier choisi sur l'appareil, avant l'envoi : rien
/// n'est relu depuis le serveur.
struct UploadPieceSheet: View {
    /// Type de pièce à déposer.
    let type: DocumentType
    /// Personne concernée (le membre ou un enfant).
    let holder: DocumentHolder
    /// Le compte connecté (club du dépôt).
    let profile: SessionProfile
    /// Appelée après un dépôt réussi, avant la fermeture (relecture).
    let onDeposited: () async -> Void

    /// Fermeture de la feuille.
    @Environment(\.dismiss) private var dismiss

    /// Photo choisie dans la photothèque, en attente de lecture.
    @State private var pickedPhoto: PhotosPickerItem?
    /// Sélecteur de photos ouvert.
    @State private var showsLibrary = false
    /// Appareil photo ouvert.
    @State private var showsCamera = false
    /// Sélecteur de fichiers (app Fichiers) ouvert.
    @State private var showsFiles = false

    /// Contenu du fichier retenu.
    @State private var fileData: Data?
    /// Nom du fichier, enregistré avec la pièce.
    @State private var fileName = ""
    /// Type MIME du fichier (`application/pdf`, `image/jpeg`...).
    @State private var mimeType = ""
    /// Aperçu d'une image, ou `nil` pour un PDF.
    @State private var previewImage: UIImage?

    /// Interrupteur « Indiquer la date du document ».
    @State private var hasDocumentDate = false
    /// Date portée sur la pièce, au plus aujourd'hui.
    @State private var documentDate = Date.now
    /// Envoi en cours.
    @State private var isSending = false
    /// Message d'erreur affiché dans le formulaire.
    @State private var errorMessage: String?

    /// Formulaire : pièce visée, fichier et ses trois sources, date du
    /// document, erreur, consignes ; « Annuler » et « Envoyer » dans la barre.
    var body: some View {
        NavigationStack {
            Form {
                // Pièce visée, et pour qui.
                Section {
                    Text(type.libelle).font(.headline)
                    if !holder.isMe {
                        Text("Pour \(holder.name)").font(.footnote).foregroundStyle(Brand.textSecondary)
                    }
                }

                // Fichier retenu (aperçu d'image ou nom du PDF), puis les
                // sources ; l'appareil photo seulement s'il existe (pas dans le
                // simulateur).
                Section("Fichier") {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(.rect(cornerRadius: 12))
                    } else if fileData != nil {
                        Label(fileName, systemImage: "doc.richtext")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Prendre une photo", systemImage: "camera") { showsCamera = true }
                    }
                    Button("Choisir dans la photothèque", systemImage: "photo.on.rectangle") { showsLibrary = true }
                    Button("Choisir un PDF dans Fichiers", systemImage: "folder") { showsFiles = true }
                }

                // Date du document, facultative : sans elle, `deposer_piece`
                // compte la validité à partir du jour du dépôt.
                Section {
                    Toggle("Indiquer la date du document", isOn: $hasDocumentDate.animation())
                    if hasDocumentDate {
                        DatePicker("Date du document", selection: $documentDate, in: ...Date.now, displayedComponents: .date)
                    }
                } footer: {
                    Text("La date figurant sur la pièce, une attestation datée du 3 mars par exemple. Le club en déduit la date d'expiration.")
                }

                if let errorMessage {
                    Section { InlineMessage(kind: .error, message: errorMessage) }
                }

                Section {
                    Text("PDF, JPEG, PNG ou HEIC, 10 Mo au plus. Le club vérifie la pièce avant de la valider.")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .navigationTitle("Déposer une pièce")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                // « Envoyer » dès qu'un fichier est retenu ; indicateur
                // d'activité pendant l'envoi.
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Envoyer") { send() }
                            .disabled(fileData == nil)
                    }
                }
            }
            // Les trois sources : photothèque, Fichiers (PDF ou image), et
            // appareil photo en plein écran (photo réencodée en JPEG à 85 %).
            .photosPicker(isPresented: $showsLibrary, selection: $pickedPhoto, matching: .images)
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.pdf, .jpeg, .png, .heic]) { result in
                importFile(result)
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { image in
                    guard let image, let data = image.jpegData(compressionQuality: 0.85) else { return }
                    setFile(data: data, name: "photo-\(Int(Date.now.timeIntervalSince1970)).jpg", mime: "image/jpeg", preview: image)
                }
                .ignoresSafeArea()
            }
            // Photo choisie : lecture et conversion éventuelle.
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
        }
        // Pas de fermeture par glissement pendant l'envoi.
        .interactiveDismissDisabled(isSending)
    }

    // MARK: - Sources

    /// Retient un fichier, s'il ne dépasse pas 10 Mo.
    /// - Parameters:
    ///   - data: contenu du fichier.
    ///   - name: nom enregistré avec la pièce.
    ///   - mime: type MIME.
    ///   - preview: image d'aperçu, ou `nil` pour un PDF.
    private func setFile(data: Data, name: String, mime: String, preview: UIImage?) {
        errorMessage = nil
        guard data.count <= MemberDocumentsService.maxPieceBytes else {
            errorMessage = "Le fichier dépasse 10 Mo."
            return
        }
        fileData = data
        fileName = name
        mimeType = mime
        previewImage = preview
    }

    /// Lit une photo de la photothèque et la retient, telle quelle ou
    /// convertie en JPEG.
    ///
    /// Limite connue : si la lecture échoue, la sélection n'est pas remise à
    /// zéro ; choisir à nouveau la même photo ne relance alors pas la lecture.
    /// - Parameter item: la photo choisie.
    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Cette photo n'a pas pu être lue."
            return
        }
        let original = item.supportedContentTypes.first
        // HEIC, JPEG et PNG partent tels quels ; tout autre format (WebP…) est
        // converti en JPEG, que le club sait lire.
        if let original, let mime = MemberDocumentsService.mimeType(for: original) {
            let ext = original.preferredFilenameExtension ?? "jpg"
            setFile(data: data, name: "photo.\(ext)", mime: mime, preview: UIImage(data: data))
        } else if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
            setFile(data: jpeg, name: "photo.jpg", mime: "image/jpeg", preview: image)
        } else {
            errorMessage = "Format d'image non pris en charge."
        }
        // Remise à zéro : choisir à nouveau la même photo relancera la lecture.
        pickedPhoto = nil
    }

    /// Lit un fichier choisi dans Fichiers ; le type MIME vient de l'extension
    /// du nom. Une annulation ne fait rien.
    /// - Parameter result: l'adresse du fichier choisi, ou l'erreur du
    ///   sélecteur.
    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        // Accès temporaire au fichier hors du bac à sable de l'app, rendu à la
        // sortie de la fonction.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let type = UTType(filenameExtension: url.pathExtension),
              let mime = MemberDocumentsService.mimeType(for: type)
        else {
            errorMessage = "Ce fichier n'a pas pu être lu. Formats acceptés : PDF, JPEG, PNG et HEIC."
            return
        }
        setFile(data: data, name: url.lastPathComponent, mime: mime, preview: type.conforms(to: .image) ? UIImage(data: data) : nil)
    }

    // MARK: - Envoi

    /// Envoie le fichier puis enregistre la pièce (voir l'en-tête du fichier),
    /// au nom de la personne choisie ; en cas de succès, relecture puis
    /// fermeture, sinon message dans le formulaire.
    private func send() {
        guard let fileData else { return }
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await MemberDocumentsService.deposit(
                    data: fileData,
                    fileName: fileName,
                    mimeType: mimeType,
                    type: type,
                    profileId: holder.profileId,
                    clubId: profile.clubId,
                    documentDate: hasDocumentDate ? documentDate : nil
                )
                Haptics.success()
                await onDeposited()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.failure()
            }
            isSending = false
        }
    }
}

// MARK: - Appareil photo

/// `UIImagePickerController` en mode appareil photo : SwiftUI n'a pas
/// d'équivalent natif.
///
/// L'accès à l'appareil photo est demandé par iOS à la première ouverture, avec
/// le texte NSCameraUsageDescription des réglages du projet.
struct CameraPicker: UIViewControllerRepresentable {
    /// Appelée avec la photo prise, ou `nil` si l'utilisateur annule.
    let onFinish: (UIImage?) -> Void

    /// Crée le contrôleur UIKit, réglé sur l'appareil photo.
    /// - Parameter context: contexte SwiftUI, qui porte le coordinateur.
    /// - Returns: le contrôleur.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    /// Rien à mettre à jour : le contrôleur n'a aucun état venu de SwiftUI.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    /// Crée le délégué qui reçoit la photo.
    /// - Returns: le coordinateur.
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    /// Délégué UIKit du contrôleur : transmet la photo (ou l'annulation) et
    /// referme l'appareil photo.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        /// Rappel fourni par la vue.
        let onFinish: (UIImage?) -> Void

        /// - Parameter onFinish: rappel à appeler avec la photo ou `nil`.
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        /// Photo prise : l'image d'origine est transmise, puis l'appareil se
        /// ferme.
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
            picker.dismiss(animated: true)
        }

        /// Annulation : `nil` est transmis, puis l'appareil se ferme.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
            picker.dismiss(animated: true)
        }
    }
}
