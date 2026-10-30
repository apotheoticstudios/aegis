import SwiftUI

/// Source-selection rules that know only `allCases`, `title` and `host`, so new providers need no picker changes.
enum BeholderSources {
    /// The sources Beholder first shipped with: the first four cases, whatever is added after them.
    static let original = Set(BeholderProvider.allCases.prefix(4))

    /// Sources whose name or host contains `filter` (ignoring case and accents), kept in the given order.
    static func matching(_ filter: String, in providers: [BeholderProvider] = BeholderProvider.allCases) -> [BeholderProvider] {
        let term = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return providers }
        return providers.filter { $0.title.localizedStandardContains(term) || $0.host.localizedStandardContains(term) }
    }

    static func summary(_ selected: Set<BeholderProvider>) -> String {
        let total = BeholderProvider.allCases.count
        return "\(selected.count) of \(total) " + (total == 1 ? "source" : "sources")
    }
}

/// A compact button that opens a searchable source list. Choosing sources never starts a search.
struct BeholderSourcePicker: View {
    @Binding var selected: Set<BeholderProvider>
    @State private var showing = false
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Button { showing.toggle() } label: {
            Label(BeholderSources.summary(selected), systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Choose which public sources receive the username")
        .accessibilityLabel("Choose public sources")
        .accessibilityValue(BeholderSources.summary(selected))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BeholderSourceList(selected: $selected).environment(\.hudTheme, theme)
        }
    }
}

struct BeholderSourceList: View {
    @Binding var selected: Set<BeholderProvider>
    @State private var filter = ""

    var body: some View {
        let shown = BeholderSources.matching(filter)
        VStack(alignment: .leading, spacing: HUD.space3) {
            HStack {
                Text("SOURCES").hudType(.data)
                Spacer()
                Text(BeholderSources.summary(selected).uppercased()).hudType(.data).foregroundStyle(HUD.primary)
            }
            TextField("Filter by name or host", text: $filter).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter sources by name or host")
            HStack {
                Button("All") { selected = Set(BeholderProvider.allCases) }
                Button("None") { selected = [] }
                Button("Original four") { selected = BeholderSources.original }
                    .help(BeholderProvider.allCases.prefix(4).map(\.title).joined(separator: ", "))
            }.controlSize(.small)
            if shown.isEmpty {
                Text("No source matches that filter.").foregroundStyle(HUD.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: HUD.space2) {
                        ForEach(shown) { provider in
                            Toggle(isOn: binding(provider)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.title)
                                    Text(verbatim: provider.host).font(.caption).foregroundStyle(HUD.inkMuted)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel(provider.title)
                            .accessibilityHint("Sends the username to \(provider.host) when you search")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 320)
            }
        }
        .foregroundStyle(HUD.ink).padding(HUD.space4).frame(width: 320)
        .background(HUD.surface)
    }

    private func binding(_ provider: BeholderProvider) -> Binding<Bool> {
        Binding(
            get: { selected.contains(provider) },
            set: {
                if $0 {
                    selected.insert(provider)
                } else {
                    selected.remove(provider)
                }
            }
        )
    }
}
