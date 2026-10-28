//
//  DocumentsSection.swift
//  iClub
//
//  « Mes pièces » : ce que le club demande, pour le membre et pour chacun de
//  ses enfants, et l'état de chaque pièce — même vocabulaire que le web.
//
//  Une pièce sensible (attestation de santé) n'est jamais affichée en aperçu
//  ailleurs que dans l'écran de dépôt.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Dans le profil, une seule ligne qui résume l'état des pièces et mène à
/// l'écran complet.
struct DocumentsSection: View {
    let profile: SessionProfile
    let store: ProfileExtrasStore

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
    private var states: [DocumentState] {
        store.holders(me: profile).flatMap { holder in
            store.lines(for: holder)
                .filter { $0.type.concerne != .competiteurs || $0.document != nil }
                .filter { $0.type.obligatoire || $0.document != nil }
                .map { DocumentState(document: $0.document) }
        }
    }

    private var needsAttention: Bool {
        states.contains { state in
            switch state {
            case .missing, .expired, .refused, .expiringSoon: true
            case .pending, .valid: false
            }
        }
    }

    /// « 2 à déposer · 1 en cours de vérification », ou « Tout est à jour ».
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
    let profile: SessionProfile
    let store: ProfileExtrasStore

    @State private var selectedHolder: UUID?

    var body: some View {
        let holders = store.holders(me: profile)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if holders.count > 1 {
                    Picker("Personne", selection: holderBinding) {
                        ForEach(holders) { Text($0.name).tag($0.profileId) }
                    }
                    .pickerStyle(.segmented)
                }

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

    private var holderBinding: Binding<UUID> {
        Binding(get: { selectedHolder ?? profile.id }, set: { selectedHolder = $0 })
    }
}

/// Les pièces d'une personne. Réutilisée dans la fiche d'un enfant.
struct DocumentListCard: View {
    let holder: DocumentHolder
    let profile: SessionProfile
    let store: ProfileExtrasStore

    @State private var uploadingType: DocumentType?
    @State private var documentToDelete: MemberDocument?
    @State private var errorMessage: String?

    var body: some View {
        let lines = store.lines(for: holder)

        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                ProfileCardHeader(title: holder.isMe ? "Mes pièces" : "Pièces de \(holder.name)")

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
        .sheet(item: $uploadingType) { type in
            UploadPieceSheet(type: type, holder: holder, profile: profile) {
                await store.reloadDocuments(profile: profile)
            }
        }
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

    private func row(type: DocumentType, document: MemberDocument?) -> some View {
        let state = DocumentState(document: document)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.libelle)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
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

    private func tint(_ state: DocumentState) -> Color {
        switch state {
        case .valid: Brand.success
        case .pending: Brand.navy700
        case .expiringSoon, .missing: Brand.warning
        case .expired, .refused: Brand.error
        }
    }

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
struct UploadPieceSheet: View {
    let type: DocumentType
    let holder: DocumentHolder
    let profile: SessionProfile
    let onDeposited: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showsLibrary = false
    @State private var showsCamera = false
    @State private var showsFiles = false

    @State private var fileData: Data?
    @State private var fileName = ""
    @State private var mimeType = ""
    @State private var previewImage: UIImage?

    @State private var hasDocumentDate = false
    @State private var documentDate = Date.now
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(type.libelle).font(.headline)
                    if !holder.isMe {
                        Text("Pour \(holder.name)").font(.footnote).foregroundStyle(Brand.textSecondary)
                    }
                }

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
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Envoyer") { send() }
                            .disabled(fileData == nil)
                    }
                }
            }
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
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    // MARK: - Sources

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
        pickedPhoto = nil
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
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
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
            picker.dismiss(animated: true)
        }
    }
}
