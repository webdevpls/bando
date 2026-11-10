import AppKit
import BandoCore
import SwiftUI

// MARK: - Caixa de nova sessão

/// Nova sessão como uma caixa de texto no centro: escreve a tarefa, escolhe
/// projeto e agente nos chips e envia (⌘↩). Opções extras ficam num popover.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    /// Projeto fixo (página do projeto) ou escolhido no chip.
    var fixedProject: String? = nil
    var compact = false

    @State private var text = ""
    @State private var projectId: String?
    @State private var agent = ""
    @State private var provider = "default"
    @State private var modelName = ""
    @State private var branch = ""
    @State private var useWorktree = true
    @State private var dependsOn: String?
    @State private var showProjects = false
    @State private var showOptions = false
    @State private var creating = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(compact ? (currentProject?.isGeneral == true ? "Descreva a tarefa (roda na sua pasta pessoal)…" : "Descreva a próxima tarefa deste projeto…") : "Descreva a tarefa ou cole o link de um ticket…")
                        .font(.system(size: 14)).foregroundStyle(p.tertiary)
                        .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: compact ? 44 : 70, maxHeight: compact ? 120 : 220)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if fixedProject == nil { projectChip }
                agentChip
                Chip(symbol: "slider.horizontal.3", title: optionsLabel) { showOptions.toggle() }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) { options }
                Spacer()
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(StateColor.failed).lineLimit(2) }
                Button(action: create) {
                    Image(systemName: creating ? "hourglass" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.onAccent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canCreate ? p.accent : p.accent.opacity(0.3)))
                }
                .buttonStyle(.plain).pointerCursor()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
                .help("Criar sessão (⌘↩). Tarefa vazia abre o agente para você escrever lá.")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.hover))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? p.accent.opacity(0.4) : p.border))
        .onAppear {
            projectId = fixedProject ?? model.route.projectId
                ?? model.projects.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }?.id
            let preferred = projectId.flatMap(model.project)?.defaultAgent ?? model.lastAgent
            agent = model.availability[preferred]?.isInstalled == true ? preferred
                : (installedAgents.first?.agent.id ?? preferred)
            showOptions = false
            showProjects = false
            if !compact { DispatchQueue.main.async { focused = true } }
        }
    }

    var currentProject: Project? { (fixedProject ?? projectId).flatMap(model.project) }

    var canCreate: Bool { (fixedProject ?? projectId) != nil && !creating && !agent.isEmpty }

    var installedAgents: [AgentAvailability] {
        model.availability.values.filter { $0.isInstalled && $0.agent.id != "shell" }
            .sorted { $0.agent.name < $1.agent.name }
    }

    var optionsLabel: String {
        var parts: [String] = []
        if provider != "default" { parts.append(model.config?.providers[provider]?.name ?? provider) }
        if !modelName.isEmpty { parts.append(modelName) }
        if !useWorktree { parts.append("sem worktree") }
        if dependsOn != nil { parts.append("na fila") }
        return parts.isEmpty ? "Opções" : parts.joined(separator: " · ")
    }

    var projectChip: some View {
        Chip(symbol: projectId.flatMap(model.project)?.isGeneral == true ? "tray" : "folder",
             title: projectId.flatMap(model.project)?.name ?? "Projeto") { showProjects.toggle() }
            .popover(isPresented: $showProjects, arrowEdge: .bottom) {
                ProjectPicker { id in projectId = id; showProjects = false }
                    .environment(model).environment(\.palette, p)
            }
    }

    var agentChip: some View {
        Menu {
            ForEach(installedAgents, id: \.agent.id) { a in
                Button { agent = a.agent.id; if !(providers.contains { $0.id == provider }) { provider = "default" } } label: {
                    Label(a.agent.name, systemImage: a.agent.id == agent ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkle").font(.system(size: 11))
                Text(model.config?.agents[agent]?.name ?? agent).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(p.text)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().strokeBorder(p.border))
        .pointerCursor()
    }

    var providers: [ProviderDefinition] {
        (model.config?.providers(for: agent) ?? [])
            .sorted { ($0.id == "default" ? 0 : 1, $0.name) < ($1.id == "default" ? 0 : 1, $1.name) }
    }

    var options: some View {
        Form {
            Picker("Provider", selection: $provider) { ForEach(providers) { Text($0.name).tag($0.id) } }
            TextField("Modelo", text: $modelName, prompt: Text(model.config?.providers[provider]?.models.first ?? "padrão do agente"))
            if currentProject?.isGeneral != true {
                Toggle("Worktree separado", isOn: $useWorktree)
                if useWorktree { TextField("Branch", text: $branch, prompt: Text("bando/<nome>")) }
            }
            Picker("Começar depois de", selection: $dependsOn) {
                Text("Agora").tag(String?.none)
                ForEach(model.sessions.filter { $0.status.isLive || $0.status == .queued }) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
    }

    func create() {
        guard let service = model.service, let pid = fixedProject ?? projectId, let project = model.project(pid) else { return }
        creating = true
        error = nil
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = SessionService.NewSession(
            project: project, prompt: prompt.isEmpty ? nil : prompt, agent: agent,
            provider: provider == "default" ? nil : provider, model: modelName.isEmpty ? nil : modelName,
            branch: branch.isEmpty ? nil : branch, useWorktree: useWorktree, dependsOn: dependsOn
        )
        model.lastAgent = agent
        Task.detached {
            do {
                let s = try service.create(req)
                await MainActor.run {
                    text = ""
                    creating = false
                    model.refreshSessions()
                    if model.gridMode { model.showInGrid(s.id) }
                    model.select(s.id)
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; creating = false }
            }
        }
    }
}

struct Chip: View {
    @Environment(\.palette) private var p
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(hovering ? p.hover : .clear))
            .overlay(Capsule().strokeBorder(p.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerCursor()
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

/// Lista de projetos com busca (chip de projeto da caixa de nova sessão).
struct ProjectPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let choose: (String) -> Void
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Buscar projeto", text: $filter).textFieldStyle(.roundedBorder).padding(8)
            ScrollView {
                VStack(spacing: 0) {
                    if filter.isEmpty || Project.generalName.localizedCaseInsensitiveContains(filter) {
                        ActionItem(symbol: "tray", title: "Geral (sem projeto)", color: p.text) {
                            if let g = model.projects.first(where: \.isGeneral) { choose(g.id); return }
                            guard let service = model.service, let g = try? service.generalProject() else { return }
                            model.refreshSessions()
                            choose(g.id)
                        }
                    }
                    ForEach(projects.filter { !$0.isGeneral }) { proj in
                        ActionItem(symbol: "folder", title: proj.name, color: p.text) { choose(proj.id) }
                    }
                    ActionItem(symbol: "plus", title: "Adicionar projeto…", color: p.secondary) {
                        model.showAddProject = true
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 280)
        .padding(.bottom, 6)
    }

    var projects: [Project] {
        model.projects
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
    }
}

/// Tela central de nova sessão.
struct ComposerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let projectId: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BandoMark(size: 34).foregroundStyle(p.text.opacity(0.85))
            Composer(fixedProject: nil).frame(maxWidth: 780).id(projectId ?? "-")
            recentProjects
            Button("Ver todos os projetos") { model.sidebarMode = .projects }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(p.secondary).pointerCursor()
            Spacer()
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var recentProjects: some View {
        let recent = model.projects.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }.prefix(6)
        return HStack(spacing: 6) {
            ForEach(Array(recent)) { proj in
                Chip(symbol: "folder", title: proj.name) { model.route = .composer(proj.id) }
            }
        }
    }
}

// MARK: - Página do projeto

struct ProjectPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let projectId: String
    @State private var search = ""
    @State private var showWorktrees = false

    var project: Project? { model.project(projectId) }
    var sessions: [Session] { model.sessions.filter { $0.projectId == projectId } }
    var active: [Session] {
        sessions.filter { $0.status.isLive || $0.status == .queued || $0.status == .error }
            .sorted { ($0.status.urgency, $1.statusChangedAt) < ($1.status.urgency, $0.statusChangedAt) }
    }
    var recent: [Session] {
        sessions.filter { !$0.status.isLive && $0.status != .queued && $0.status != .error }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.prompt ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Composer(fixedProject: projectId, compact: true).id(projectId)
                activeSection
                if project?.isGeneral != true { worktreesSection }
                recentSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: project?.isGeneral == true ? "tray.fill" : "folder.fill").font(.system(size: 20))
                .foregroundStyle(project?.isGeneral == true ? p.secondary : StateColor.waiting)
            VStack(alignment: .leading, spacing: 2) {
                Text(project?.name ?? "Projeto").font(.system(size: 20, weight: .bold))
                if project?.isGeneral == true {
                    Text("Sessões fora de um projeto. Rodam na sua pasta pessoal, sem worktree.")
                        .font(.system(size: 12)).foregroundStyle(p.tertiary).lineLimit(1)
                } else {
                    Text(project?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if let proj = project {
                IconButton(symbol: "folder", help: "Mostrar no Finder", size: 15) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: proj.path)])
                }
            }
        }
    }

    var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "ATIVAS", count: active.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(active) { SessionCard(session: $0) }
                QuickSessionCard(projectId: projectId)
            }
        }
    }

    var worktreesSection: some View {
        let trees = sessions.filter(\.usesWorktree).map(\.worktreePath)
            .filter { FileManager.default.fileExists(atPath: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showWorktrees.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showWorktrees ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 12))
                    Text("WORKTREES").font(.system(size: 12, weight: .bold))
                    Text("\(trees.count)").font(.system(size: 12)).foregroundStyle(p.tertiary)
                }
                .foregroundStyle(p.secondary)
            }
            .buttonStyle(.plain).pointerCursor()
            if showWorktrees {
                ForEach(trees, id: \.self) { path in
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.secondary).textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
        }
    }

    var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "RECENTES", count: recent.count)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.tertiary)
                    TextField("Buscar sessões", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(width: 220, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(p.hover))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            }
            if recent.isEmpty {
                Text(search.isEmpty ? "Nenhuma sessão parada ou encerrada." : "Nada encontrado.")
                    .font(.system(size: 12)).foregroundStyle(p.tertiary)
            }
            VStack(spacing: 2) {
                ForEach(recent.prefix(80)) { RecentRow(session: $0) }
            }
        }
    }
}

