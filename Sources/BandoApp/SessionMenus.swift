import AppKit
import BandoCore
import SwiftUI

/// Botão "Claude Code ⌄" do cabeçalho: troca agente, provider ou modelo
/// mantendo a sessão (worktree, branch e histórico).
struct AgentSwitcher: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var open = false

    var body: some View {
        let p = model.palette
        let name = model.config?.agents[session.agent]?.name ?? session.agent
        let provider = session.provider.flatMap { model.config?.providers[$0]?.name }
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(provider.map { "\(name) · \($0)" } ?? name).font(.system(size: 12.5)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(p.secondary)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? p.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help("Trocar agente, provider ou modelo")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AgentSwitcherPanel(session: session) { open = false }
                .environment(model)
                .environment(\.palette, p)
        }
    }
}

struct AgentSwitcherPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let session: Session
    let close: () -> Void
    @State private var agent = ""
    @State private var provider = "default"
    @State private var modelName = ""

    @State private var showOthers = false
    @State private var filter = ""
    @State private var handoff: HandoffMode = .summary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverLabel("Agente").padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            // Só os instalados à vista; os outros ficam recolhidos e com busca.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(installed, id: \.agent.id) { a in
                        AgentOption(item: a, selected: a.agent.id == agent, current: a.agent.id == session.agent) {
                            agent = a.agent.id; fixProvider()
                        }
                    }
                    if !notInstalled.isEmpty {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showOthers.toggle() } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle").font(.system(size: 12)).frame(width: 14)
                                Text("Instalar outros agentes").font(.system(size: 12.5))
                                Text("\(notInstalled.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.tertiary)
                                Spacer()
                                Image(systemName: showOthers ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(p.secondary)
                            .padding(.horizontal, 14).frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor()
                        if showOthers {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.tertiary)
                                TextField("Buscar agente", text: $filter)
                            }
                            .fieldBox(height: 28)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                            ForEach(notInstalled.filter { filter.isEmpty || $0.agent.name.localizedCaseInsensitiveContains(filter) }, id: \.agent.id) { a in
                                AgentOption(item: a, selected: false, current: false) { install(a.agent) }
                            }
                        }
                    }
                }
            }
            .frame(height: showOthers ? min(420, CGFloat(installed.count) * 38 + 34 + 40 + CGFloat(notInstalled.count) * 38) : CGFloat(installed.count) * 38 + 34)
            DialogDivider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Provider")
                        SelectField(selection: $provider, options: providers.map { ($0.id, $0.name) })
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Modelo", hint: "opcional")
                        TextField(model.config?.providers[provider]?.models.first ?? "padrão", text: $modelName).fieldBox()
                    }
                }
                if agent != session.agent {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Levar para o novo agente")
                        SelectField(selection: $handoff, options: HandoffMode.allCases.map { ($0, $0.label) })
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(p.tertiary).padding(.top, 1)
                    Text(note).font(.system(size: 11.5)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancelar", action: close).buttonStyle(OutlineButtonStyle())
                    Button(agent == session.agent ? "Reiniciar" : "Trocar para \(model.config?.agents[agent]?.name ?? agent)") {
                        apply()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(width: 360)
        .onAppear {
            agent = session.agent
            provider = session.provider ?? "default"
            modelName = session.model ?? ""
            handoff = model.handoffDefault
        }
    }

    var installed: [AgentAvailability] { agents.filter { $0.isInstalled || $0.agent.id == session.agent } }
    var notInstalled: [AgentAvailability] { agents.filter { !$0.isInstalled && $0.agent.id != session.agent } }

    var agents: [AgentAvailability] {
        let current = model.availability[session.agent]
        let rest = model.availability.values.filter { $0.agent.id != session.agent && $0.agent.id != "shell" }
            .sorted { ($0.isInstalled ? 0 : 1, $0.agent.name) < ($1.isInstalled ? 0 : 1, $1.agent.name) }
        return (current.map { [$0] } ?? []) + rest
    }

    var providers: [ProviderDefinition] {
        (model.config?.providers(for: agent) ?? [])
            .sorted { ($0.id == "default" ? 0 : 1, $0.name) < ($1.id == "default" ? 0 : 1, $1.name) }
    }

    var changed: Bool {
        agent != session.agent || provider != (session.provider ?? "default") || modelName != (session.model ?? "")
    }

    var note: String {
        if agent == session.agent {
            return "Mesmo agente: reinicia retomando a mesma conversa, agora com o provider e o modelo escolhidos."
        }
        switch handoff {
        case .summary: return "O agente atual escreve .bando/handoff.md (comandos, decisões, pendências) e o novo começa lendo esse arquivo. O texto do pedido fica em Ajustes > Geral."
        case .transcript: return "O Bando exporta a conversa inteira para .bando/handoff.md (só a partir do Claude Code) e o novo agente começa lendo."
        case .none: return "O novo agente começa só com a tarefa original e o código como está."
        }
    }

    func fixProvider() {
        if !providers.contains(where: { $0.id == provider }) { provider = "default" }
    }

    func apply() {
        let id = session.id, a = agent
        let prov = provider == "default" ? nil : provider
        let m = modelName.isEmpty ? nil : modelName
        close()
        model.swapAgent(id, agent: a, provider: prov, model: m, handoff: a == session.agent ? .none : handoff)
    }

    /// Instala num Terminal à parte, com o comando do preset à vista.
    func install(_ a: AgentDefinition) {
        guard let cmd = a.install else { return }
        close()
        let script = "tell application \"Terminal\" to do script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSApp.activate()
    }
}

struct AgentOption: View {
    @Environment(\.palette) private var p
    let item: AgentAvailability
    let selected: Bool
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0).foregroundStyle(p.accent).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.agent.name).font(.system(size: 13))
                            .foregroundStyle(item.isInstalled ? p.text : p.tertiary)
                        if current {
                            Text("atual").font(.system(size: 10, weight: .medium)).foregroundStyle(p.secondary)
                                .padding(.horizontal, 5).frame(height: 16)
                                .background(RoundedRectangle(cornerRadius: 4).fill(p.hover))
                        }
                    }
                    Text(item.isInstalled ? (item.version ?? "instalado") : "Não instalado")
                        .font(.system(size: 11)).foregroundStyle(p.tertiary).lineLimit(1)
                }
                Spacer()
                if !item.isInstalled && item.agent.install != nil {
                    Text("Instalar").font(.system(size: 11, weight: .medium)).foregroundStyle(p.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(p.border.opacity(2)))
                }
            }
            .padding(.horizontal, 10).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? p.hover : .clear))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

