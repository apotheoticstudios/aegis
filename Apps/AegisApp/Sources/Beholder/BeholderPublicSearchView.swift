import SwiftUI

/// A separate owner click opens the browser. Selecting a service, editing and Return never open anything.
struct BeholderPublicSearchView: View {
    let input: BeholderPublicSearch.Input
    let ownerTyped: Bool
    @State private var selection: BeholderPublicSearch.Selection?

    private var service: Binding<BeholderPublicSearch.Service?> {
        Binding(get: { selection?.input == input ? selection?.service : nil }, set: { chosen in
            selection = chosen.map { .init(service: $0, input: input) }
        })
    }

    var body: some View {
        DisclosureGroup("Public lookup in your browser") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Public service", selection: service) {
                    Text("Choose a service").tag(nil as BeholderPublicSearch.Service?)
                    ForEach(BeholderPublicSearch.Service.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.disabled(!ownerTyped || input.value.isEmpty)
                if !ownerTyped {
                    Text("Type the identifier yourself to prepare a public lookup. Imported records and case evidence are not sent.")
                        .font(.caption).foregroundStyle(HUD.inkMuted)
                } else if let selection, let plan = selection.plan(for: input) {
                    Text("EXACT PUBLIC QUERY").hudType(.data)
                    Text(verbatim: plan.query).textSelection(.enabled)
                    Text(verbatim: plan.destination.absoluteString).font(.caption).textSelection(.enabled)
                    Text(
                        "Opening sends this query to \(plan.host). Your browser exposes your IP address and uses its current cookies and sign-in settings; the service may log the query."
                    )
                    .font(.caption).foregroundStyle(HUD.inkMuted)
                    Link("Open selected public search ↗", destination: plan.destination)
                    Text(
                        "Inspect results in the browser. Indexed pages can be incomplete or mistaken; a search hit is not proof of account ownership."
                    )
                    .font(.caption).foregroundStyle(HUD.inkMuted)
                } else {
                    Text(
                        "Choose a service for the current input. GitHub supports usernames, names and public emails; phone searches use DuckDuckGo."
                    )
                    .font(.caption).foregroundStyle(HUD.inkMuted)
                }
            }.padding(.vertical, 8)
        }
        .onChange(of: input) { _, _ in selection = nil }
        .onChange(of: ownerTyped) {
            _, typed in if !typed {
                selection = nil
            }
        }
    }
}
