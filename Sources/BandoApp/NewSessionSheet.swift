import AppKit
import BandoCore
import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    @State private var projectId: String?
    @State private var prompt = ""
    @State private var name = ""
    @State private var agent = "claude"
    @State private var provider = "default"
    @State private var modelName = ""
    @State private var branch = ""
    @State private var useWorktree = true
    @State private var dependsOn: String?
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DialogHeader(title: "Nova sessão", description: "O agente roda num worktree próprio, numa sessão do tmux.",
                         symbol: "square.and.pencil")

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Projeto")
                HStack(spacing: 8) {
                    SelectField(selection: $projectId, options: model.projects.map { (Optional($0.id), $0.name) })
                    Button("Outra pasta…", action: pickFolder).buttonStyle(OutlineButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Tarefa", hint: "opcional")
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 6)
                    .frame(minHeight: 90, maxHeight: 180)
                    .fieldBox(height: nil)
                Text("Pode deixar vazio para abrir o agente e escrever lá.")
                    .font(.system(size: 11.5)).foregroundStyle(p.tertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Nome", hint: "opcional")
                TextField("Gerado a partir da tarefa", text: $name).fieldBox()
            }

            DialogDivider()

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Agente")
                    SelectField(selection: $agent, options: agents.map {
                        ($0.agent.id, $0.agent.name + ($0.isInstalled ? "" : " (não instalado)"))
                    })
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Provider")
                    SelectField(selection: $provider, options: providers.map { ($0.id, $0.name) })
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Modelo", hint: "opcional")
                TextField(modelHint, text: $modelName).fieldBox()
            }

            DialogDivider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Worktree separado").font(.system(size: 13))
                    Text("Isola as mudanças numa branch própria.").font(.system(size: 11.5)).foregroundStyle(p.tertiary)
                }
                Spacer()
                Toggle("", isOn: $useWorktree).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            HStack(alignment: .top, spacing: 12) {
                if useWorktree {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Branch", hint: "opcional")
                        TextField("bando/<nome>", text: $branch).fieldBox()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Começar depois de")
                    SelectField(selection: $dependsOn, options: [(String?.none, "Agora")] +
                        model.sessions.filter { $0.status.isLive || $0.status == .queued }.map { (Optional($0.id), $0.name) })
                }
            }

            if let error {
                Text(error).foregroundStyle(StateColor.failed).font(.system(size: 12))
            }
            HStack(spacing: 8) {
                if let a = model.availability[agent], !a.isInstalled, let install = a.agent.install {
                    Text("Instalar: \(install)").font(.system(size: 11.5)).foregroundStyle(p.secondary).textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(creating ? "Criando…" : "Criar sessão", action: create)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(projectId == nil || creating)
            }
        }
        .dialog(width: 560, palette: p)
        .onAppear(perform: setDefaults)
        .onChange(of: agent) { _, new in
            if !(providers.contains { $0.id == provider }) { provider = "default" }
            _ = new
        }
        .onChange(of: projectId) { _, id in
            if let p = id.flatMap(model.project), let a = p.defaultAgent, model.config?.agents[a] != nil { agent = a }
        }
    }

    /// Instalados primeiro, depois o resto em ordem alfabética.
    var agents: [AgentAvailability] {
        model.availability.values.filter { $0.agent.id != "shell" || true }
            .sorted { ($0.isInstalled ? 0 : 1, $0.agent.name) < ($1.isInstalled ? 0 : 1, $1.agent.name) }
    }

    var providers: [ProviderDefinition] {
        let list = model.config?.providers(for: agent) ?? []
        return list.sorted { ($0.id == "default" ? 0 : 1, $0.name) < ($1.id == "default" ? 0 : 1, $1.name) }
    }

    var modelHint: String {
        model.config?.providers[provider]?.models.first ?? "padrão do agente"
    }

    func setDefaults() {
        projectId = model.newSessionProject ?? model.selectedSession?.projectId
            ?? model.projects.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }?.id
        if let p = projectId.flatMap(model.project), let a = p.defaultAgent, model.config?.agents[a] != nil { agent = a }
        else if model.availability["claude"]?.isInstalled != true,
                let first = agents.first(where: { $0.isInstalled && $0.agent.id != "shell" }) { agent = first.agent.id }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Usar esta pasta"
        guard panel.runModal() == .OK, let url = panel.url, let service = model.service else { return }
        do {
            let p = try service.ensureProject(at: url.path)
            model.refreshSessions()
            projectId = p.id
        } catch { self.error = error.localizedDescription }
    }

    func create() {
        guard let service = model.service, let pid = projectId, let project = model.project(pid) else { return }
        creating = true
        error = nil
        let req = SessionService.NewSession(
            project: project,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt,
            name: name.isEmpty ? nil : name,
            agent: agent,
            provider: provider == "default" ? nil : provider,
            model: modelName.isEmpty ? nil : modelName,
            branch: branch.isEmpty ? nil : branch,
            useWorktree: useWorktree,
            dependsOn: dependsOn
        )
        Task.detached {
            do {
                let s = try service.create(req)
                await MainActor.run {
                    model.refreshSessions()
                    if model.gridMode { model.showInGrid(s.id) }
                    model.select(s.id)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    creating = false
                }
            }
        }
    }
}

/// ⌘K: busca rápida de sessões.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0

    var results: [Session] {
        let all = model.sessions.sorted { ($0.status.urgency, $1.updatedAt) < ($1.status.urgency, $0.updatedAt) }
        guard !query.isEmpty else { return Array(all.prefix(12)) }
        return all.filter { s in
            [s.name, s.agent, s.branch ?? "", model.project(s.projectId)?.name ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Buscar sessão por nome, projeto, agente ou branch", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .onSubmit(open)
                .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 8) {
                            StatusIcon(status: s.status)
                            Text(s.name).lineLimit(1)
                            Spacer()
                            Text(model.project(s.projectId)?.name ?? "").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(i == index ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; open() }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 560)
    }

    func open() {
        guard index < results.count else { return }
        model.select(results[index].id)
        dismiss()
    }
}
