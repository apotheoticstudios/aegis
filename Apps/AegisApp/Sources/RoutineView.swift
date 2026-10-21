import AegisKit
import SwiftUI

/// The morning routine card (#286): each proposal with Yes and No, and Always for jobs Aegis may remember.
extension BriefView {
    @ViewBuilder var routineSection: some View {
        let routine = RoutinePresence.shared.today
        let pending = routine?.pending ?? []
        let automatic = routine?.proposals.filter { $0.remembered && $0.status == .executed } ?? []
        if !pending.isEmpty || !automatic.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("MORNING ROUTINE").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                ForEach(pending) { proposal in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(proposal.number)").font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan.opacity(0.7))
                        Text(proposal.text).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 8)
                        routineButton("Yes", proposal, approved: true, always: false)
                        routineButton("No", proposal, approved: false, always: false)
                        if proposal.tier.canRemember {
                            Menu("Always") {
                                Button("Always yes") { Task { await model.decideRoutine([proposal], approved: true, always: true) } }
                                Button("Always no") { Task { await model.decideRoutine([proposal], approved: false, always: true) } }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(.caption)
                        }
                    }
                }
                ForEach(automatic) { proposal in
                    Text("✓ " + proposal.text + " (you said always)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .hudPanel()
        }
    }

    private func routineButton(_ title: String, _ proposal: RoutineProposal, approved: Bool, always: Bool) -> some View {
        Button(title) { Task { await model.decideRoutine([proposal], approved: approved, always: always) } }
            .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(approved ? Self.cyan : .secondary)
    }
}
