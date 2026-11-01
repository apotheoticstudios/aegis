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
        Group {
            if input.kind == .username {
                DisclosureGroup("Open a public search in your browser") { controls }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FIND PUBLIC ACCOUNTS ON THE WEB").hudType(.data)
                    Text("The case search checks saved evidence. Choose a service below to look for additional public pages.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    controls
                }
            }
        }
        .onChange(of: input) { _, _ in selection = nil }
        .onChange(of: ownerTyped) {
            _, typed in if !typed {
                selection = nil
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Public service", selection: service) {
                Text("Choose a service").tag(nil as BeholderPublicSearch.Service?)
                ForEach(BeholderPublicSearch.Service.allCases.filter { $0.supports(input.kind) }) {
                    Text($0.rawValue).tag(Optional($0))
                }
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
                // privacy-guard: allow-network ADR-0036 separate owner click after the exact query/destination preview
                Link("Open selected public search ↗", destination: plan.destination)
                if input.kind == .phone {
                    Text("This query uses the international phone format. Pages may use other spellings or spacing.")
                        .font(.caption).foregroundStyle(HUD.inkMuted)
                }
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
}
