import SwiftUI

// iPad-only. Fresh rebuild (per request). Date-grouping logic (NoteGroup/group(for:)/
// rowDate) ported from Mac's NoteListView.swift for the same section titles/ordering
// (Today/Yesterday/Previous 7 Days/Previous 30 Days/month/year) — duplicated here
// rather than shared, per the "no shared view code between iPhone/iPad" direction.
// .listStyle(.plain) + native Section headers gives flat rows with default
// separators/dividers between them (like Mac), not iPhone's card-per-section
// .insetGrouped look.
private enum NoteGroup: Hashable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(month: Int)   // current year only, e.g. "March"
    case year(Int)           // older than the current year, grouped whole — no month breakdown

    var title: String {
        switch self {
        case .today:          return "Today"
        case .yesterday:      return "Yesterday"
        case .previous7Days:  return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case .month(let month):
            var comps = DateComponents()
            comps.year = Calendar.current.component(.year, from: Date())
            comps.month = month; comps.day = 1
            let date = Calendar.current.date(from: comps) ?? Date()
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM"
            return fmt.string(from: date)
        case .year(let year):
            return String(year)
        }
    }

    // Sort order — lower = more recent. .month/.year additionally need the tie-break
    // in `grouped`'s sort below, since many notes share the same case with a different
    // month/year.
    var order: Int {
        switch self {
        case .today:          return 0
        case .yesterday:      return 1
        case .previous7Days:  return 2
        case .previous30Days: return 3
        case .month:          return 4
        case .year:           return 5
        }
    }
}

private func group(for note: Note) -> NoteGroup {
    let cal = Calendar.current
    let d   = note.updatedTime
    if cal.isDateInToday(d)     { return .today }
    if cal.isDateInYesterday(d) { return .yesterday }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7  { return .previous7Days }
    if days < 30 { return .previous30Days }
    let y = cal.component(.year, from: d)
    if y == cal.component(.year, from: Date()) {
        return .month(month: cal.component(.month, from: d))
    }
    return .year(y)
}

private func rowDate(_ note: Note) -> String {
    let cal = Calendar.current
    let d   = note.updatedTime
    if cal.isDateInToday(d) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
        let f = DateFormatter(); f.dateFormat = "EEEE"   // "Monday"
        return f.string(from: d)
    }
    // Older: show short date
    let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
    return f.string(from: d)
}

struct PadNoteListView: View {
    @EnvironmentObject var appState: AppState

    private var displayedNotes: [Note] {
        appState.isTrashSelected ? appState.trashedNotes : appState.notes
    }

    // Pinning only applies to live notes — pulled out of their date group into their
    // own section (first, like Apple Notes) so a note doesn't appear twice.
    private var pinnedNotes: [Note] {
        guard !appState.isTrashSelected else { return [] }
        return displayedNotes.filter { $0.isPinned }.sorted { $0.updatedTime > $1.updatedTime }
    }

    private var grouped: [(group: NoteGroup, notes: [Note])] {
        let unpinned = appState.isTrashSelected ? displayedNotes : displayedNotes.filter { !$0.isPinned }
        let byGroup = Dictionary(grouping: unpinned, by: { group(for: $0) })
        return byGroup
            .sorted { a, b in
                if a.key.order != b.key.order { return a.key.order < b.key.order }
                if case .month(let am) = a.key, case .month(let bm) = b.key {
                    return am > bm
                }
                if case .year(let ay) = a.key, case .year(let by) = b.key {
                    return ay > by
                }
                return false
            }
            .map { (group: $0.key, notes: $0.value) }
    }

    // Binding<String?> — same reasoning as PadSidebarView's selection: the optional
    // overload is what NavigationSplitView needs to push the detail column forward
    // on tap when columns are collapsed.
    private var selection: Binding<String?> {
        Binding<String?>(
            get: { appState.selectedNoteID },
            set: { newValue in
                guard let id = newValue, let note = displayedNotes.first(where: { $0.id == id }) else {
                    appState.selectNote(nil)
                    return
                }
                appState.selectNote(note)
            }
        )
    }

    private var navigationTitle: String {
        if appState.isTrashSelected { return "Trash" }
        return appState.selectedFolder?.title ?? "All Notes"
    }