struct SectionTitle: View {
    @Environment(\.palette) private var p
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(p.secondary)
            Text("\(count)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(p.hover)).foregroundStyle(p.secondary)
        }
    }
}

/// Cartão de sessão ativa na página do projeto.
struct SessionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let session: Session
    @State private var menuOpen = false
    @State private var hovering = false

    var body: some View {
        let tint = StateColor.dot(session.status)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(tint ?? p.tertiary).frame(width: 6, height: 6)
                Text(StateColor.label(session.status)).font(.system(size: 11, design: .monospaced)).foregroundStyle(tint ?? p.secondary)
                Spacer()
                if hovering || menuOpen { SessionActionsButton(session: session, size: 12, openBinding: $menuOpen) }
            }
            Text(session.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            if let b = session.branch {
                Label(b, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(StateColor.cyan).lineLimit(1)
            }
            HStack {
                if let c = model.contexts[session.id] {
                    Capsule().fill(p.border).frame(width: 70, height: 3)
                        .overlay(alignment: .leading) { Capsule().fill(StateColor.cyan).frame(width: 70 * c.fraction, height: 3) }
                    Text("\(Int(c.fraction * 100))%").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.tertiary)
                }
                Spacer()
                Label(relativeTime(session.statusChangedAt), systemImage: "clock").font(.system(size: 10.5)).foregroundStyle(p.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? p.selected : p.hover))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((tint ?? p.border).opacity(tint == nil ? 1 : 0.4)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .onTapGesture { model.select(session.id) }
        .contextMenu { SessionContextMenu(session: session) }
    }
}

