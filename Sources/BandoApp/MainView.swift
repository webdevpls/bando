import BandoCore
import SwiftUI

/// Janela principal: moldura com barra superior própria, lateral e um painel
/// de conteúdo com cantos arredondados. Todas as cores vêm do tema.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let p = model.palette
        HStack(spacing: 8) {
            if model.showSidebar {
                Sidebar()
                    .frame(width: model.sidebarWidth)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .trailing) { SidebarResizer() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ContentPanel()
        }
        .padding([.horizontal, .bottom], 8)
        .padding(.top, 2)
        .background(p.chrome)
        .background(WindowChrome(color: p.chromeNS))
        .toolbar { TopBarItems() }
        .environment(\.palette, p)
        .foregroundStyle(p.text)
        .tint(p.accent)
        .preferredColorScheme(p.isDark ? .dark : .light)
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet().environment(\.palette, p) }
        .sheet(isPresented: $model.showPalette) { CommandPalette().environment(\.palette, p) }
        .sheet(isPresented: $model.showShortcuts) { ShortcutsSheet().environment(\.palette, p) }
        .sheet(item: $model.stopRequest) { StopSessionsSheet(ids: $0.sessionIds).environment(model).environment(\.palette, p) }
        .sheet(item: $model.deleteRequest) { DeleteSessionsSheet(ids: $0.sessionIds).environment(model).environment(\.palette, p) }
        .sheet(item: $model.renaming) { RenameSheet(session: $0).environment(model).environment(\.palette, p) }
        .sheet(isPresented: $model.showAddProject) { AddProjectSheet().environment(model).environment(\.palette, p) }
        .sheet(isPresented: $model.showImportWorkspace) { ImportWorkspaceSheet().environment(model).environment(\.palette, p) }
        .animation(.easeOut(duration: 0.2), value: model.showSidebar)
    }
}

/// Alça na borda da lateral: arrasta para mudar a largura (230 a 400 pt).
struct SidebarResizer: View {
    @Environment(AppModel.self) private var model
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? model.palette.border : .clear)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = model.sidebarWidth }
                    model.sidebarWidth = min(max((start ?? 250) + g.translation.width, 230), 400)
                }
                .onEnded { _ in start = nil })
            .offset(x: 4)
    }
}

// MARK: - Barra superior (barra de ferramentas nativa)

struct TopBarItems: ToolbarContent {
    var body: some ToolbarContent {
        // O macOS não mostra item central na barra compacta; a busca fica à
        // direita, como no Finder e no Mail.
        if #available(macOS 26.0, *) {
            // macOS 26: sem o fundo de "vidro" que o sistema põe nos itens, e com
            // espaço flexível para mandar os controles para a direita.
            ToolbarItem(placement: .navigation) { LeadingItems() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) { TrailingItems() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { LeadingItems() }
            ToolbarItem(placement: .primaryAction) { TrailingItems() }
        }
    }
}

struct LeadingItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "sidebar.left", help: "Mostrar ou esconder a lateral (⌃⌘S)", size: 16) { model.showSidebar.toggle() }
            HStack(spacing: 7) {
                BandoMark(size: 15)
                Text("bando").font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(p.text)
        }
        .environment(\.palette, model.palette)
    }
}

struct SearchField: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let p = model.palette
        Button { model.showPalette = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                Text("Buscar sessões").font(.system(size: 12.5))
                Spacer()
                Text("⌘K").font(.system(size: 11, weight: .medium)).foregroundStyle(p.tertiary)
            }
            .foregroundStyle(p.secondary)
            .padding(.horizontal, 12)
            .frame(width: 260, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.hover))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .tooltip("Buscar sessões (⌘K)")
    }
}

struct TrailingItems: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let p = model.palette
        HStack(spacing: 4) {
            SearchField().padding(.trailing, 6)
            let c = model.counts
            if c.waiting > 0 {
                Button { model.selectNextWaiting() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text("\(c.waiting) esperando")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).pointerCursor()
                .tooltip("Ir para a próxima sessão esperando você (⌘J)")
            }
            LayoutMenu()
            IconButton(symbol: "sidebar.right", help: "Detalhes da sessão (⌥⌘I)", size: 16) { model.showInspector.toggle() }
            ReportsButtons()
            HelpMenu()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(p.secondary)
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .tooltip("Ajustes (⌘,)")
        }
        .environment(\.palette, p)
    }
}