    // Section headers ("Today", "Pinned", etc.) — matches the note title's style/color
    // (system default Section headers are small and gray) but 2pt bigger: .headline
    // resolves to 17pt semibold, so this is 19pt semibold, .primary instead of gray.
    // A divider now sits right below the title, same edge-to-edge/default position as
    // the first note row's own divider (see noteRow's isFirstInSection).
    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                // .foregroundStyle(.primary) alone wasn't enough — List section headers
                // apply their own muted/secondary tint by default that can override it;
                // .foregroundColor + .textCase(nil) (no forced uppercasing) reliably wins.
                .foregroundColor(.primary)
                .textCase(nil)
            Divider()
        }
    }

    // Row text/dividers sit 16px to the right of the section title's own leading
    // edge (the title's default List-header inset renders at ~16px already, so rows
    // need 32px total to read as 16px further indented than it) — except the
    // section's first divider, which keeps its default, edge-to-edge position per
    // earlier request. .listRowInsets alone didn't visibly move the system-drawn
    // separator here, so the system separator is hidden entirely and a manual
    // Divider is drawn instead, giving direct control over its inset.
    private let rowIndent: CGFloat = 32

    // Hides a row's own divider (drawn at its bottom, which visually also serves as
    // the row below it's top divider) when either this row or the next row is
    // selected — otherwise the divider would visibly cut across the yellow
    // selection highlight or the highlight of the row right after it.
    @ViewBuilder
    private func noteRow(_ note: Note, nextNoteIsSelected: Bool = false) -> some View {
        let isSelected = appState.selectedNoteID == note.id
        let hideDivider = isSelected || nextNoteIsSelected
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .foregroundStyle(isSelected ? .white : .primary)
                // Timestamp matches the title's color; preview keeps its own
                // (unchanged) secondary color — set per-segment since they're
                // concatenated into one Text.
                Group {
                    if note.preview.isEmpty {
                        Text(rowDate(note))
                            .foregroundColor(isSelected ? .white : .primary)
                    } else {
                        Text(rowDate(note))
                            .foregroundColor(isSelected ? .white : .primary)
                        + Text("  \(note.preview)")
                            .foregroundColor(isSelected ? .white : .secondary)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
            .padding(.leading, rowIndent)
            .padding(.trailing, 16)
            .padding(.vertical, 8)

            // Every row's divider — 32px leading, 16px trailing, matching the row
            // text's own padding above. Fully transparent when it would touch a
            // selected cell (this row or the next one).
            Divider()
                .padding(.leading, rowIndent)
                .padding(.trailing, 16)
                .opacity(hideDivider ? 0 : 1)
        }
        .tag(note.id)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // Dark yellow instead of the system's default gray/blue selection tint, per
        // request — .listRowBackground replaces the row's default (including its
        // selected-state) background entirely. Rounded via a shape (16px) instead of
        // a plain Color, with a little horizontal inset so the corners are visible
        // rather than clipped by the list's own edge.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? AppColors.darkYellow : Color.clear)
                .padding(.horizontal, 8)
        )
        // Long press — Pin/Unpin + Delete (or, when viewing Trash, Restore/Delete
        // Permanently instead).
        .contextMenu {
            if appState.isTrashSelected {
                Button("Restore") { appState.restoreNote(note) }
                Button("Delete Permanently", role: .destructive) { appState.permanentlyDeleteNote(note) }
            } else {
                Button(note.isPinned ? "Unpin Note" : "Pin Note") { appState.togglePin(note) }
                Button("Delete Note", role: .destructive) { appState.deleteNote(note) }
            }
        }
    }

    var body: some View {
        List(selection: selection) {
            // Note count — a subtitle under the current notebook's nav title, not a
            // real row, so no separators above/below it and not selectable/tappable
            // like the real rows below it.
            Text("\(displayedNotes.count) note\(displayedNotes.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .selectionDisabled()
                .listRowSeparator(.hidden)

            if !pinnedNotes.isEmpty {
                Section {
                    ForEach(Array(pinnedNotes.enumerated()), id: \.element.id) { index, note in
                        let nextIsSelected = index + 1 < pinnedNotes.count
                            && appState.selectedNoteID == pinnedNotes[index + 1].id
                        noteRow(note, nextNoteIsSelected: nextIsSelected)
                    }
                } header: {
                    sectionHeader("Pinned")
                }
            }
            if appState.isTrashSelected && !appState.trashedFolders.isEmpty {
                Section {
                    ForEach(appState.trashedFolders) { folder in
                        Text(folder.title)
                    }
                } header: {
                    sectionHeader("Notebooks")
                }
            }
            ForEach(grouped, id: \.group) { section in
                Section {
                    ForEach(Array(section.notes.enumerated()), id: \.element.id) { index, note in
                        let nextIsSelected = index + 1 < section.notes.count
                            && appState.selectedNoteID == section.notes[index + 1].id
                        noteRow(note, nextNoteIsSelected: nextIsSelected)
                    }
                } header: {
                    sectionHeader(section.group.title)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.createNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
    }
}

#Preview {
    PadNoteListView()
        .environmentObject(AppState())
}