/// "Sessão vazia rápida": abre o agente padrão sem tarefa.
struct QuickSessionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let projectId: String
    @State private var hovering = false

    var body: some View {
        Button {
            guard let service = model.service, let project = model.project(projectId) else { return }
            let agent = project.defaultAgent ?? model.lastAgent
            model.runReturning("Nova sessão") { try $0.create(.init(project: project, prompt: nil, agent: agent)) }
            _ = service
        } label: {
            Label("Sessão vazia rápida", systemImage: "plus").font(.system(size: 12.5))
                .foregroundStyle(hovering ? p.text : p.secondary)
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovering = $0 }
    }
}

/// Sessão parada ou encerrada na lista de recentes.
struct RecentRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let session: Session
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(tag).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(p.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(p.hover))
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if let prompt = session.prompt, !prompt.isEmpty {
                    Text(prompt).font(.system(size: 12)).foregroundStyle(p.secondary).lineLimit(1)
                }
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(p.tertiary)
            }
            Spacer()
            if hovering {
                Button("Retomar") { model.resumeSession(session.id); model.select(session.id) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(p.accent).pointerCursor()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? p.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .onTapGesture { model.select(session.id) }
        .contextMenu { SessionContextMenu(session: session) }
    }

    var tag: String {
        switch session.status {
        case .exited: "FEITA"
        case .stopped: "PARADA"
        case .idle: "OCIOSA"
        default: StateColor.label(session.status).uppercased()
        }
    }
}