/// Ações da sessão, num lugar só: o menu nativo (clique direito) e o menu
/// próprio do botão "⋯" usam a mesma lista.
struct SessionAction: Identifiable {
    enum Kind { case normal, destructive, separator, dependency }
    let id: String
    var title = ""
    var symbol = ""
    var kind: Kind = .normal
    var run: () -> Void = {}

    static func separator(_ id: String) -> SessionAction { SessionAction(id: id, kind: .separator) }

    @MainActor
    static func list(for session: Session, model: AppModel) -> [SessionAction] {
        let id = session.id
        var items: [SessionAction] = []
        if session.status.isLive {
            items.append(.init(id: "stop", title: "Parar sessão…", symbol: "stop.circle", kind: .destructive) { model.requestStop([id]) })
        } else {
            items.append(.init(id: "resume", title: "Retomar sessão", symbol: "play.circle") { model.resumeSession(id) })
        }
        items.append(.init(id: "pin", title: session.pinned ? "Desafixar" : "Fixar no topo", symbol: session.pinned ? "pin.slash" : "pin") {
            let v = !session.pinned; model.run("Fixar") { try $0.setPinned(id, v) }
        })
        items.append(.init(id: "rename", title: "Renomear…", symbol: "pencil") { model.renaming = session })
        items.append(.separator("s1"))
        items.append(.init(id: "term", title: "Novo terminal neste worktree", symbol: "terminal") {
            model.runReturning("Novo terminal") { try $0.newTerminal(id) }
        })
        items.append(.init(id: "fork", title: "Fork da sessão", symbol: "arrow.triangle.branch") {
            model.runReturning("Fork") { try $0.fork(id) }
        })
        items.append(.init(id: "dep", title: "Depende de", symbol: "link", kind: .dependency))
        items.append(.separator("s2"))
        let inGrid = model.gridMode && model.gridSessions.contains { $0.id == id }
        items.append(inGrid
            ? .init(id: "grid", title: "Tirar da grade", symbol: "square.grid.2x2") { model.removeFromGrid(id) }
            : .init(id: "grid", title: "Adicionar à grade", symbol: "square.grid.2x2") { model.showInGrid(id) })
        items.append(.init(id: "alone", title: "Abrir só esta", symbol: "arrow.up.left.and.arrow.down.right") { model.openAlone(id) })
        items.append(.init(id: "hide", title: session.hidden ? "Mostrar na lateral" : "Esconder da lateral", symbol: session.hidden ? "eye" : "eye.slash") {
            let v = !session.hidden; model.run("Esconder") { try $0.setHidden(id, v) }
        })
        items.append(.separator("s3"))
        items.append(.init(id: "finder", title: "Mostrar no Finder", symbol: "folder") { model.reveal(session) })
        items.append(.init(id: "copyid", title: "Copiar ID da sessão", symbol: "number") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
        })
        items.append(.init(id: "copypath", title: "Copiar caminho do worktree", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.worktreePath, forType: .string)
        })
        items.append(.separator("s4"))
        items.append(.init(id: "delete", title: "Apagar sessão e worktree…", symbol: "trash", kind: .destructive) { model.requestDelete([id]) })
        return items
    }
}

