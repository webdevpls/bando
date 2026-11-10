import BandoCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var showFinished = false
    @State private var collapsed: Set<String> = []
    @State private var expandedStopped: Set<String> = []
    @State private var scrolledFromTop = false
    @AppStorage("sidebarCompact") private var compact = false
    @State private var query = ""

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.sidebarMode == .projects {
                    ActionRow(symbol: "arrow.left", title: "Voltar às sessões", shortcut: nil) {
                        model.sidebarMode = .byProject
                        model.route = .sessions
                    }
                    NewProjectRow()
                } else {
                    ActionRow(symbol: "square.and.pencil", title: "Nova sessão", shortcut: "⌘N") { model.openComposer() }
                    ActionRow(symbol: "folder", title: "Projetos", shortcut: nil) { model.sidebarMode = .projects }
                    ActionRow(symbol: model.sidebarMode == .byProject ? "list.bullet" : "square.stack",
                              title: model.sidebarMode == .byProject ? "Agrupar por estado" : "Agrupar por projeto", shortcut: nil) {
                        model.sidebarMode = model.sidebarMode == .byProject ? .byStatus : .byProject
                    }
                }
                SidebarSearch(query: $query, placeholder: model.sidebarMode == .projects ? "Buscar projeto" : "Buscar projeto ou sessão")
                    .padding(.top, 6)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)

            Rectangle().fill(scrolledFromTop ? p.border : .clear).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch model.sidebarMode {
                    case .projects: projectList
                    case _ where searching: searchResults
                    case .byProject: byProject; hiddenSection
                    case .byStatus: byStatus; hiddenSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("sidebar")).minY)
                })
            }
            .coordinateSpace(name: "sidebar")
            .onPreferenceChange(ScrollOffsetKey.self) { scrolledFromTop = $0 < -2 }
            .scrollIndicators(.never)
            .overlay {
                if model.sessions.filter({ !$0.hidden }).isEmpty && model.loadError == nil {
                    Text("Nenhuma sessão ativa").font(.system(size: 14)).foregroundStyle(p.secondary)
                }
            }

            footer
        }
    }

    // Por projeto (padrão): fixadas primeiro, depois cada projeto com sessões ativas.
    @ViewBuilder var byProject: some View {
        let visible = model.sessions.filter { !$0.hidden }
        let pinned = visible.filter(\.pinned)
        if !pinned.isEmpty {
            GroupHeader(title: "Fixadas", symbol: "pin", first: true, collapsed: collapsed.contains("_pinned")) { toggle("_pinned") }
            if !collapsed.contains("_pinned") { TreeChildren { ForEach(pinned) { SessionRow(session: $0) } } }
        }
        let groups = model.projects.compactMap { project -> (Project, [Session])? in
            let list = visible.filter { $0.projectId == project.id && !$0.pinned &&
                ($0.status.isLive || $0.status == .queued || $0.status == .error) }
                .sorted { ($0.status.urgency, $1.statusChangedAt) < ($1.status.urgency, $0.statusChangedAt) }
            return list.isEmpty && stopped(of: project.id).isEmpty ? nil : (project, list)
        }
        .sorted { ($0.0.isGeneral ? 0 : 1, $0.1.map(\.status.urgency).min() ?? 9, $0.0.name)
                < ($1.0.isGeneral ? 0 : 1, $1.1.map(\.status.urgency).min() ?? 9, $1.0.name) }
        ForEach(Array(groups.enumerated()), id: \.element.0.id) { i, g in
            let quiet = g.1.isEmpty   // só sessões paradas: cabeçalho abre direto a lista
            let isCollapsed = quiet ? !expandedStopped.contains(g.0.id) : collapsed.contains(g.0.id)
            GroupHeader(title: g.0.name, symbol: g.0.isGeneral ? "tray" : "folder", count: g.1.count + stopped(of: g.0.id).count,
                        live: g.1.filter { $0.status.isLive }.count,
                        first: i == 0 && pinned.isEmpty, collapsed: isCollapsed,
                        marked: model.projectSelection.contains(g.0.id),
                        selecting: model.isSelecting,
                        newSession: { model.openComposer(project: g.0.id) },
                        onHide: quiet ? { model.hideProjects([g.0.id]) } : nil,
                        onCommandClick: { model.toggleProjectMark(g.0.id) },
                        dragPayload: "project:\(g.0.id)") {
                if model.isSelecting {
                    model.toggleProjectMark(g.0.id)
                } else if quiet {
                    if expandedStopped.contains(g.0.id) { expandedStopped.remove(g.0.id) } else { expandedStopped.insert(g.0.id) }
                } else {
                    toggle(g.0.id)
                }
            }
            if quiet {
                if !isCollapsed {
                    TreeChildren { ForEach(stopped(of: g.0.id).prefix(30)) { SessionRow(session: $0, showProject: false, dimmed: true) } }
                }
            } else if !collapsed.contains(g.0.id) {
              TreeChildren {
                ForEach(g.1) { SessionRow(session: $0, showProject: false) }
                StoppedToggle(project: g.0, expanded: expandedStopped.contains(g.0.id)) {
                    if expandedStopped.contains(g.0.id) { expandedStopped.remove(g.0.id) } else { expandedStopped.insert(g.0.id) }
                }
                if expandedStopped.contains(g.0.id) {
                    TreeChildren { ForEach(stopped(of: g.0.id).prefix(30)) { SessionRow(session: $0, showProject: false, dimmed: true) } }
                }
              }
            }
        }
        // Sessões cujo projeto foi removido do Bando (o worktree pode ainda existir).
        let known = Set(model.projects.map(\.id))
        let orphans = visible.filter { !known.contains($0.projectId) && !$0.pinned }
            .sorted { $0.updatedAt > $1.updatedAt }
        if !orphans.isEmpty {
            GroupHeader(title: "Sem projeto", symbol: "questionmark.folder", first: groups.isEmpty && pinned.isEmpty, collapsed: collapsed.contains("_orphans")) { toggle("_orphans") }
            if !collapsed.contains("_orphans") { TreeChildren { ForEach(orphans.prefix(50)) { SessionRow(session: $0, showProject: false) } } }
        }
    }

    /// Resultado da busca: projeto cujo nome bate aparece inteiro; senão, só as
    /// sessões cujo nome ou branch batem. Tudo expandido.
    @ViewBuilder var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let results = searchGroups(q)
        if results.isEmpty {
            Text("Nada encontrado para \u{201C}\(q)\u{201D}").font(.system(size: 12.5)).foregroundStyle(p.tertiary)
                .frame(maxWidth: .infinity).padding(.top, 24)
        }
        ForEach(Array(results.enumerated()), id: \.element.0.id) { i, g in
            GroupHeader(title: g.0.name, symbol: g.0.isGeneral ? "tray" : "folder", count: g.1.count,
                        live: g.1.filter { $0.status.isLive }.count, first: i == 0, collapsed: false,
                        newSession: { model.openComposer(project: g.0.id) }) { model.openProject(g.0.id) }
            TreeChildren {
                ForEach(g.1.prefix(30)) { s in
                    SessionRow(session: s, showProject: false, dimmed: !s.status.isLive && s.status != .queued && s.status != .error)
                }
            }
        }
    }

    func searchGroups(_ q: String) -> [(Project, [Session])] {
        func hit(_ text: String?) -> Bool { text?.localizedCaseInsensitiveContains(q) ?? false }
        func order(_ a: Session, _ b: Session) -> Bool {
            (a.status.isLive ? 0 : 1, a.status.urgency, b.updatedAt) < (b.status.isLive ? 0 : 1, b.status.urgency, a.updatedAt)
        }
        return model.projects.compactMap { project -> (Project, [Session])? in
            let all = model.sessions.filter { $0.projectId == project.id }
            let list = hit(project.name) ? all : all.filter { hit($0.name) || hit($0.branch) }
            return list.isEmpty && !hit(project.name) ? nil : (project, list.sorted(by: order))
        }
        .sorted { ($0.1.contains { $0.status.isLive } ? 0 : 1, $0.0.name) < ($1.1.contains { $0.status.isLive } ? 0 : 1, $1.0.name) }
    }

    /// Sessões escondidas da lateral: ficam numa linha recolhida no fim. O menu
    /// da sessão tem "Mostrar na lateral" para trazê-las de volta.
    @ViewBuilder var hiddenSection: some View {
        let hidden = model.sessions.filter(\.hidden).sorted { $0.updatedAt > $1.updatedAt }
        if !hidden.isEmpty {
            Button { if expandedStopped.contains("_hidden") { expandedStopped.remove("_hidden") } else { expandedStopped.insert("_hidden") } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expandedStopped.contains("_hidden") ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Image(systemName: "eye.slash").font(.system(size: 10))
                    Text("\(hidden.count) oculta\(hidden.count == 1 ? "" : "s")").font(.system(size: 11.5))
                    Spacer()
                }
                .foregroundStyle(p.tertiary)
                .padding(.horizontal, 10).frame(height: 26).padding(.top, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            if expandedStopped.contains("_hidden") {
                ForEach(hidden.prefix(50)) { SessionRow(session: $0).opacity(0.75) }
            }
        }
    }

    func stopped(of projectId: String) -> [Session] {
        model.sessions.filter { $0.projectId == projectId && !$0.hidden && !$0.pinned && ($0.status == .stopped || $0.status == .exited) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Modo "Projetos": lista com contagem; clique abre a página do projeto.
    @ViewBuilder var projectList: some View {
        let counts = Dictionary(grouping: model.sessions, by: \.projectId).mapValues(\.count)
        let q = query.trimmingCharacters(in: .whitespaces)
        ForEach(model.projects.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }.sorted { ($0.isGeneral ? 0 : 1, $1.lastUsedAt ?? .distantPast) < ($1.isGeneral ? 0 : 1, $0.lastUsedAt ?? .distantPast) }) { proj in
            ProjectRow(project: proj, count: counts[proj.id] ?? 0, selected: model.route == .project(proj.id)) {
                model.openProject(proj.id)
            }
        }
    }

    @ViewBuilder var byStatus: some View {
        ForEach(Array(model.groups.enumerated()), id: \.element.title) { i, group in
            GroupHeader(title: group.title, symbol: Self.statusSymbol(group.title), count: group.sessions.count,
                        first: i == 0, collapsed: collapsed.contains(group.title)) { toggle(group.title) }
            if !collapsed.contains(group.title) { TreeChildren { ForEach(group.sessions) { SessionRow(session: $0) } } }
        }
        finished
    }

    @ViewBuilder var finished: some View {
        if !model.finishedSessions.isEmpty {
            GroupHeader(title: "Paradas e encerradas", symbol: "stop.circle", count: model.finishedSessions.count, first: false, collapsed: !showFinished) {
                showFinished.toggle()
            }
            if showFinished {
                TreeChildren { ForEach(model.finishedSessions.prefix(80)) { SessionRow(session: $0, dimmed: true) } }
            }
        }
    }

    /// Chaves de todos os grupos visíveis no modo atual (para recolher tudo).
    var allGroupKeys: Set<String> {
        switch model.sidebarMode {
        case .byStatus: return Set(model.groups.map(\.title))
        default: return Set(model.projects.map(\.id)).union(["_pinned", "_orphans"])
        }
    }

    static func statusSymbol(_ title: String) -> String {
        switch title {
        case "Fixadas": "pin"
        case "Esperando você": "bubble.left"
        case "Com erro": "exclamationmark.triangle"
        case "Pronto para revisar": "checkmark.circle"
        case "Trabalhando": "bolt"
        case "Na fila": "clock"
        case "Ociosas": "moon"
        default: "circle"
        }
    }

    func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    @ViewBuilder var footer: some View {
        if model.isSelecting { selectionFooter } else { normalFooter }
    }

    /// Modo de seleção: o rodapé vira a barra de ações em lote, para sessões
    /// e projetos marcados.
    var selectionFooter: some View {
        let ids = Array(model.multiSelection)
        let projects = model.projectSelection
        let liveIds = ids.filter { model.session($0)?.status.isLive == true }
        var parts: [String] = []
        if !ids.isEmpty { parts.append("\(ids.count) \(ids.count == 1 ? "sessão" : "sessões")") }
        if !projects.isEmpty { parts.append("\(projects.count) projeto\(projects.count == 1 ? "" : "s")") }
        return HStack(spacing: 2) {
            Text(parts.isEmpty ? "Marque sessões ou projetos" : parts.joined(separator: " · "))
                .font(.system(size: 12, weight: parts.isEmpty ? .regular : .medium))
                .foregroundStyle(parts.isEmpty ? p.tertiary : p.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !liveIds.isEmpty {
                IconButton(symbol: "stop.circle", help: "Parar as sessões marcadas") { model.requestStop(liveIds) }
            }
            if !ids.isEmpty {
                IconButton(symbol: "trash", help: "Apagar as sessões marcadas") { model.requestDelete(ids) }
            }
            if !projects.isEmpty {
                IconButton(symbol: "eye.slash", help: "Tirar os projetos da lateral (nada é apagado)") { model.hideProjects(projects) }
            }
            Button("Concluir") { model.endSelection() }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.leading, 4)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
        .background(p.accent.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    var normalFooter: some View {
        HStack(spacing: 2) {
            let waiting = model.counts.waiting
            if waiting > 0 {
                Button { model.selectNextWaiting() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(StateColor.waiting).frame(width: 6, height: 6)
                        Text("\(waiting) esperando").font(.system(size: 12)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(StateColor.waiting)
                }
                .buttonStyle(.plain).pointerCursor().help("Ir para a próxima esperando você (⌘J)")
            } else {
                let live = model.sessions.filter(\.status.isLive).count
                HStack(spacing: 6) {
                    Circle().fill(live > 0 ? StateColor.working : p.tertiary).frame(width: 6, height: 6)
                    Text("\(live) ativa\(live == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(p.secondary)
                        .lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 4)
            if model.sidebarMode != .projects {
                IconButton(symbol: "checklist", help: "Selecionar várias sessões ou projetos") { model.selectMode = true }
            }
            if model.sessions.contains(where: \.status.isLive) {
                IconButton(symbol: "stop.circle", help: "Parar todas as sessões") { model.requestStop(model.sessions.filter(\.status.isLive).map(\.id)) }
            }
            IconButton(symbol: "square.grid.2x2", help: "Grade (⌥⌘G)") { model.toggleGrid() }
            // Opções de exibição menos usadas ficam num menu nativo.
            Menu {
                if model.sidebarMode != .projects {
                    Button { if collapsed.isEmpty { collapsed = allGroupKeys; expandedStopped = [] } else { collapsed = [] } } label: {
                        Label(collapsed.isEmpty ? "Recolher todos os grupos" : "Expandir todos os grupos", systemImage: "chevron.up.chevron.down")
                    }
                }
                Toggle(isOn: $compact) { Label("Cartões compactos", systemImage: "arrow.down.and.line.horizontal.and.arrow.up") }
                Divider()
                Button { Task { await model.reload() } } label: { Label("Recarregar configuração", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(p.secondary)
                    .frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tooltip("Exibição")
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Cabeçalho de grupo: 12 pt negrito cinza; seta e "+" só no hover.
struct GroupHeader: View {
    @Environment(\.palette) private var p
    let title: String
    var symbol: String? = nil
    /// Número de sessões do grupo, mostrado como badge quando recolhido.
    var count: Int? = nil
    /// Sessões ativas do grupo: badge verde com quantas estão ativas; sem ativas e
    /// recolhido, badge cinza com o total.
    var live = 0
    let first: Bool
    let collapsed: Bool
    /// Marcado para ação em lote; `selecting` mostra a caixinha em todos.
    var marked = false
    var selecting = false
    var newSession: (() -> Void)? = nil
    /// "Tirar da lateral" no hover (só projetos sem sessão ativa).
    var onHide: (() -> Void)? = nil
    /// Cmd+clique: marca para ação em lote.
    var onCommandClick: (() -> Void)? = nil
    /// Texto arrastado para a grade ("project:<id>"), se o grupo for um projeto.
    var dragPayload: String? = nil
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if selecting {
                Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12)).foregroundStyle(marked ? p.accent : p.tertiary).frame(width: 12)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(p.tertiary).frame(width: 12)
            }
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.secondary).lineLimit(1)
            let active = live > 0
            if let count, count > 0, collapsed || active {
                let shown = active ? live : count
                Text("\(shown)").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(active ? StateColor.working : p.secondary)
                    .padding(.horizontal, 5).frame(minWidth: 16).frame(height: 15)
                    .background(Capsule().fill(active ? StateColor.working.opacity(0.14) : p.hover))
                    .overlay(Capsule().strokeBorder(active ? StateColor.working.opacity(0.4) : p.border))
                    .help(active ? "\(live) \(live == 1 ? "ativa" : "ativas") de \(count)" : "\(count) \(count == 1 ? "sessão" : "sessões")")
            }
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(p.tertiary)
                .frame(width: 10)
                .opacity(hovering || collapsed ? 1 : 0)
            Spacer()
            if hovering && !selecting {
                if let onHide {
                    RowAction(symbol: "eye.slash", help: "Tirar da lateral", action: onHide)
                }
                if let newSession {
                    RowAction(symbol: "plus", help: "Nova sessão neste projeto", action: newSession)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(marked ? p.accent.opacity(0.10) : (hovering ? p.hover : .clear)))
        .padding(.top, first ? 0 : 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .gesture(TapGesture().modifiers(.command).onEnded { onCommandClick?() ?? toggle() })
        .onTapGesture(perform: toggle)
        .draggable(dragPayload ?? "") {
            Label(title, systemImage: "folder").font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.card))
        }
    }
}

struct ActionRow: View {
    @Environment(\.palette) private var p
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(p.secondary).frame(width: 14)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut, hovering { Text(shortcut).font(.system(size: 11)).foregroundStyle(p.tertiary) }
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? p.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

/// Linha de sessão: título 14 pt (negrito se aberta), branch em 11 pt mono,
/// ponto de estado à direita; no hover o ponto vira "⋯".
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let session: Session
    var showProject = true
    /// Sessão parada dentro do grupo "N paradas": texto apagado, sem marca de estado.
    var dimmed = false
    @State private var hovering = false
    @State private var menuOpen = false
    @AppStorage("sidebarCompact") private var compact = false

    var isSelected: Bool { model.selection == session.id }
    var isMarked: Bool { model.multiSelection.contains(session.id) }
    var inGrid: Bool { model.gridMode && model.gridSessions.contains { $0.id == session.id } }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if model.isSelecting {
                Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).foregroundStyle(isMarked ? p.accent : p.tertiary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(dimmed && !isSelected && !hovering ? p.secondary : p.text)
                    .lineLimit(1)
                if let line = secondLine {
                    HStack(spacing: 4) {
                        if let icon = line.icon {
                            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(line.color.opacity(0.8))
                        }
                        Text(line.text)
                            .font(.system(size: 11, design: line.mono ? .monospaced : .default))
                            .foregroundStyle(line.color)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            // Altura fixa de 16: os botões do hover (24 pt) não mudam a altura da linha.
            Group {
                if (hovering || menuOpen) && !model.isSelecting { hoverActions } else { stateMark.frame(width: 18) }
            }
            .frame(height: 16)
            .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isMarked ? p.accent.opacity(0.5) : .clear))
        .overlay(alignment: .leading) {
            if inGrid { Capsule().fill(StateColor.working.opacity(0.6)).frame(width: 2, height: 14).offset(x: 2) }
        }
        .opacity(session.status == .queued ? (hovering ? 0.8 : 0.6) : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .gesture(TapGesture().modifiers(.command).onEnded { model.toggleMulti(session.id) })
        .onTapGesture(count: 2) { if !model.isSelecting { model.openAlone(session.id) } }
        .onTapGesture {
            // No modo de seleção, clique simples marca.
            if model.isSelecting { model.toggleMulti(session.id) } else { model.select(session.id) }
        }
        .draggable(session.id)
        .contextMenu { SessionContextMenu(session: session) }
        .help(tooltip)
    }

    /// Segunda linha: a pergunta pendente (esperando), o erro, a fila, ou a branch.
    var secondLine: (text: String, mono: Bool, color: Color, icon: String?)? {
        switch session.status {
        case .waiting: return (session.statusDetail ?? "esperando você", false, StateColor.waiting, "bubble.left")
        case .error: return (session.statusDetail ?? "falhou", false, StateColor.failed, "exclamationmark.triangle")
        case .queued: return ("na fila", false, p.secondary, "clock")
        default: break
        }
        if compact { return nil }
        var parts: [String] = []
        if showProject, let proj = model.project(session.projectId) { parts.append(proj.name) }
        if let b = session.branch { parts.append(b) }
        if dimmed { return nil }
        return parts.isEmpty ? nil : (parts.joined(separator: " · "), true, p.tertiary, nil)
    }

    var background: Color {
        if isMarked { return p.accent.opacity(0.10) }
        if isSelected { return p.selected }
        return hovering ? p.hover : .clear
    }

    /// Parar (se ativa), apagar e o menu completo; ocupam o lugar do ponto de estado.
    var hoverActions: some View {
        HStack(spacing: 0) {
            if session.status.isLive {
                RowAction(symbol: "stop.circle", help: "Parar sessão…") { model.requestStop([session.id]) }
            }
            RowAction(symbol: "trash", help: "Apagar sessão e worktree…", destructive: true) {
                model.requestDelete([session.id])
            }
            SessionActionsButton(session: session, size: 12, openBinding: $menuOpen)
        }
        .fixedSize()
    }

    @ViewBuilder var stateMark: some View {
        if let color = StateColor.dot(session.status) {
            Circle().fill(color).frame(width: 8, height: 8)
                .frame(width: 18)
        } else {
            Color.clear.frame(width: 18, height: 8)
        }
    }

    var tooltip: String {
        var lines = [session.name, session.status.label]
        if let proj = model.project(session.projectId) { lines.append(proj.name) }
        lines.append(session.worktreePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        if let b = session.branch { lines.append(b) }
        lines.append([model.config?.agents[session.agent]?.name ?? session.agent, session.provider, session.model]
            .compactMap { $0 }.joined(separator: " · "))
        if let d = session.dependsOn, let parent = model.session(d) { lines.append("Depende de \(parent.name)") }
        return lines.joined(separator: "\n")
    }
}

struct SessionInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.selectedSession {
            Form {
                Section("Sessão") {
                    LabeledContent("Estado") { HStack { StatusIcon(status: s.status, size: 10); Text(s.status.label) } }
                    if let d = s.statusDetail { LabeledContent("Detalhe", value: d) }
                    LabeledContent("Agente", value: model.config?.agents[s.agent]?.name ?? s.agent)
                    LabeledContent("Provider", value: s.provider.flatMap { model.config?.providers[$0]?.name } ?? "login da CLI")
                    if let m = s.model { LabeledContent("Modelo", value: m) }
                    LabeledContent("Criada", value: s.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("Código") {
                    if let proj = model.project(s.projectId) { LabeledContent("Projeto", value: proj.name) }
                    if let b = s.branch { LabeledContent("Branch", value: b) }
                    if let b = s.baseBranch { LabeledContent("Base", value: b) }
                    LabeledContent("Worktree") {
                        Text(s.worktreePath).lineLimit(3).truncationMode(.head).textSelection(.enabled)
                    }
                }
                if let prompt = s.prompt, !prompt.isEmpty {
                    Section("Tarefa") { Text(prompt).textSelection(.enabled) }
                }
                if let native = s.nativeId {
                    Section("Conversa do agente") { Text(native).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Nenhuma sessão", systemImage: "sidebar.right")
        }
    }
}


/// Linha "N paradas" dentro de cada projeto (recolhida por padrão).
struct StoppedToggle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let project: Project
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let ids = model.sessions.filter { $0.projectId == project.id && !$0.hidden && !$0.pinned && ($0.status == .stopped || $0.status == .exited) }.map(\.id)
        let n = ids.count
        if n > 0 {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text("\(n) \(n == 1 ? "sessão" : "sessões")").font(.system(size: 11.5))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(p.tertiary)
                .padding(.horizontal, 8).frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .overlay(alignment: .trailing) {
                if hovering {
                    Button("Selecionar") {
                        model.multiSelection.formUnion(ids)
                        if !expanded { toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(p.secondary)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.hover))
                    .pointerCursor().help("Marcar as \(n) sessões para apagar de uma vez")
                    .padding(.trailing, 4)
                }
            }
            .onHover { hovering = $0 }
        }
    }
}

struct ProjectRow: View {
    @Environment(\.palette) private var p
    let project: Project
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: project.isGeneral ? (selected ? "tray.fill" : "tray") : (selected ? "folder.fill" : "folder"))
                    .font(.system(size: 13)).foregroundStyle(p.secondary)
                Text(project.name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.tertiary) }
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? p.selected : (hovering ? p.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovering = $0 }
    }
}


/// "Novo projeto": adicionar uma pasta ou importar um workspace inteiro.
struct NewProjectRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var open = false

    var body: some View {
        ActionRow(symbol: "folder.badge.plus", title: "Novo projeto", shortcut: nil) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 2) {
                    PopoverLabel("Novo projeto").padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
                    OptionItem(symbol: "folder.badge.plus", title: "Adicionar projeto",
                               detail: "Uma pasta com repositório git") {
                        open = false; model.showAddProject = true
                    }
                    OptionItem(symbol: "square.stack.3d.down.right", title: "Importar workspace",
                               detail: "Procura vários repositórios numa pasta") {
                        open = false; model.showImportWorkspace = true
                    }
                }
                .padding(6).frame(width: 260)
                .background(p.card)
                .environment(\.palette, p)
            }
    }
}

/// Confirmação para parar uma ou várias sessões. Lista o que vai parar e
/// deixa claro que nada é apagado.
struct StopSessionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let ids: [String]

    var body: some View {
        let live = ids.compactMap { model.session($0) }.filter(\.status.isLive)
            .sorted { ($0.status.urgency, $0.name) < ($1.status.urgency, $1.name) }
        VStack(alignment: .leading, spacing: 16) {
            DialogHeader(title: live.count == 1 ? "Parar \u{201C}\(live[0].name)\u{201D}?" : "Parar \(live.count) sessões?",
                         description: live.count == 1
                            ? "O agente para agora. Worktree, branch e conversa ficam, e dá para retomar depois."
                            : "Os agentes param agora. Worktrees, branches e conversas ficam, e cada sessão pode ser retomada depois.",
                         symbol: "stop.circle")
            if live.count > 1 {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(live) { s in
                        HStack(spacing: 10) {
                            Circle().fill(StateColor.dot(s.status) ?? p.tertiary).frame(width: 6, height: 6)
                            Text(s.name).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(model.project(s.projectId)?.name ?? "").font(.system(size: 11.5)).foregroundStyle(p.tertiary).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        if s.id != live.last?.id { DialogDivider() }
                    }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border.opacity(2)))
            }
            if live.contains(where: { $0.status == .waiting }) {
                Label(live.count == 1 ? "Esta sessão está esperando resposta sua." : "Há sessões esperando resposta sua.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(StateColor.waiting)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(live.count == 1 ? "Parar" : "Parar \(live.count)") {
                    model.stopSessions(live.map(\.id))
                    model.multiSelection.subtract(live.map(\.id))
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle(tint: StateColor.failed))
                .keyboardShortcut(.defaultAction)
                .disabled(live.isEmpty)
            }
        }
        .dialog(width: 420, palette: p)
    }
}

/// Botão pequeno das ações do hover na linha da sessão.
struct RowAction: View {
    @Environment(\.palette) private var p
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? (destructive ? StateColor.failed : p.text) : p.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? p.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .tooltip(help)
    }
}

/// Confirmação de apagar uma ou várias sessões. Consulta a trava de cada uma
/// (mudança não commitada ou commit sem push) e só apaga essas se o usuário marcar.
struct DeleteSessionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let ids: [String]
    @State private var blockers: [String: String]? = nil
    @State private var includeUnsafe = false

    var body: some View {
        let list = ids.compactMap { model.session($0) }
        let unsafe = blockers.map { b in list.filter { b[$0.id] != nil } } ?? []
        let count = includeUnsafe ? list.count : list.count - unsafe.count
        VStack(alignment: .leading, spacing: 16) {
            DialogHeader(title: list.count == 1 ? "Apagar \u{201C}\(list.first?.name ?? "")\u{201D}?" : "Apagar \(list.count) sessões?",
                         description: "Remove a sessão e o worktree. A branch continua no git.",
                         symbol: "trash")
            if list.count > 1 || !unsafe.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(list) { s in
                            HStack(spacing: 10) {
                                Image(systemName: blockers?[s.id] == nil ? "circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: blockers?[s.id] == nil ? 5 : 10))
                                    .foregroundStyle(blockers?[s.id] == nil ? p.tertiary : StateColor.waiting)
                                    .frame(width: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name).font(.system(size: 13)).lineLimit(1)
                                    if let why = blockers?[s.id] {
                                        Text(why).font(.system(size: 11)).foregroundStyle(StateColor.waiting).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(model.project(s.projectId)?.name ?? "").font(.system(size: 11.5)).foregroundStyle(p.tertiary).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            if s.id != list.last?.id { DialogDivider() }
                        }
                    }
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border.opacity(2)))
            }
            if blockers == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Conferindo mudanças não salvas…").font(.system(size: 12)).foregroundStyle(p.secondary)
                }
            } else if !unsafe.isEmpty {
                Toggle(isOn: $includeUnsafe) {
                    Text(unsafe.count == 1 ? "Apagar também a que tem trabalho não salvo" : "Apagar também as \(unsafe.count) com trabalho não salvo")
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Apagar" : "Apagar \(count)") {
                    model.deleteSessions(list.map(\.id), force: includeUnsafe ? Set(unsafe.map(\.id)) : [])
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle(tint: StateColor.failed))
                .keyboardShortcut(.defaultAction)
                .disabled(blockers == nil || count == 0)
            }
        }
        .dialog(width: 440, palette: p)
        .task {
            guard let service = model.service else { blockers = [:]; return }
            let ids = self.ids
            blockers = await Task.detached {
                var out: [String: String] = [:]
                for id in ids { if let why = try? service.deleteBlocker(id) { out[id] = why } }
                return out
            }.value
        }
    }
}

/// Opção de popover com título e uma linha de explicação.
struct OptionItem: View {
    @Environment(\.palette) private var p
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12))
                    .foregroundStyle(hovering ? p.text : p.secondary)
                    .frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(p.text)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(p.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? p.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

/// Campo de busca da lateral: lupa, texto e botão de limpar. Esc limpa.
struct SidebarSearch: View {
    @Environment(\.palette) private var p
    @Binding var query: String
    var placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.tertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($focused)
                .onExitCommand { query = ""; focused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(p.tertiary)
                }
                .buttonStyle(.plain).pointerCursor().tooltip("Limpar busca")
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(focused ? p.panel.opacity(0.6) : p.hover))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? p.border.opacity(3) : p.border))
    }
}

/// Filhos de um grupo na lateral: recuados sob o ícone do cabeçalho, com uma
/// linha guia fina, como numa árvore.
struct TreeChildren<Content: View>: View {
    @Environment(\.palette) private var p
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                Rectangle().fill(p.border.opacity(1.5)).frame(width: 1).padding(.leading, 13).padding(.vertical, 2)
            }
    }
}
