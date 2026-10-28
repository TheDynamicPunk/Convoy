import SwiftUI
import AppKit
import DownloadEngine
import UniformTypeIdentifiers

/// Short local name for the folder category type, used throughout this file.
private typealias Category = DownloadCategory

/// Settings → Downloads → Save in Folders.
///
/// Sections, not a screen: they sit inside the Downloads form (a Form cannot
/// contain another Form), right after the download location. A
/// master toggle comes first; the rules and the Try It field below it stay in
/// place and are greyed out, and inert, while it is off. Each rule is a
/// folder plus the file types and sites that go into it. The sheet shares
/// its header, card and footer layout with NewDownloadView and
/// DuplicateDownloadSheet.
///
/// Wording: people see "rules" and "save in folders". The types underneath
/// keep the name DownloadCategory; renaming them would touch the engine and
/// every test for no visible gain.
struct SaveInFoldersSections: View {
    @EnvironmentObject var settings: AppSettings
    @State private var editorTarget: EditorTarget? = nil
    @State private var showingResetConfirmation = false
    @State private var tryItInput = ""
    /// The drag in progress, if any, recorded when a row is picked up. It lets
    /// the drop move the rows the instant it happens, and tells the drop line
    /// which way the row is travelling. See ActiveDrag.
    @State private var activeDrag: ActiveDrag?
    @State private var dropTargetID: UUID?