/// Menu nativo (clique direito), com os mesmos ícones.
struct SessionContextMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        ForEach(SessionAction.list(for: session, model: model)) { item in
            switch item.kind {
            case .separator: Divider()
            case .dependency:
                Menu { DependencyItems(session: session) } label: { Label(item.title, systemImage: item.symbol) }
            case .destructive:
                Button(role: .destructive, action: item.run) { Label(item.title, systemImage: item.symbol) }
            case .normal:
                Button(action: item.run) { Label(item.title, systemImage: item.symbol) }
            }
        }
    }
}

struct DependencyItems: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var candidates: [Session] {
        model.sessions.filter { $0.id != session.id && ($0.status.isLive || $0.status == .queued) }
    }

    var body: some View {
        Button("Nenhuma") { let id = session.id; model.run("Dependência") { try $0.setDependency(id, parent: nil) } }
        Divider()
        ForEach(candidates) { other in
            Button((session.dependsOn == other.id ? "✓ " : "") + other.name) {
                let id = session.id, parent = other.id
                model.run("Dependência") { try $0.setDependency(id, parent: parent) }
            }
        }
    }
}

/// Botão "⋯" com o menu próprio do Bando (visual do tema, ícones, ações
/// perigosas em vermelho), no lugar do menu padrão do macOS.
struct SessionActionsButton: View {
    @Environment(AppModel.self) private var model
    let session: Session
    var size: CGFloat = 14
    /// Avisa quem mostra o botão só no hover: com o menu aberto o botão precisa
    /// continuar na tela, senão o menu perde a âncora e para de responder.
    var onOpenChange: ((Bool) -> Void)? = nil
    /// Estado do menu guardado por quem mostra o botão: muda no mesmo instante
    /// do clique, sem o botão sumir e o popover reabrir.
    var openBinding: Binding<Bool>? = nil
    @State private var localOpen = false