/// Escolha da grade: passe o mouse sobre o quadro 4×4 e clique.
struct LayoutMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: model.gridMode ? "square.grid.2x2" : "rectangle").font(.system(size: 16))
                if model.gridMode { Text("\(model.gridCols)×\(model.gridRows)").font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(p.secondary)
            .frame(height: 28).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .tooltip("Layout: uma sessão ou grade até 4×4 (⌥⌘G)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            GridPicker { cols, rows in
                model.setGrid(cols: cols, rows: rows)
                open = false
            }
            .environment(model)
        }
    }
}

struct GridPicker: View {
    @Environment(AppModel.self) private var model
    let choose: (Int, Int) -> Void
    @State private var hover: (Int, Int)?

    var body: some View {
        let p = model.palette
        let current = model.gridMode ? (model.gridCols, model.gridRows) : (1, 1)
        let shown = hover ?? current
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(1...AppModel.maxGrid, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(1...AppModel.maxGrid, id: \.self) { c in
                            let on = c <= shown.0 && r <= shown.1
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? p.accent.opacity(0.22) : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? p.accent.opacity(0.5) : p.border.opacity(2), lineWidth: 1))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                                .onHover { inside in if inside { hover = (c, r) } }
                                .pointerCursor()
                                .onTapGesture { choose(c, r) }
                        }
                    }
                }
            }
            .onHover { inside in if !inside { hover = nil } }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            Text(shown == (1, 1) ? "Uma sessão" : "\(shown.0) × \(shown.1)")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(p.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

            Rectangle().fill(p.border).frame(height: 1)
            VStack(spacing: 0) {
                MenuRow(symbol: "rectangle.stack.badge.plus", title: "Preencher com as ativas") { model.autoFillGrid() }
                MenuRow(symbol: "equal.square", title: "Igualar tamanhos") {
                    model.equalize(columns: true); model.equalize(columns: false)
                }
                MenuRow(symbol: model.dimUnfocused ? "circle.lefthalf.filled" : "circle", title: model.dimUnfocused ? "Não esmaecer os sem foco" : "Esmaecer os sem foco") {
                    model.dimUnfocused.toggle()
                }
                MenuRow(symbol: "rectangle.dashed", title: "Esvaziar grade") { model.emptyGrid() }
            }
            .padding(4)
            .disabled(!model.gridMode)
            .opacity(model.gridMode ? 1 : 0.4)
        }
        .frame(width: 260)
        .environment(\.palette, p)
    }
}

/// Linha de menu dos popovers: mesmo visual do menu da sessão.
struct MenuRow: View {
    @Environment(\.palette) private var p
    let symbol: String
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        ActionItem(symbol: symbol, title: title, color: p.text, trailing: nil, action: action)
            .overlay(alignment: .trailing) {
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(p.tertiary).padding(.trailing, 10).allowsHitTesting(false) }
            }
    }
}

/// "?" da barra: atalhos, documentação e contato.
struct HelpMenu: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    static let repo = URL(string: "https://github.com/nerigleston/bando")!

    var body: some View {
        let p = model.palette
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 16)).foregroundStyle(p.secondary)
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .tooltip("Ajuda")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                MenuRow(symbol: "keyboard", title: "Atalhos de teclado", shortcut: "⌘/") { open = false; model.showShortcuts = true }
                MenuRow(symbol: "book", title: "Documentação") { open = false; NSWorkspace.shared.open(Self.repo.appendingPathComponent("blob/main/README.md")) }
                MenuRow(symbol: "exclamationmark.bubble", title: "Reportar problema") { open = false; NSWorkspace.shared.open(Self.repo.appendingPathComponent("issues/new")) }
                MenuRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Código no GitHub") { open = false; NSWorkspace.shared.open(Self.repo) }
            }
            .padding(4)
            .frame(width: 230)
            .environment(\.palette, p)
        }
    }
}