// MARK: - Adicionar projeto e importar workspace

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var path = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DialogHeader(title: "Adicionar projeto", description: "Uma pasta com repositório git.", symbol: "folder.badge.plus")
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Caminho")
                HStack(spacing: 8) {
                    TextField("/caminho/do/projeto", text: $path).fieldBox()
                    Button { pick() } label: { Image(systemName: "folder").font(.system(size: 12)) }
                        .buttonStyle(OutlineButtonStyle()).help("Escolher pasta")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Nome", hint: "opcional")
                TextField("Meu projeto", text: $name).fieldBox()
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(StateColor.failed) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Adicionar", action: add).buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction).disabled(path.isEmpty)
            }
        }
        .dialog(width: 460, palette: p)
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }

    func add() {
        guard let service = model.service else { return }
        do {
            var p = try service.ensureProject(at: (path as NSString).expandingTildeInPath)
            if !name.isEmpty && name != p.name {
                p.name = name
                try service.store.pool.write { db in try p.update(db) }
            }
            model.refreshSessions()
            model.openProject(p.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ImportWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State private var path = "~/"
    @State private var found: [URL] = []
    @State private var selected: Set<URL> = []
    @State private var scanned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DialogHeader(title: "Importar workspace",
                         description: "O Bando procura repositórios git até dois níveis abaixo da pasta. Você escolhe quais importar.",
                         symbol: "folder.badge.gearshape")
            HStack(spacing: 8) {
                TextField("Pasta com seus projetos", text: $path).fieldBox()
                Button { pick() } label: { Image(systemName: "folder").font(.system(size: 12)) }
                    .buttonStyle(OutlineButtonStyle()).help("Escolher pasta")
                Button("Procurar", action: scan).buttonStyle(OutlineButtonStyle()).keyboardShortcut(.defaultAction)
            }
            if scanned {
                HStack {
                    FieldLabel("\(found.count) repositórios encontrados")
                    Spacer()
                    Button(selected.count == found.count ? "Desmarcar todos" : "Marcar todos") {
                        selected = selected.count == found.count ? [] : Set(found)
                    }
                    .buttonStyle(.link)
                }
                List(found, id: \.self) { url in
                    Toggle(isOn: Binding(get: { selected.contains(url) }, set: { if $0 { selected.insert(url) } else { selected.remove(url) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(height: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border.opacity(2)))
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Importar \(selected.count)") { importSelected() }.buttonStyle(AccentButtonStyle()).disabled(selected.isEmpty)
            }
        }
        .dialog(width: 560, palette: p)
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path; scan() }
    }

    func scan() {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let known = Set(model.projects.map(\.path))
        var out: [URL] = []
        let fm = FileManager.default
        func visit(_ dir: URL, depth: Int) {
            guard depth <= 2, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ["node_modules", "Library", ".bando-worktrees"].contains(item.lastPathComponent) { continue }
                if fm.fileExists(atPath: item.appendingPathComponent(".git").path) {
                    if !known.contains(item.path) { out.append(item) }
                } else {
                    visit(item, depth: depth + 1)
                }
            }
        }
        if fm.fileExists(atPath: root.appendingPathComponent(".git").path), !known.contains(root.path) { out.append(root) }
        visit(root, depth: 1)
        found = out.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        selected = Set(found)
        scanned = true
    }

    func importSelected() {
        guard let service = model.service else { return }
        for url in selected { _ = try? service.ensureProject(at: url.path) }
        model.refreshSessions()
        model.sidebarMode = .projects
        dismiss()
    }
}