    private enum EditorTarget: Identifiable {
        case add
        case edit(Category)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let category): return category.id.uuidString
            }
        }
    }

    private var duplicateWarnings: [CategoryRouter.DuplicateExtension] {
        CategoryRouter.duplicateExtensions(in: settings.downloadCategories)
    }

    /// True when the list is anything other than the original set. Compared
    /// whole (ids, folders, extensions, switches): the original categories
    /// have fixed ids, so an unchanged list really is equal to them. Reset is
    /// disabled when there is nothing to reset.
    private var differsFromDefaults: Bool {
        settings.downloadCategories != Category.suggestedCategories(in: settings.downloadDirectory)
    }

    var body: some View {
        Section {
            Toggle("Automatically save into folders", isOn: $settings.downloadCategoriesEnabled)
                // The confirmation and the editor sheet hang off this row, which
                // is always live. The rows below are greyed out and inert while
                // the switch is off, and a presentation should not hang off
                // something the person cannot currently touch.
                .confirmationDialog(
                    "Reset rules to defaults?",
                    isPresented: $showingResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset to Defaults", role: .destructive) {
                        settings.resetCategoriesToDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This replaces all of your rules with the original set, including any you added or changed. Files already saved stay where they are.")
                }
                .sheet(item: $editorTarget) { target in
                    CategoryEditorSheet(
                        existing: {
                            if case .edit(let category) = target { return category }
                            return nil
                        }(),
                        defaultBaseFolder: settings.downloadDirectory,
                        otherCategories: settings.downloadCategories.filter {
                            if case .edit(let category) = target { return $0.id != category.id }
                            return true
                        },
                        onSave: { saved in
                            saveCategory(saved)
                        }
                    )
                }
        } header: {
            Text("Save in Folders")
        } footer: {
            Text("Saves each download in the folder of the first rule that matches its file type or site.")
        }

        // These stay where they are whether or not the switch is on, greyed
        // out and inert while it is off. Hiding them shifted the layout under
        // the person's cursor and, in a window this short, put the result of
        // turning the switch on out of sight below the fold.
        Section {
            Group {
                if settings.downloadCategories.isEmpty {
                    emptyStateRow
                } else {
                    categoryList

                    ForEach(duplicateWarnings) { warning in
                        DuplicateExtensionWarningRow(warning: warning)
                    }

                    HStack(spacing: 10) {
                        Button("Add Rule…") {
                            editorTarget = .add
                        }

                        Spacer()

                        Button("Reset to Defaults…") {
                            showingResetConfirmation = true
                        }
                        .disabled(!differsFromDefaults)
                    }
                    .padding(.vertical, 2)
                }
            }
            .greyedOut(!settings.downloadCategoriesEnabled)
        } header: {
            Text("Rules")
                .greyedOut(!settings.downloadCategoriesEnabled)
        } footer: {
            Text("Checked from top to bottom; drag to reorder. A folder you choose yourself always wins.")
                .greyedOut(!settings.downloadCategoriesEnabled)
        }

        if !settings.downloadCategories.isEmpty {
            Section {
                Group {
                    TextField(
                        "Filename or link",
                        text: $tryItInput,
                        prompt: Text("Paste a filename or link, e.g. song.mp3")
                    )
                    if let outcome = tryItOutcome {
                        tryItResultRow(outcome)
                    }
                }
                .greyedOut(!settings.downloadCategoriesEnabled)
            } header: {
                Text("Try It")
                    .greyedOut(!settings.downloadCategoriesEnabled)
            } footer: {
                Text("Links without a file extension are named by the server, so the real result can differ.")
                    .greyedOut(!settings.downloadCategoriesEnabled)
            }
        }
    }

    private var emptyStateRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("No rules yet")
                    .font(.body)
                Text("Restore the original folders for Music, Video, Documents, Books, Archives, Programs and Images, or add your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Add Rule…") {
                editorTarget = .add
            }
            Button("Restore Defaults") {
                settings.resetCategoriesToDefaults()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    private enum TryItOutcome {
        case routed(CategoryRoute)
        case noMatch
    }

    /// What the Try It field says about what was typed, using the same
    /// decision real downloads use. Nil while the field is empty.
    private var tryItOutcome: TryItOutcome? {
        let trimmed = tryItInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let route = CategoryPreview.route(for: trimmed, in: settings.downloadCategories) {
            return .routed(route)
        }
        return .noMatch
    }

    @ViewBuilder
    private func tryItResultRow(_ outcome: TryItOutcome) -> some View {
        switch outcome {
        case .routed(let route):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Goes to \(route.category.name)")
                    Text(abbreviateHome(route.category.folder.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .noMatch:
            Label {
                Text("No rule matches, so it stays in \(FileManager.default.displayName(atPath: settings.downloadDirectory)).")
            } icon: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The rows, laid out here rather than handed to the Form one by one.
    ///
    /// A Form pads each row it owns by an amount it does not expose, so a drop
    /// line drawn at a row's edge landed inside that padding, cutting through
    /// the row's text with the row's separator a few points lower. Owning the
    /// layout means owning the edges: each row carries its own padding, the
    /// separators sit exactly between rows, and the drop line is drawn on the
    /// same boundary, over the separator it replaces.
    private var categoryList: some View {
        let categories = settings.downloadCategories
        let starters = starterIDs
        return VStack(spacing: 0) {
            ForEach(categories) { category in
                CategoryRow(
                    category: category,
                    defaultDownloadsFolder: settings.downloadDirectory,
                    onEdit: { editorTarget = .edit(category) },
                    onDelete: { deleteCategory(id: category.id) },
                    canMoveUp: CategoryOrdering.canMove(category.id, .up, in: categories),
                    canMoveDown: CategoryOrdering.canMove(category.id, .down, in: categories),
                    onMoveUp: { moveCategory(id: category.id, .up) },
                    onMoveDown: { moveCategory(id: category.id, .down) },
                    isStarter: starters.contains(category.id),
                    dropIndicator: dropIndicator(for: category.id)
                )
                .onDrag {
                    activeDrag = ActiveDrag(id: category.id, startedAt: Date())
                    return NSItemProvider(object: category.id.uuidString as NSString)
                }
                .onDrop(
                    of: [UTType.plainText],
                    delegate: CategoryDropDelegate(
                        targetID: category.id,
                        activeDrag: $activeDrag,
                        dropTargetID: $dropTargetID,
                        onMove: { dragged, target in dropCategory(dragged, onto: target) }
                    )
                )

                if category.id != categories.last?.id {
                    // No fade: as rows trade places, which row is last changes,
                    // and a separator fading in and out under a moving row
                    // reads as a ghost.
                    Divider()
                        .transition(.identity)
                }
            }
        }
    }

    /// Which edge of `id`'s row the drop line belongs on while a drag is over
    /// it. Nil when nothing is being dragged over this row, or when dropping
    /// there would change nothing.
    private func dropIndicator(for id: UUID) -> CategoryOrdering.DropSide? {
        guard let dragging = activeDrag?.id, dropTargetID == id else { return nil }
        return CategoryOrdering.dropSide(of: dragging, onto: id, in: settings.downloadCategories)
    }

    /// Not animated here: the drop delegate animates the move together with
    /// clearing the drop line, as one change, so the line and the rows settle
    /// in the same motion instead of one after the other.
    private func dropCategory(_ id: UUID, onto targetID: UUID) {
        settings.downloadCategories = CategoryOrdering.moved(
            id, onto: targetID, in: settings.downloadCategories
        )
    }

    /// Ids of the original categories, so a deletion can say whether Reset to
    /// Defaults would bring the category back.
    private var starterIDs: Set<UUID> {
        Set(Category.suggestedCategories(in: settings.downloadDirectory).map(\.id))
    }

    private func moveCategory(id: UUID, _ direction: CategoryOrdering.Direction) {
        withAnimation(.easeOut(duration: 0.2)) {
            settings.downloadCategories = CategoryOrdering.moved(
                id, direction, in: settings.downloadCategories
            )
        }
    }

    private func deleteCategory(id: UUID) {
        settings.downloadCategories = settings.downloadCategories.filter { $0.id != id }
    }

    private func saveCategory(_ saved: Category) {
        var list = settings.downloadCategories
        if let idx = list.firstIndex(where: { $0.id == saved.id }) {
            list[idx] = saved
        } else {
            list.append(saved)
        }
        settings.downloadCategories = list
    }
}

// MARK: - Button feel

/// The look of every button in a category row. The stock `.borderless` and
/// `.link` styles give almost no feedback on macOS (no hover, barely any
/// press), so a button read as plain text rather than something to click.
/// This one answers the pointer at every stage: a soft highlight on hover, a
/// deeper one with a slight press-in while held, and a dimmed look when
/// disabled. `hoverTint` recolours the icon, and the highlight behind it, as
/// the pointer arrives: red for the destructive action so the consequence
/// shows before the click, the accent colour for Edit.
private struct RowButtonStyle: ButtonStyle {
    var tint: Color = .secondary
    var hoverTint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, tint: tint, hoverTint: hoverTint)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let hoverTint: Color?

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        guard isEnabled else { return tint.opacity(0.4) }
        if isHovering || configuration.isPressed { return hoverTint ?? tint }
        return tint
    }

    private var highlight: Color {
        guard isEnabled else { return .clear }
        let base = hoverTint ?? Color.primary
        if configuration.isPressed { return base.opacity(0.18) }
        return isHovering ? base.opacity(0.10) : .clear
    }

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 30, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlight)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Drag to reorder

/// A drag that began on one of these rows.
///
/// SwiftUI never reports a cancelled drag, so a record like this can outlive
/// its drag. A real drop follows the pick-up within seconds, so the record is
/// trusted for a generous bound and not beyond it; past that, the dropped
/// item itself is asked who it is (the slower path in CategoryDropDelegate).
private struct ActiveDrag: Equatable {
    let id: UUID
    let startedAt: Date

    var isFresh: Bool { Date().timeIntervalSince(startedAt) < 120 }
}

/// Receives a category row dragged onto another row.
///
/// The move is applied the moment the drop happens, using the record made at
/// pick-up. An earlier version always asked the dropped item for its identity
/// and moved the rows when the answer arrived. That answer is asynchronous
/// and, during a drag, can take most of a second, so the drop line vanished,
/// the drag image lingered over the target, and only then did the rows move.
/// The item is still consulted, but only when there is no fresh record (see
/// ActiveDrag), so a drop that did not start here still cannot move anything.
private struct CategoryDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var activeDrag: ActiveDrag?
    @Binding var dropTargetID: UUID?
    let onMove: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        if let drag = activeDrag, drag.id != targetID { dropTargetID = targetID }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        // The ordinary case: this drag started on one of these rows.
        if let drag = activeDrag, drag.isFresh {
            guard drag.id != targetID else {
                clear()
                return false
            }
            commit(drag.id)
            return true
        }

        // No fresh record: ask the dropped item who it is. Slower, and the
        // drop line stays until the answer arrives so it does not just vanish.
        guard let provider = info.itemProviders(for: [.plainText]).first else {
            clear()
            return false
        }
        let finish = self
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                guard let text = object as? NSString,
                      let dragged = UUID(uuidString: text as String) else {
                    finish.clear()
                    return
                }
                finish.commit(dragged)
            }
        }
        return true
    }

    /// The move and the clearing of the drop line as ONE animated change, so
    /// they settle together.
    private func commit(_ dragged: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            onMove(dragged, targetID)
            activeDrag = nil
            dropTargetID = nil
        }
    }

    private func clear() {
        activeDrag = nil
        dropTargetID = nil
    }
}