/// Lista de atalhos (⌘/).
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    static let groups: [(String, [(String, String)])] = [
        ("Sessões", [("⌘N", "Nova sessão"), ("⌘K", "Buscar sessão"), ("⌘J", "Próxima esperando você"),
                     ("⌘1 … ⌘9", "Ir para a sessão"), ("⌘.", "Parar sessão"), ("⇧⌘R", "Retomar sessão"),
                     ("⇧⌘E", "Mostrar no Finder"), ("clique duplo", "Abrir só a sessão (na grade)")]),
        ("Grade", [("⌥⌘G", "Alternar grade"), ("⌥⌘1 … ⌥⌘7", "Grade 1×1 até 4×4"),
                   ("arrastar divisória", "Ajustar tamanho"), ("clique duplo na divisória", "Igualar tamanhos")]),
        ("Janelas", [("⇧⌘U", "Uso e custo"), ("⌥⌘R", "Relatórios")]),
        ("Janela", [("⌃⌘S", "Mostrar ou esconder a lateral"), ("⌥⌘I", "Detalhes da sessão"),
                    ("⌘+ / ⌘−", "Fonte do terminal"), ("⌘,", "Ajustes"), ("⌘/", "Esta lista")]),
        ("Terminal (tmux)", [("Ctrl-b d", "Sair do terminal sem parar (no bando attach)"), ("rolar o mouse", "Histórico da sessão")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                DialogHeader(title: "Atalhos de teclado", symbol: "keyboard")
                Button("Fechar") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            }
            ForEach(Self.groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.0).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(p.secondary)
                    ForEach(group.1, id: \.0) { item in
                        HStack {
                            Text(item.1).font(.system(size: 13))
                            Spacer()
                            Text(item.0).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.secondary)
                                .padding(.horizontal, 6).frame(height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.border.opacity(2)))
                        }
                    }
                }
            }
        }
        .dialog(width: 460, palette: p)
    }
}

// MARK: - Painel de conteúdo

