import SwiftUI

/// Browse sources by topic and access mode, then select exactly the sources shown. Choosing never starts a search.
struct BeholderSourceGuideView: View {
    @Binding var selected: Set<BeholderProvider>
    @State private var text = ""
    @State private var category: BeholderSourceGuide.Category?
    @State private var access = BeholderSourceGuide.Access.all

    var body: some View {
        let visible = BeholderSourceGuide.filter(text, category: category, access: access)
        let chosen = visible.filter(selected.contains).count
        VStack(alignment: .leading, spacing: HUD.space3) {
            HStack {
                Text("SOURCE GUIDE").hudType(.data)
                Spacer()
                Text(BeholderSources.summary(selected).uppercased() + " SELECTED").hudType(.data).foregroundStyle(HUD.primary)
            }
            TextField("Filter by name, host or topic", text: $text).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter sources by name, host or topic")
            Picker("Access", selection: $access) {
                ForEach(BeholderSourceGuide.Access.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Category", selection: $category) {
                Text("All categories (\(count(nil)))").tag(BeholderSourceGuide.Category?.none)
                ForEach(BeholderSourceGuide.Category.allCases) { Text("\($0.title) (\(count($0)))").tag(Optional($0)) }
            }
            HStack {
                Button("Select \(visible.count) shown") { selected = BeholderSourceGuide.select(visible, in: selected) }
                    .disabled(chosen == visible.count)
                Button("Clear \(chosen) shown") { selected = BeholderSourceGuide.deselect(visible, in: selected) }
                    .disabled(chosen == 0)
            }.controlSize(.small)
            if visible.isEmpty {
                Text("No source matches these filters. Change the text, category or access to see more.")
                    .foregroundStyle(HUD.inkMuted).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HUD.space2) {
                        ForEach(visible) { row($0) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 360)
            }
            Text(BeholderSourceGuide.caveat).font(.caption).foregroundStyle(HUD.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(HUD.ink).padding(HUD.space4).frame(minWidth: 320, idealWidth: 400, alignment: .leading)
    }

    private func count(_ category: BeholderSourceGuide.Category?) -> Int {
        BeholderSourceGuide.filter(text, category: category, access: access).count
    }

    private func row(_ provider: BeholderProvider) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(provider) },
            set: { selected = $0 ? selected.union([provider]) : selected.subtracting([provider]) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                Text(verbatim: provider.host + " · " + BeholderSourceGuide.category(provider).title)
                    .font(.caption).foregroundStyle(HUD.inkMuted)
                Text(provider.accessLabel).font(.caption2).foregroundStyle(HUD.inkMuted)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(provider.sourceAccessibilityLabel + ", " + BeholderSourceGuide.category(provider).title)
        .accessibilityHint(provider.isManual ? "Unchecked link; opens only when you choose its browser button"
            : "Sends the username to \(provider.host) when you search")
    }
}
