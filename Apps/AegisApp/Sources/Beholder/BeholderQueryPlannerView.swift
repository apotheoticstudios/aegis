import AppKit
import SwiftUI

/// An independent scratchpad: no access to the research model, personal memory or a network client.
struct BeholderQueryPlannerView: View {
    /// Shown in the dashboard's Planner tab rather than a sheet: no Done button, full width.
    var embedded = false
    @State private var input = ""
    @State private var kind = BeholderQueryPlanner.Kind.username
    @State private var region = BeholderQueryPlanner.PhoneRegion.international
    @State private var scope = ""
    @State private var document = BeholderQueryPlanner.DocumentKind.any
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space4) {
            if !embedded {
                HStack {
                    Text("RESEARCH PLANNER").hudType(.data)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            Text("Prepare a precise public search").hudType(.bodyStrong)
            Text("This scratchpad stays on your Mac. Copy the query when ready to use it in a search service.")
                .foregroundStyle(HUD.inkMuted)
            HUDSegmented(
                label: "Input type",
                options: BeholderQueryPlanner.Kind.allCases.map { HUDOption(value: $0, label: $0.rawValue) },
                value: $kind
            )
            TextField("Enter " + (kind == .email ? "an " : "a ") + kind.rawValue.lowercased(), text: $input).modifier(BeholderField())
                .accessibilityLabel("Research " + kind.rawValue.lowercased())
            if kind == .phone {
                HUDSegmented(
                    label: "Phone format",
                    options: BeholderQueryPlanner.PhoneRegion.allCases.map { HUDOption(value: $0, label: $0.rawValue) },
                    value: $region,
                    small: true
                )
            }
            HStack {
                TextField("Optional site, e.g. example.com", text: $scope).modifier(BeholderField())
                    .accessibilityLabel("Optional domain scope")
                HUDSegmented(
                    label: "Documents",
                    options: BeholderQueryPlanner.DocumentKind.allCases.map { HUDOption(value: $0, label: $0.rawValue) },
                    value: $document,
                    small: true
                )
            }
            switch BeholderQueryPlanner.build(input: input, kind: kind, scope: scope, document: document, region: region) {
            case let .success(plan):
                Text("EXACT QUERY").hudType(.data).foregroundStyle(HUD.inkMuted)
                Text(verbatim: plan.query).hudType(.term).textSelection(.enabled)
                    .padding(HUD.space3).frame(maxWidth: .infinity, alignment: .leading).background(HUD.surface)
                Button(copied ? "Copied" : "Copy query") {
                    NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
                    copied = NSPasteboard.general.setString(plan.query, forType: .string)
                }
                ForEach(plan.notes, id: \.self) { Text($0).hudType(.caption).foregroundStyle(HUD.inkMuted) }
            case let .failure(problem):
                Text(input.isEmpty ? "Choose a type and enter a value to prepare a query." : problem.message)
                    .foregroundStyle(HUD.inkMuted)
            }
            Text("Check original sources and the relevant jurisdiction. Public availability alone does not establish accuracy.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
        }
        .padding(embedded ? 0 : HUD.space4).frame(width: embedded ? nil : 620, alignment: .leading)
        .frame(maxWidth: embedded ? 720 : nil, alignment: .leading)
        .foregroundStyle(HUD.ink).background(embedded ? AnyShapeStyle(.clear) : AnyShapeStyle(HUD.void)).beholderStyle()
        .onChange(of: input) { copied = false }
        .onChange(of: kind) { copied = false }
        .onChange(of: scope) { copied = false }
        .onChange(of: document) { copied = false }
        .onChange(of: region) { copied = false }
    }
}