struct ContentPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        @Bindable var model = model
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .inspector(isPresented: $model.showInspector) {
                SessionInspector().inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(toast).font(.system(size: 12))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(p.card))
                    .overlay(Capsule().strokeBorder(p.border))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
    }

    @ViewBuilder var content: some View {
        if let error = model.loadError {
            ContentUnavailableView("Erro na configuração", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if case .composer(let pid) = model.route {
            ComposerScreen(projectId: pid)
        } else if case .project(let pid) = model.route {
            ProjectPage(projectId: pid)
        } else if model.gridMode {
            SessionGrid()
        } else if let s = model.selectedSession {
            SessionPane(session: s, focused: true).id(s.id)
        } else {
            EmptyState()
        }
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 14) {
            BandoMark(size: 44).foregroundStyle(p.text.opacity(0.9))
            Text("Nenhuma sessão ainda").font(.system(size: 14, weight: .bold))
            Text("Cada sessão roda um agente de código no seu próprio worktree.\nVocê acompanha todas por aqui.")
                .font(.system(size: 12)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Nova sessão") { model.openComposer() }.buttonStyle(AccentButtonStyle())
                SettingsLink { Text("Importar do Xirp").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(p.secondary)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Uma sessão: cabeçalho + terminal anexado ao tmux. Na grade (`cellIndex`),
/// o cabeçalho é compacto e as ações aparecem só com o mouse em cima.
struct SessionPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let session: Session
    var focused: Bool
    var cellIndex: Int? = nil
    @State private var hovering = false
    @State private var menuOpen = false

    var inGrid: Bool { cellIndex != nil }

    var body: some View {
        VStack(spacing: 0) {
            if inGrid { gridHeader } else { header }
            Rectangle().fill(p.border).frame(height: 1)
            terminal
        }
        .background(model.theme?.background.color ?? p.card)
        .onHover { hovering = $0 }
    }

    @ViewBuilder var terminal: some View {
        if model.canAttach(session), let tmux = try? Tmux(server: session.tmuxServer) {
            TerminalPane(argv: tmux.attachCommand(session.tmuxName), cwd: session.worktreePath,
                         theme: model.theme, fontSize: model.fontSize, focused: focused,
                         onFocus: inGrid ? { focusCell() } : nil)
                .padding(.leading, inGrid ? 14 : 12).padding(.trailing, inGrid ? 6 : 4)
                .padding(.top, inGrid ? 10 : 6).padding(.bottom, inGrid ? 6 : 2)
        } else {
            stopped
        }
    }

    var projectName: String { model.project(session.projectId)?.name ?? "" }

    /// Clique no terminal ou no cabeçalho de um painel da grade: ele vira o foco.
    func focusCell() {
        guard let cell = cellIndex, model.focusedCell != cell || model.selection != session.id else { return }
        model.focusedCell = cell
        model.select(session.id)
    }

    /// Cabeçalho da sessão aberta sozinha (48 pt): projeto / nome, branch, contexto, agente, ações.
    var header: some View {
        HStack(spacing: 6) {
            Text(projectName).font(.system(size: 14)).foregroundStyle(p.secondary).lineLimit(1)
            Text("/").font(.system(size: 14)).foregroundStyle(p.tertiary)
            Text(session.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.secondary).lineLimit(1)
                    .padding(.leading, 6)
                    .tooltip(session.worktreePath)
            }
            ContextRing(session: session)
            if session.status == .waiting, let d = session.statusDetail {
                Text(d).font(.system(size: 12)).foregroundStyle(StateColor.waiting).lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentSwitcher(session: session)
            if session.status.isLive {
                IconButton(symbol: "stop.circle", help: "Parar sessão (⌘.)", size: 15) { model.requestStop([session.id]) }
            } else {
                IconButton(symbol: "play.circle", help: "Retomar (⇧⌘R)", size: 15) { model.resumeSession(session.id) }
            }
            IconButton(symbol: "folder", help: "Mostrar no Finder (⇧⌘E)", size: 15) { model.reveal(session) }
            SessionActionsButton(session: session)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 48)
    }

    /// Cabeçalho do painel na grade (34 pt): estado, projeto / nome e branch à
    /// esquerda; contexto e estado à direita. As ações entram no lugar do
    /// estado quando o mouse passa por cima.
    var gridHeader: some View {
        let tint = StateColor.dot(session.status)
        return HStack(spacing: 8) {
            StatusIcon(status: session.status, size: 11)
            (Text(projectName).foregroundStyle(p.secondary)
             + Text("  /  ").foregroundStyle(p.tertiary)
             + Text(session.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text))
                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            if let branch = session.branch {
                // Só aparece se couber inteira (até 150 pt); senão some.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                        Text(branch.replacingOccurrences(of: "bando/", with: "")).font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
                    }
                    .fixedSize()
                    .foregroundStyle(StateColor.cyan)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(StateColor.cyan.opacity(0.10)))
                    Color.clear.frame(width: 0, height: 0)
                }
                .tooltip(session.worktreePath)
            }
            Spacer(minLength: 6)
            if hovering || menuOpen {
                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Abrir só esta sessão", size: 12) { model.openAlone(session.id) }
                    if session.status.isLive {
                        IconButton(symbol: "stop.circle", help: "Parar sessão", size: 12) { model.requestStop([session.id]) }
                    }
                    IconButton(symbol: "rectangle.badge.minus", help: "Tirar da grade", size: 12) { model.removeFromGrid(session.id) }
                    SessionActionsButton(session: session, size: 12, openBinding: $menuOpen)
                }
                .transition(.opacity)
            } else {
                ContextRing(session: session).scaleEffect(0.8).fixedSize()
                Text(StateColor.label(session.status)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint ?? p.tertiary).lineLimit(1).fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 34)
        .background(p.card)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openAlone(session.id) }
        .onTapGesture { focusCell() }
        .contextMenu { SessionContextMenu(session: session) }
    }

    var stoppedTitle: String {
        switch session.status {
        case .stopped: "Sessão parada"
        case .exited: "Sessão encerrada"
        case .error: "Sessão com erro"
        case .queued: "Sessão na fila"
        default: "Sessão sem terminal"
        }
    }

    var stopped: some View {
        VStack(spacing: 10) {
            Text(stoppedTitle).font(.system(size: 14, weight: .bold))
            if let d = session.statusDetail {
                Text(d).font(.system(size: 12)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
            }
            Button("Retomar sessão") { model.resumeSession(session.id) }.buttonStyle(AccentButtonStyle())
            Text("Continua a conversa do agente no mesmo worktree.").font(.system(size: 11)).foregroundStyle(p.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Grade: só as sessões escolhidas, arranjadas pelo número delas (até o limite
/// de colunas × linhas). Divisórias arrastáveis; clique duplo iguala.
struct SessionGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    static let gap: CGFloat = 10
    static let pad: CGFloat = 10
    @State private var dropTargeted = false
    /// Arraste em andamento: posição onde vai entrar (ou célula a substituir).
    @State private var dragSlot: Int?
    @State private var dragReplace = false
    @State private var dragWatch = DragEndWatch()

    /// Uma posição da grade: sessão ou a prévia de onde o arraste vai cair.
    enum Slot: Identifiable {
        case session(Session), ghost
        var id: String { if case .session(let s) = self { s.id } else { "_ghost" } }
    }

    struct Layout {
        let cols: Int, rows: Int
        let widths: [CGFloat], heights: [CGFloat]
        let usableW: CGFloat, usableH: CGFloat

        func origin(_ i: Int) -> CGPoint {
            let r = i / cols, c = i % cols
            return CGPoint(x: SessionGrid.pad + Self.offset(widths, c), y: SessionGrid.pad + Self.offset(heights, r))
        }
        func frame(_ i: Int) -> CGRect {
            CGRect(origin: origin(i), size: CGSize(width: widths[i % cols], height: heights[min(i / cols, rows - 1)]))
        }
        /// Índice da célula sob o ponto (a mais próxima, se cair num vão).
        func index(at pt: CGPoint, count: Int) -> Int {
            var best = 0, bestDist = CGFloat.infinity
            for i in 0..<max(count, 1) {
                let f = frame(i)
                if f.contains(pt) { return i }
                let d = hypot(pt.x - f.midX, pt.y - f.midY)
                if d < bestDist { best = i; bestDist = d }
            }
            return best
        }
        static func offset(_ sizes: [CGFloat], _ index: Int) -> CGFloat {
            sizes.prefix(index).reduce(0, +) + SessionGrid.gap * CGFloat(index)
        }
    }

    /// Formato para `n` painéis: o escolhido quando a conta fecha com ele,
    /// senão o recomendado (1 cheio, 2 lado a lado, 3 em 3×1, 4 em 2×2...).
    static func shape(_ n: Int, chosen: (Int, Int), fit: Int) -> (Int, Int) {
        var cols: Int
        if n == chosen.0 * chosen.1 {
            cols = chosen.0
        } else {
            switch n {
            case ...3: cols = max(n, 1)
            case 4: cols = 2
            case 5, 6, 9: cols = 3
            default: cols = 4
            }
        }
        cols = max(min(cols, fit, n), 1)
        return (cols, Int(ceil(Double(n) / Double(cols))))
    }

    func layout(_ n: Int, in size: CGSize) -> Layout {
        let fit = max(Int((size.width - 2 * Self.pad + Self.gap) / 332), 1)
        let (cols, rows) = Self.shape(n, chosen: (model.gridCols, model.gridRows), fit: fit)
        let usableW = size.width - 2 * Self.pad - Self.gap * CGFloat(cols - 1)
        let usableH = size.height - 2 * Self.pad - Self.gap * CGFloat(rows - 1)
        return Layout(cols: cols, rows: rows,
                      widths: model.fractions(columns: true, count: cols).map { CGFloat($0) * usableW },
                      heights: model.fractions(columns: false, count: rows).map { CGFloat($0) * usableH },
                      usableW: usableW, usableH: usableH)
    }

    var body: some View {
        let items = model.gridSessions
        if items.isEmpty && dragSlot == nil {
            empty
        } else {
            GeometryReader { geo in
                let inserting = dragSlot != nil && !dragReplace
                let slots: [Slot] = items.map { .session($0) }
                let l = layout(slots.count, in: geo.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { i, slot in
                        let f = l.frame(i)
                        Group {
                            switch slot {
                            case .session(let s): cell(s, index: items.firstIndex { $0.id == s.id } ?? i, replacing: dragReplace && dragSlot == i)
                            case .ghost: ghost
                            }
                        }
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                    }
                    if !inserting {
                        ForEach(0..<max(l.cols - 1, 0), id: \.self) { c in
                            Handle(vertical: true, total: l.usableW) { d, done in
                                model.resize(columns: true, at: c, count: l.cols, by: d, persist: done)
                            } reset: { model.equalize(columns: true) }
                            .frame(width: Self.gap, height: geo.size.height - 2 * Self.pad)
                            .offset(x: Self.pad + Layout.offset(l.widths, c + 1) - Self.gap, y: Self.pad)
                        }
                        ForEach(0..<max(l.rows - 1, 0), id: \.self) { r in
                            Handle(vertical: false, total: l.usableH) { d, done in
                                model.resize(columns: false, at: r, count: l.rows, by: d, persist: done)
                            } reset: { model.equalize(columns: false) }
                            .frame(width: geo.size.width - 2 * Self.pad, height: Self.gap)
                            .offset(x: Self.pad, y: Self.pad + Layout.offset(l.heights, r + 1) - Self.gap)
                        }
                    }
                }
                .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2), value: slots.map(\.id))
                // Prévia leve por cima: os terminais não mudam de tamanho no arraste.
                .overlay(alignment: .topLeading) {
                    if inserting, let at = dragSlot { preview(items: items, ghostAt: at, size: geo.size) }
                }
                .onChange(of: dragSlot != nil) { _, on in
                    if on { dragWatch.start { dragSlot = nil; dragReplace = false } } else { dragWatch.stop() }
                }
                .onDisappear { dragWatch.stop() }
                .onDrop(of: [.text], delegate: GridDrop(
                    count: items.count, capacity: AppModel.maxGrid * AppModel.maxGrid,
                    slotAt: { pt, inserting in
                        let n = items.count
                        return inserting ? layout(n + 1, in: geo.size).index(at: pt, count: n + 1)
                                         : layout(n, in: geo.size).index(at: pt, count: n)
                    },
                    update: { slot, replace in dragSlot = slot; dragReplace = replace },
                    perform: { payloads, slot, replace in model.dropIntoGrid(payloads, at: slot, replace: replace) }))
            }
        }
    }

    /// Mapa de como a grade vai ficar: um retângulo por painel, com o nome, e
    /// a posição nova destacada.
    func preview(items: [Session], ghostAt at: Int, size: CGSize) -> some View {
        var names: [String?] = items.map { $0.name }
        names.insert(nil, at: min(at, names.count))
        let l = layout(names.count, in: size)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(p.chrome.opacity(0.82))
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                let f = l.frame(i)
                Group {
                    if let name {
                        RoundedRectangle(cornerRadius: 10).fill(p.card)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border.opacity(2)))
                            .overlay(Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondary)
                                .lineLimit(1).padding(.horizontal, 12))
                    } else {
                        ghost
                    }
                }
                .frame(width: f.width, height: f.height)
                .offset(x: f.minX, y: f.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: at)
    }

    /// Célula tracejada no lugar onde o arraste vai cair.
    var ghost: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(p.accent.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .overlay {
                Label("Soltar aqui", systemImage: "plus.square.dashed").font(.system(size: 12, weight: .medium)).foregroundStyle(p.accent)
            }
    }

    func offset(_ sizes: [CGFloat], _ index: Int) -> CGFloat {
        sizes.prefix(index).reduce(0, +) + Self.gap * CGFloat(index)
    }

    func border(_ s: Session, focused: Bool) -> (Color, CGFloat) {
        // Só o foco e o que pede você ganham cor; o resto fica discreto.
        if focused { return (p.accent.opacity(0.55), 1.5) }
        switch s.status {
        case .waiting: return (StateColor.waiting.opacity(0.55), 1.5)
        case .error: return (StateColor.failed.opacity(0.5), 1)
        default: return (p.border, 1)
        }
    }

    func cell(_ s: Session, index: Int, replacing: Bool = false) -> some View {
        let focused = model.focusedCell == index
        let b = replacing ? (p.accent, CGFloat(2)) : border(s, focused: focused)
        return SessionPane(session: s, focused: focused, cellIndex: index)
            .id(s.id)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(b.0, lineWidth: b.1))
            .shadow(color: .black.opacity(focused ? 0.25 : 0), radius: 10, y: 3)
            .opacity(model.dimUnfocused && !focused ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            .overlay {
                if replacing {
                    RoundedRectangle(cornerRadius: 10).fill(p.accent.opacity(0.10))
                        .overlay(Label("Substituir", systemImage: "arrow.left.arrow.right").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.accent).padding(.horizontal, 10).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(p.card)))
                        .allowsHitTesting(false)
                }
            }
    }

    var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.system(size: 40, weight: .light)).foregroundStyle(p.tertiary)
            Text("Nenhuma sessão na grade").font(.system(size: 14, weight: .bold))
            Text("Arraste sessões ou projetos da lateral para cá, ou use \"Adicionar à grade\" no menu da sessão.")
                .font(.system(size: 12)).foregroundStyle(p.secondary).multilineTextAlignment(.center)
            let live = model.sessions.filter(\.status.isLive).count
            if live > 0 {
                Button("Adicionar as \(min(live, model.cellCount)) ativas") { model.autoFillGrid() }
                    .buttonStyle(AccentButtonStyle()).padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8).strokeBorder(p.border, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .padding(Self.pad))
        .background(dropTargeted ? StateColor.cyan.opacity(0.05) : .clear)
        .dropDestination(for: String.self) { ids, _ in
            model.dropIntoGrid(ids, at: 0, replace: false)
        } isTargeted: { dropTargeted = $0 }
    }

    /// Alça entre painéis: barra ciano no hover; arrasta para redimensionar.
    struct Handle: View {
        let vertical: Bool
        let total: CGFloat
        let onDrag: (Double, Bool) -> Void
        let reset: () -> Void
        @State private var last: CGFloat = 0
        @State private var hovering = false

        var body: some View {
            ZStack {
                Color.clear.contentShape(Rectangle())
                if hovering {
                    RoundedRectangle(cornerRadius: 2).fill(StateColor.cyan.opacity(0.6))
                        .frame(width: vertical ? 4 : 44, height: vertical ? 44 : 4)
                }
            }
            .onHover { inside in
                hovering = inside
                if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let move = vertical ? g.translation.width : g.translation.height
                    onDrag(Double((move - last) / max(total, 1)), false)
                    last = move
                }
                .onEnded { _ in last = 0; onDrag(0, true) })
            .onTapGesture(count: 2, perform: reset)
        }
    }
}