// MARK: - Row

private struct CategoryRow: View {
    let category: Category
    let defaultDownloadsFolder: String
    let onEdit: () -> Void
    let onDelete: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    /// Whether Reset to Defaults would bring this category back; only used
    /// to word the delete confirmation honestly.
    let isStarter: Bool
    /// The edge to draw the drop line on while a row is being dragged over
    /// this one; nil the rest of the time.
    let dropIndicator: CategoryOrdering.DropSide?

    @State private var showingDeleteConfirmation = false

    private var style: CategoryVisualStyle {
        CategoryVisualStyle.forName(category.name)
    }

    var body: some View {
        // An explicit HStack rather than LabeledContent: these rows are laid
        // out by SaveInFoldersSections itself (see categoryList), outside the
        // Form's own row layout, so the alignment is spelled out here instead
        // of inherited.
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                // Says the row can be dragged. Quiet on purpose; the whole row
                // is the drag target, this just makes it discoverable.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help("Drag to change the order. Rules nearer the top are checked first.")
                    .accessibilityHidden(true)

                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(style.tint.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: style.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .font(.body)

                    Text(criteriaSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if !usesOrdinaryFolder {
                    customFolderNote
                }

                // An icon like the trash beside it. "Adjust" rather than a
                // pencil: the editor changes several things at once (name,
                // folder, file types, sites), a bare pencil read as a stray
                // slash, and Apple's pencil-in-a-square means "compose".
                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14))
                }
                .buttonStyle(RowButtonStyle(tint: .secondary, hoverTint: .accentColor))
                .help("Edit \(category.name)")
                .accessibilityLabel("Edit \(category.name)")

