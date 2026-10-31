import AppKit
import SwiftUI

/// An independent scratchpad: no access to the research model, personal memory or a network client.
struct BeholderQueryPlannerView: View {
    @State private var input = ""
    @State private var kind = BeholderQueryPlanner.Kind.username
    @State private var region = BeholderQueryPlanner.PhoneRegion.international
    @State private var scope = ""
    @State private var document = BeholderQueryPlanner.DocumentKind.any
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space4) {
            HStack {
                Text("RESEARCH PLANNER").hudType(.data)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Prepare a precise public search").font(.title2)
            Text("This scratchpad stays on your Mac. Copy the query when ready to use it in a search service.")
                .foregroundStyle(HUD.inkMuted)
            Picker("Input type", selection: $kind) {
                ForEach(BeholderQueryPlanner.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Enter a " + kind.rawValue.lowercased(), text: $input).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Research " + kind.rawValue.lowercased())
            if kind == .phone {
                Picker("Phone format", selection: $region) {
                    ForEach(BeholderQueryPlanner.PhoneRegion.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                TextField("Optional site, e.g. example.com", text: $scope).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Optional domain scope")
                Picker("Documents", selection: $document) {
                    ForEach(BeholderQueryPlanner.DocumentKind.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 200)
            }
            switch BeholderQueryPlanner.build(input: input, kind: kind, scope: scope, document: document, region: region) {
            case let .success(plan):
                Text("EXACT QUERY").hudType(.data).foregroundStyle(HUD.inkMuted)
                Text(verbatim: plan.query).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(HUD.space3).frame(maxWidth: .infinity, alignment: .leading).background(HUD.surface)
                Button(copied ? "Copied" : "Copy query") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(plan.query, forType: .string)
                }
                ForEach(plan.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(HUD.inkMuted) }
            case let .failure(problem):
                Text(input.isEmpty ? "Choose a type and enter a value to prepare a query." : problem.message)
                    .foregroundStyle(HUD.inkMuted)
            }
            Text("Check original sources and the relevant jurisdiction. Public availability alone does not establish accuracy.")
                .font(.caption).foregroundStyle(HUD.inkMuted)
        }
        .padding(HUD.space4).frame(width: 620, alignment: .leading)
        .foregroundStyle(HUD.ink).background(HUD.void)
        .onChange(of: input) { copied = false }
        .onChange(of: kind) { copied = false }
        .onChange(of: scope) { copied = false }
        .onChange(of: document) { copied = false }
        .onChange(of: region) { copied = false }
    }
}