/// Atalhos para as janelas de uso e relatórios.
struct ReportsButtons: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        IconButton(symbol: "dollarsign.circle", help: "Uso e custo (⇧⌘U)", size: 16) { openWindow(id: "usage") }
        IconButton(symbol: "chart.bar.xaxis", help: "Relatórios (⌥⌘R)", size: 16) { openWindow(id: "reports") }
    }
}

/// Arraste sobre a grade: calcula a posição sob o mouse a cada movimento e
/// avisa a grade para mostrar a prévia. Com a grade cheia, substitui.
struct GridDrop: DropDelegate {
    let count: Int
    let capacity: Int
    let slotAt: (CGPoint, Bool) -> Int
    let update: (Int?, Bool) -> Void
    let perform: ([String], Int, Bool) -> Void

    var inserting: Bool { count < capacity }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { update(slotAt(info.location, inserting), !inserting) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(slotAt(info.location, inserting), !inserting)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { update(nil, false) }

    func performDrop(info: DropInfo) -> Bool {
        let slot = slotAt(info.location, inserting), replace = !inserting
        update(nil, false)
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadTransferable(type: String.self) { result in
                guard case .success(let text) = result else { return }
                Task { @MainActor in perform([text], slot, replace) }
            }
        }
        return true
    }
}

/// O SwiftUI às vezes não avisa que o arraste saiu (a grade muda embaixo do
/// mouse). Enquanto a prévia está na tela, o primeiro evento comum de mouse ou
/// teclado (que não chega durante o arraste) encerra a prévia.
@MainActor
final class DragEndWatch {
    private var monitor: Any?

    func start(_ end: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            end()
            self?.stop()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