                // Always visible, not tucked into the edit dialog or a
                // right-click menu. Asks before deleting, and turns red as
                // the pointer arrives.
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }
                .buttonStyle(RowButtonStyle(tint: .secondary, hoverTint: .red))
                .help("Delete \(category.name)")
                .accessibilityLabel("Delete \(category.name)")
            }
        }
        .padding(.vertical, 12)
        // The drop line sits on the boundary between two rows, centred on the
        // separator that is there and 2 points thick, so it replaces the
        // separator instead of floating inside the row.
        .overlay(alignment: dropIndicator == .above ? .top : .bottom) {
            if let side = dropIndicator {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: side == .above ? -1 : 1)
                    .allowsHitTesting(false)
            }
        }
        // Dragging cannot be done from a keyboard or with VoiceOver, so the
        // same moves are offered here and as accessibility actions.
        .accessibilityAction(named: "Move up") { if canMoveUp { onMoveUp() } }
        .accessibilityAction(named: "Move down") { if canMoveDown { onMoveDown() } }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Move Up", action: onMoveUp)
                .disabled(!canMoveUp)
            Button("Move Down", action: onMoveDown)
                .disabled(!canMoveDown)
            Button("Show Folder in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: category.folder.path)
            }
            Divider()
            Button("Delete…", role: .destructive) {
                showingDeleteConfirmation = true
            }
        }
        .confirmationDialog(
            "Delete “\(category.name)”?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
        // Above its neighbours while it carries the drop line, so the line is
        // not painted over by the separator that sits just beneath it.
        .zIndex(dropIndicator == nil ? 0 : 1)
    }

    /// True when the folder is simply "<Downloads>/<this category's name>",
    /// which is what every original category uses. Showing it on every row
    /// repeated the category's own name beside it ("Video" next to "Video");
    /// the folder is only worth a line of its own when it is somewhere else.
    private var usesOrdinaryFolder: Bool {
        let base = URL(
            fileURLWithPath: (defaultDownloadsFolder as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        let ordinary = base.appendingPathComponent(category.name, isDirectory: true)
        return category.folder.standardizedFileURL.path == ordinary.standardizedFileURL.path
    }

    /// Plain text, no pill: it only appears for the exceptions, and a gray
    /// box around it would make an exception look like a control.
    private var customFolderNote: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(conciseFolderLabel)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 170, alignment: .trailing)
        .help(abbreviateHome(category.folder.path))
    }

    private var deletionMessage: String {
        let kept = "Files already saved in its folder stay where they are."
        return isStarter
            ? "\(kept) You can bring it back with Reset to Defaults."
            : "\(kept) This can’t be undone."
    }

    private var conciseFolderLabel: String {
        let folderURL = category.folder.standardizedFileURL
        let baseURL = URL(
            fileURLWithPath: (defaultDownloadsFolder as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        if folderURL.deletingLastPathComponent() == baseURL {
            return folderURL.lastPathComponent
        }
        return abbreviateHome(folderURL.path)
    }

    private var criteriaSummary: String {
        var parts: [String] = []
        if !category.extensions.isEmpty {
            let previewLimit = 6
            let head = category.extensions.prefix(previewLimit).joined(separator: ", ")
            let remaining = category.extensions.count - previewLimit
            parts.append(remaining > 0 ? "\(head) +\(remaining) more" : head)
        }
        if !category.sitePatterns.isEmpty {
            let sites = category.sitePatterns.joined(separator: ", ")
            parts.append("from \(sites)")
        }
        return parts.isEmpty ? "No extensions or sites" : parts.joined(separator: " · ")
    }
}

private struct CategoryVisualStyle {
    let icon: String
    let tint: Color

    static func forName(_ rawName: String) -> CategoryVisualStyle {
        switch rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "music", "audio":
            return CategoryVisualStyle(icon: "waveform", tint: .pink)
        case "video", "videos", "movies":
            return CategoryVisualStyle(icon: "film", tint: .purple)
        case "documents", "docs":
            return CategoryVisualStyle(icon: "doc.text.fill", tint: .blue)
        case "books", "ebooks":
            return CategoryVisualStyle(icon: "book.closed.fill", tint: .indigo)
        case "archives", "compressed":
            return CategoryVisualStyle(icon: "archivebox.fill", tint: .orange)
        case "programs", "apps", "software", "installers":
            return CategoryVisualStyle(icon: "shippingbox.fill", tint: .teal)
        case "images", "photos", "pictures":
            return CategoryVisualStyle(icon: "photo.fill", tint: .green)
        default:
            return CategoryVisualStyle(icon: "folder.fill", tint: .accentColor)
        }
    }
}