    private var open: Bool {
        get { openBinding?.wrappedValue ?? localOpen }
        nonmutating set { if let openBinding { openBinding.wrappedValue = newValue } else { localOpen = newValue } }
    }

    var body: some View {
        let p = model.palette
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis").font(.system(size: size, weight: .semibold)).foregroundStyle(p.secondary)
                .frame(width: size + 14, height: size + 12)
                .background(RoundedRectangle(cornerRadius: 6).fill(open ? p.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .tooltip("Mais ações")
        .popover(isPresented: openBinding ?? $localOpen, arrowEdge: .bottom) {
            SessionActionsPanel(session: session) { open = false }
                .environment(model)
                .environment(\.palette, p)
        }
        .onChange(of: open) { _, v in onOpenChange?(v) }
    }
}

struct SessionActionsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let session: Session
    let close: () -> Void
    @State private var showDependency = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(session.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle().fill(StateColor.dot(session.status) ?? p.tertiary).frame(width: 6, height: 6)
                    Text(StateColor.label(session.status)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.secondary)
                }
                .padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(p.hover))
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
            Rectangle().fill(p.border).frame(height: 1).padding(.horizontal, -6).padding(.bottom, 4)
            ForEach(SessionAction.list(for: session, model: model)) { item in
                switch item.kind {
                case .separator:
                    Rectangle().fill(p.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, -6)
                case .dependency:
                    ActionItem(symbol: item.symbol, title: item.title, color: p.text,
                               trailing: showDependency ? "chevron.down" : "chevron.right") {
                        withAnimation(.easeOut(duration: 0.15)) { showDependency.toggle() }
                    }
                    if showDependency { dependencyList }
                default:
                    ActionItem(symbol: item.symbol, title: item.title,
                               color: item.kind == .destructive ? StateColor.failed : p.text) {
                        close(); item.run()
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 260)
        .background(p.card)
    }

    var dependencyList: some View {
        let candidates = model.sessions.filter { $0.id != session.id && ($0.status.isLive || $0.status == .queued) }
        return VStack(alignment: .leading, spacing: 0) {
            ActionItem(symbol: session.dependsOn == nil ? "checkmark" : "", title: "Nenhuma", color: p.secondary) {
                close(); let id = session.id; model.run("Dependência") { try $0.setDependency(id, parent: nil) }
            }
            ForEach(candidates) { other in
                ActionItem(symbol: session.dependsOn == other.id ? "checkmark" : "", title: other.name, color: p.secondary) {
                    close(); let id = session.id, parent = other.id
                    model.run("Dependência") { try $0.setDependency(id, parent: parent) }
                }
            }
        }
        .padding(.leading, 18)
    }
}

/// Linha do menu próprio: ícone de 14 pt, texto de 13 pt, fundo no hover.
struct ActionItem: View {
    @Environment(\.palette) private var p
    let symbol: String
    let title: String
    let color: Color
    var trailing: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol.isEmpty ? "circle" : symbol).font(.system(size: 12))
                    .foregroundStyle(color == p.text ? (hovering ? p.text : p.secondary) : color)
                    .opacity(symbol.isEmpty ? 0 : 1).frame(width: 16)
                Text(title).font(.system(size: 13)).lineLimit(1).foregroundStyle(color)
                Spacer(minLength: 6)
                if let trailing { Image(systemName: trailing).font(.system(size: 9, weight: .semibold)).foregroundStyle(p.tertiary) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? (color == p.text || color == p.secondary ? p.hover : color.opacity(0.10)) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let session: Session
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DialogHeader(title: "Renomear sessão", description: "O nome aparece na lateral e na grade.", symbol: "pencil")
            TextField("Nome", text: $name).fieldBox().onSubmit(save)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Salvar", action: save).buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .dialog(width: 400, palette: p)
        .onAppear { name = session.name }
    }

    func save() {
        let id = session.id, n = name
        model.run("Renomear") { try $0.rename(id, to: n) }
        dismiss()
    }
}
