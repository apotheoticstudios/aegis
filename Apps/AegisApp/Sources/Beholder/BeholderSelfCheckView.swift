import SwiftUI

/// What is public about the owner, and where to ask for it to be removed. Opening a page is a separate click; the
/// handle check runs the ordinary username search, so it shows the same request preview first.
struct BeholderSelfCheckView: View {
    let sources: Int
    let onCheckHandle: (String) -> Void
    @State private var handle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space2) {
                Text("See what's public about you, and where to ask for it to be removed or limited.")
                    .hudType(.body).foregroundStyle(HUD.ink)
                HUDSubhead(title: "Your accounts", first: true)
                Text("Check one of your own handles against all \(sources) sources. Only the handle is sent, as in any search.")
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                HStack(spacing: HUD.space3) {
                    HUDTermInput(prompt: "my handle >", text: $handle, placeholder: "e.g. ExampleAlex").onSubmit(check)
                        .accessibilityLabel("Your own handle")
                    Button("Check on all sources", action: check).buttonStyle(HUDPlateStyle(compact: true)).fixedSize()
                        .disabled(BeholderCaseSearch.username(handle) == nil)
                }
                ForEach(BeholderSelfCheck.Kind.allCases, id: \.self) { kind in
                    HUDSubhead(title: kind.rawValue, meta: "Checked " + BeholderSelfCheck.checked)
                    ForEach(BeholderSelfCheck.places.filter { $0.kind == kind }) { row($0) }
                }
                Text(
                    "Breach checks inside Beholder are off for now: Have I Been Pwned's API needs a paid key, "
                        + "and sending an email address from Aegis needs its own decision record first."
                )
                .hudType(.caption).foregroundStyle(HUD.inkMuted).padding(.top, HUD.space2)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .beholderStyle()
    }

    private func check() {
        guard let name = BeholderCaseSearch.username(handle) else { return }
        onCheckHandle(name)
    }

    private func row(_ place: BeholderSelfCheck.Place) -> some View {
        VStack(alignment: .leading, spacing: HUD.space1) {
            HStack(spacing: HUD.space2) {
                Text(place.name).hudType(.label).foregroundStyle(HUD.ink)
                Spacer(minLength: HUD.space2)
                if let url = place.page.url {
                    Link("Open ↗", destination: url).fixedSize()
                        .help("Opens \(place.page.host) in your browser. Beholder sends it nothing.")
                }
                if let url = place.source?.url {
                    Link("Source ↗", destination: url).buttonStyle(HUDChipStyle(muted: true)).fixedSize()
                        .help("Where this page was confirmed: \(place.source?.host ?? "")")
                }
            }
            Text(place.what).hudType(.caption).foregroundStyle(HUD.ink)
            Text(place.action).hudType(.caption).foregroundStyle(HUD.inkMuted)
        }
        .padding(.vertical, HUD.space2)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.glassEdge).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