private struct DuplicateExtensionWarningRow: View {
    let warning: CategoryRouter.DuplicateExtension

    var body: some View {
        Label {
            Text(".\(warning.ext) is listed in both \(ListFormatter.localizedString(byJoining: warning.categoryNames)) — \(warning.categoryNames.first ?? "the first one") will take those files. Drag the rules to change the order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor sheet

private struct CategoryEditorSheet: View {
    let existing: Category?
    let defaultBaseFolder: String
    let otherCategories: [Category]
    let onSave: (Category) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var folderPath: String = ""
    @State private var extensions: [String] = []
    @State private var pendingExtensionInput: String = ""
    @State private var sitePatterns: [String] = []
    @State private var pendingSiteInput: String = ""

    /// Extensions including anything currently typed in the add box so
    /// clicking Save without pressing Return first still keeps what was typed.
    private var effectiveExtensions: [String] {
        var result = extensions
        for ext in Category.parseExtensions(pendingExtensionInput) where !result.contains(ext) {
            result.append(ext)
        }
        return result
    }

    private var effectiveSites: [String] {
        var result = sitePatterns
        for site in Category.parseSitePatterns(pendingSiteInput) where !result.contains(site) {
            result.append(site)
        }
        return result
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftCategory: Category {
        Category(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            folderPath: folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
            extensions: effectiveExtensions,
            sitePatterns: effectiveSites
        )
    }

    private var overlappingExtensions: [CategoryRouter.DuplicateExtension] {
        let previewList = otherCategories + [draftCategory]
        let draftExts = Set(effectiveExtensions)
        return CategoryRouter.duplicateExtensions(in: previewList)
            .filter { draftExts.contains($0.ext) }
    }

    private var overlappingExtensionSet: Set<String> {
        Set(overlappingExtensions.map(\.ext))
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && draftCategory.hasUsableFolder
            && (!effectiveExtensions.isEmpty || !effectiveSites.isEmpty)
    }

    private var headerStyle: CategoryVisualStyle {
        CategoryVisualStyle.forName(trimmedName.isEmpty ? (existing?.name ?? "") : trimmedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if let existing {
                name = existing.name
                folderPath = existing.folderPath
                extensions = existing.extensions
                sitePatterns = existing.sitePatterns
            } else {
                folderPath = defaultBaseFolder
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(headerStyle.tint.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: headerStyle.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(headerStyle.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(existing == nil ? "New Rule" : "Edit \(existing?.name ?? "Rule")")
                    .font(.system(size: 14, weight: .semibold))
                Text("Choose a destination folder and which downloads belong in it")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            // MARK: Rule Name & Folder
            VStack(alignment: .leading, spacing: 7) {
                sectionHeader("Rule", systemImage: "folder")
                card {
                    HStack(spacing: 12) {
                        Text("Name")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("e.g. Music", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .onChange(of: name) { oldName, newName in
                                guard existing == nil else { return }
                                let base = defaultBaseFolder.isEmpty
                                    ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? (NSHomeDirectory() + "/Downloads"))
                                    : defaultBaseFolder
                                let previousSuggested = URL(fileURLWithPath: base, isDirectory: true)
                                    .appendingPathComponent(oldName.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true).path
                                if folderPath.isEmpty || folderPath == base || folderPath == previousSuggested {
                                    let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    folderPath = clean.isEmpty
                                        ? base
                                        : URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(clean, isDirectory: true).path
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)

                    Divider().padding(.leading, 12)

                    HStack(spacing: 12) {
                        Text("Save to")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(abbreviateHome(folderPath))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folderPath)
                        Spacer(minLength: 8)
                        Button("Choose…") { chooseFolder() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                }
            }

            // MARK: File Extensions (Token chips + inline add)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    sectionHeader("File Extensions", systemImage: "doc.badge.gearshape")
                    Spacer()
                    if !extensions.isEmpty {
                        Text("\(extensions.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                card {
                    if !extensions.isEmpty {
                        extensionChipsView
                        Divider().padding(.leading, 12)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        TextField(
                            extensions.isEmpty
                                ? "Type extensions (e.g. mp3, flac, tar.gz) and press Return…"
                                : "Add extension (e.g. opus, tar.gz) and press Return…",
                            text: $pendingExtensionInput
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: pendingExtensionInput.isEmpty ? .default : .monospaced))
                        .onSubmit {
                            commitPendingExtensions()
                        }
                        .onChange(of: pendingExtensionInput) { _, newValue in
                            // Commit immediately when the user types a comma or space
                            // after a token, so typing "mp3, flac, " turns into chips live.
                            if newValue.contains(",") || newValue.hasSuffix(" ") {
                                commitCompletedTokens(from: newValue, isExtension: true)
                            }
                        }

                        if !Category.parseExtensions(pendingExtensionInput).isEmpty {
                            Button("Add") {
                                commitPendingExtensions()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)

                    if !overlappingExtensions.isEmpty {
                        ForEach(overlappingExtensions) { warning in
                            Divider().padding(.leading, 12)
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                                    .padding(.top, 1)
                                Text(".\(warning.ext) is already in \(ListFormatter.localizedString(byJoining: warning.categoryNames.filter { $0 != trimmedName })).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }

            // MARK: Sites (optional)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    sectionHeader("Sites (Optional)", systemImage: "globe")
                    Spacer()
                    Text("Leave empty for any site")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                card {
                    if !sitePatterns.isEmpty {
                        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(sitePatterns, id: \.self) { site in
                                TokenChip(
                                    label: site,
                                    isWarning: false,
                                    onRemove: { removeSite(site) }
                                )
                            }
                        }
                        .padding(10)

                        Divider().padding(.leading, 12)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        TextField(
                            "Restrict to domain (e.g. example.com or *.cdn.org)…",
                            text: $pendingSiteInput
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: pendingSiteInput.isEmpty ? .default : .monospaced))
                        .onSubmit {
                            commitPendingSites()
                        }
                        .onChange(of: pendingSiteInput) { _, newValue in
                            if newValue.contains(",") || newValue.hasSuffix(" ") {
                                commitCompletedTokens(from: newValue, isExtension: false)
                            }
                        }

                        if !Category.parseSitePatterns(pendingSiteInput).isEmpty {
                            Button("Add") {
                                commitPendingSites()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// Wrapping grid of extension chips. Expands naturally for typical
    /// categories (1–4 rows) and scrolls with visible scrollbars if someone
    /// adds dozens of extensions.
    @ViewBuilder
    private var extensionChipsView: some View {
        let chipGrid = FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(extensions, id: \.self) { ext in
                TokenChip(
                    label: "." + ext,
                    isWarning: overlappingExtensionSet.contains(ext),
                    onRemove: { removeExtension(ext) }
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)

        if extensions.count > 18 {
            ScrollView {
                chipGrid
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 136)
        } else {
            chipGrid
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Add" : "Save") {
                onSave(draftCategory)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Token actions

    private func commitPendingExtensions() {
        let parsed = Category.parseExtensions(pendingExtensionInput)
        guard !parsed.isEmpty else {
            pendingExtensionInput = ""
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            for ext in parsed where !extensions.contains(ext) {
                extensions.append(ext)
            }
            pendingExtensionInput = ""
        }
    }

    private func commitPendingSites() {
        let parsed = Category.parseSitePatterns(pendingSiteInput)
        guard !parsed.isEmpty else {
            pendingSiteInput = ""
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            for site in parsed where !sitePatterns.contains(site) {
                sitePatterns.append(site)
            }
            pendingSiteInput = ""
        }
    }

    private func commitCompletedTokens(from raw: String, isExtension: Bool) {
        let endsWithDelimiter = raw.last.map { $0 == "," || $0.isWhitespace } ?? false
        let parts = raw.split(omittingEmptySubsequences: false) { $0 == "," || $0.isWhitespace }
        let completedSlices = endsWithDelimiter ? parts[...] : parts.dropLast()
        let remainder = endsWithDelimiter ? "" : String(parts.last ?? "")

        let completedText = completedSlices.map(String.init).joined(separator: " ")
        if isExtension {
            let parsed = Category.parseExtensions(completedText)
            if !parsed.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) {
                    for ext in parsed where !extensions.contains(ext) {
                        extensions.append(ext)
                    }
                }
            }
            pendingExtensionInput = remainder
        } else {
            let parsed = Category.parseSitePatterns(completedText)
            if !parsed.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) {
                    for site in parsed where !sitePatterns.contains(site) {
                        sitePatterns.append(site)
                    }
                }
            }
            pendingSiteInput = remainder
        }
    }

    private func removeExtension(_ ext: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            extensions.removeAll { $0 == ext }
        }
    }

    private func removeSite(_ site: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            sitePatterns.removeAll { $0 == site }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}

/// A removable token pill for an extension (".mp3") or site ("example.com").
private struct TokenChip: View {
    let label: String
    let isWarning: Bool
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Text(label)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(isWarning ? Color.orange : Color.primary)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .frame(width: 14, height: 14)
                    .background(
                        Circle()
                            .fill(isHovering ? Color.primary.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Remove \(label)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isWarning ? Color.orange.opacity(0.15) : Color(nsColor: .quaternaryLabelColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isWarning ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 0.5
                )
        )
        .onHover { isHovering = $0 }
    }
}

/// Wraps token chips across lines and reports the exact height of all wrapped
/// rows so chips are never clipped mid-line.
private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            totalWidth = max(totalWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposal.width ?? totalWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Greys out and blocks a block of settings that depend on a switch which is
/// off. All three are needed. Opacity alone would leave the controls live;
/// `.disabled` dims controls but not plain text or this file's custom rows;
/// and hit testing is what also stops the double-click, the drag and the
/// right-click menu on those custom rows. The fade is animated so the change
/// is noticed.
private extension View {
    func greyedOut(_ greyed: Bool) -> some View {
        self
            .opacity(greyed ? 0.4 : 1)
            .disabled(greyed)
            .allowsHitTesting(!greyed)
            .animation(.easeInOut(duration: 0.2), value: greyed)
    }
}

private func abbreviateHome(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let home = NSHomeDirectory()
    if expanded == home { return "~" }
    if expanded.hasPrefix(home + "/") {
        return "~" + expanded.dropFirst(home.count)
    }
    return path
}
