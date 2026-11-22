import SwiftUI

struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New group chat").font(.title2.bold())
            Text("Pick two or more agents. They reply in the order you pick them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(model.agents) { agent in
                Toggle(isOn: binding(for: agent.id)) {
                    HStack {
                        AgentRow(agent: agent)
                        Spacer()
                        if let index = selected.firstIndex(of: agent.id) {
                            Text("#\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 180)

            TextField("Name (optional)", text: $title)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createGroup(agentIDs: selected, title: title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.count < 2)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.append(id) } else { selected.removeAll { $0 == id } }
            }
        )
    }
}
