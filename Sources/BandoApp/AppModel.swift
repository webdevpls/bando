import AppKit
import BandoCore
import Foundation
import Observation
import UserNotifications

/// Estado do app. Relê o banco quando outro processo avisa (Darwin
/// notification), sem polling.
@MainActor
@Observable
final class AppModel {
    // Dados
    var config: BandoConfig?
    var projects: [Project] = []
    var sessions: [Session] = []
    var availability: [String: AgentAvailability] = [:]
    /// Contexto e custo por sessão (só agentes que gravam uso, como o Claude Code).
    var contexts: [String: ContextSummary] = [:]
    var prices = PriceTable(models: [:])
    var loadError: String?

    // Seleção e layout
    var selection: String?
    var sidebarMode: SidebarMode = .byProject
    var sidebarWidth: CGFloat = 250
    /// Esmaecer os painéis sem foco na grade. Guardado entre aberturas do app.
    var dimUnfocused = UserDefaults.standard.object(forKey: "dimUnfocused") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dimUnfocused, forKey: "dimUnfocused") }
    }
    /// Grade ligada (senão mostra só a sessão selecionada).
    var gridMode = false
    var gridCols = 2
    var gridRows = 2
    /// Proporções das colunas e linhas (somam 1). Ajustadas arrastando as divisórias.
    var colFractions: [Double] = [0.5, 0.5]
    var rowFractions: [Double] = [0.5, 0.5]
    static let maxGrid = 4
    var gridCells: [String?] = []
    var focusedCell = 0
    var showInspector = false
    var showSidebar = true
    var showNewSession = false
    var showPalette = false
    var showShortcuts = false
    /// Sessões a confirmar no modal de parar.
    var stopRequest: StopRequest?
    /// Sessões marcadas para ação em lote (Cmd+clique na lateral).
    var multiSelection: Set<String> = []
    /// Projetos marcados para tirar da lateral (Cmd+clique no cabeçalho).
    var projectSelection: Set<String> = []
    /// Modo de seleção ligado pelo botão "Selecionar" do rodapé.
    var selectMode = false
    var isSelecting: Bool { selectMode || !multiSelection.isEmpty || !projectSelection.isEmpty }
    func endSelection() { selectMode = false; multiSelection = []; projectSelection = [] }
    func toggleProjectMark(_ id: String) {
        if projectSelection.contains(id) { projectSelection.remove(id) } else { projectSelection.insert(id) }
    }
    /// Sessões a confirmar no modal de apagar (uma, pelo hover, ou o lote).
    var deleteRequest: DeleteRequest?
    var renaming: Session?
    /// Aviso curto no rodapé do painel (andamento de uma troca de agente etc.).
    var toast: String?
    var handoffDefault: HandoffMode {
        get { HandoffMode(rawValue: UserDefaults.standard.string(forKey: "handoffDefault") ?? "") ?? .summary }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "handoffDefault") }
    }
    var newSessionProject: String?

    // Aparência (guardada em UserDefaults pelo próprio app)
    var themePreference: String { didSet { save() } }
    var lightTheme: String { didSet { save() } }
    var darkTheme: String { didSet { save() } }
    var fontSize: Double { didSet { save() } }
    var systemIsDark = false

    @ObservationIgnored private(set) var service: SessionService?
    @ObservationIgnored private var observer: AnyObject?
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?
    @ObservationIgnored private var lastStatus: [String: SessionStatus] = [:]

    enum SidebarMode: String, CaseIterable { case byStatus, byProject, projects }

    /// O que o painel central mostra.
    enum Route: Equatable {
        /// Sessão selecionada (ou a grade).
        case sessions
        /// Página de um projeto.
        case project(String)
        /// Caixa de nova sessão (opcionalmente já num projeto).
        case composer(String?)
    }
    var route: Route = .sessions
    var showAddProject = false
    var showImportWorkspace = false
    /// Agente usado por último na caixa de nova sessão.
    var lastAgent: String {
        get { UserDefaults.standard.string(forKey: "lastAgent") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "lastAgent") }
    }

    func openComposer(project: String? = nil) {
        route = .composer(project ?? (route.projectId) ?? selectedSession?.projectId)
    }

    func openProject(_ id: String) { route = .project(id); sidebarMode = .projects }

    init() {
        let d = UserDefaults.standard
        themePreference = d.string(forKey: "themePreference") ?? "system"
        lightTheme = d.string(forKey: "lightTheme") ?? BandoConfig.defaultLightTheme
        darkTheme = d.string(forKey: "darkTheme") ?? BandoConfig.defaultDarkTheme
        fontSize = d.object(forKey: "fontSize") as? Double ?? 13
        gridMode = d.bool(forKey: "gridMode")
        gridCols = min(max(d.integer(forKey: "gridCols").nonZero(or: 2), 1), Self.maxGrid)
        gridRows = min(max(d.integer(forKey: "gridRows").nonZero(or: 2), 1), Self.maxGrid)
        colFractions = Self.validFractions(d.array(forKey: "colFractions") as? [Double], count: gridCols)
        rowFractions = Self.validFractions(d.array(forKey: "rowFractions") as? [Double], count: gridRows)
        gridCells = (d.array(forKey: "gridCells") as? [String] ?? []).map { $0.isEmpty ? nil : $0 }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(themePreference, forKey: "themePreference")
        d.set(lightTheme, forKey: "lightTheme")
        d.set(darkTheme, forKey: "darkTheme")
        d.set(fontSize, forKey: "fontSize")
        d.set(gridMode, forKey: "gridMode")
        d.set(gridCols, forKey: "gridCols")
        d.set(gridRows, forKey: "gridRows")
        d.set(colFractions, forKey: "colFractions")
        d.set(rowFractions, forKey: "rowFractions")
        d.set(gridCells.map { $0 ?? "" }, forKey: "gridCells")
    }

    var palette: UIPalette { UIPalette(theme: theme) }

    var theme: ThemeDefinition? {
        config?.theme(preference: themePreference, systemIsDark: systemIsDark, light: lightTheme, dark: darkTheme)
    }

    // MARK: - Ciclo de vida

    func start() async {
        writePidFile()
        observer = ChangeNotifier.observe { [weak self] in
            Task { @MainActor in self?.refreshSessions() }
        }
        systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Task { @MainActor in self?.systemIsDark = dark }
        }
        await reload()
        // Só para testes e capturas: BANDO_OPEN=composer | projects | project:<nome>
        if let open = ProcessInfo.processInfo.environment["BANDO_OPEN"] {
            if open == "composer" { openComposer() }
            else if open == "projects" { sidebarMode = .projects }
            else if open.hasPrefix("session:") { gridMode = false; select(String(open.dropFirst(8))) }
            else if open.hasPrefix("project:"), let p = projects.first(where: { $0.name == String(open.dropFirst(8)) }) { openProject(p.id) }
        }
        // Pedido de permissão não pode travar o carregamento: a resposta só
        // chega quando o usuário clica no aviso do sistema.
        if Bundle.main.bundleIdentifier != nil {
            Task.detached {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    func stop() {
        try? FileManager.default.removeItem(at: BandoPaths.standard().stateDir.appendingPathComponent("app.pid"))
    }

    private func writePidFile() {
        let paths = BandoPaths.standard()
        try? FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(
            to: paths.stateDir.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
    }

    /// Recarrega config e banco (config pode ter mudado no disco).
    func reload() async {
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> (SessionService, [String: AgentAvailability]) in
                let service = try SessionService()
                try? service.reconcile()
                var avail: [String: AgentAvailability] = [:]
                for a in service.config.sortedAgents { avail[a.id] = a.availability(probeVersion: false) }
                return (service, avail)
            }.value
            service = result.0
            config = result.0.config
            availability = result.1
            loadError = nil
            refreshSessions()
            // Preços: catálogo + fonte remota (baixada no máximo 1× por dia).
            Task.detached(priority: .utility) {
                await PriceTable.refreshRemote()
                let table = PriceTable.load()
                await MainActor.run { self.prices = table; self.refreshContexts() }
            }
            // Versões de cada CLI em segundo plano (cada uma leva até ~1 s).
            let agents = result.0.config.sortedAgents
            Task.detached(priority: .utility) {
                let probed = LockedBox([String: AgentAvailability]())
                DispatchQueue.concurrentPerform(iterations: agents.count) { i in
                    let a = agents[i].availability(probeVersion: true)
                    probed.mutate { $0[a.agent.id] = a }
                }
                let value = probed.value
                await MainActor.run { self.availability = value }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Releitura rápida das sessões e projetos (chamada a cada aviso).
    func refreshSessions() {
        guard let store = service?.store else { return }
        projects = (try? store.projects()) ?? []
        let fresh = (try? store.sessions()) ?? []
        notifyTransitions(fresh)
        sessions = fresh
        multiSelection.formIntersection(fresh.map(\.id))
        if let sel = selection, !sessions.contains(where: { $0.id == sel }) { selection = nil }
        refreshContexts()
        refreshTmux()
        // Grade ligada mas vazia (ex.: ao abrir o app): preenche com as ativas.
        if gridMode && gridSessions.isEmpty && sessions.contains(where: \.status.isLive) { autoFillGrid() }
        // Nunca deixa o centro vazio: abre a sessão mais urgente.
        if selection == nil, let first = orderedSessions.first ?? finishedSessions.first { selection = first.id }
        updateDockBadge()
    }

    /// Sessões que existem no tmux, por servidor. Lidas fora da main thread: a
    /// tela nunca roda o tmux enquanto desenha (rodar um processo e esperar
    /// dentro do desenho reentra no ciclo de atualização e derruba o app).
    var liveTmux: [String: Set<String>] = [:]
    @ObservationIgnored private var tmuxRefreshing = false

    func refreshTmux() {
        guard !tmuxRefreshing else { return }
        tmuxRefreshing = true
        let servers = Set(sessions.filter(\.status.isLive).map(\.tmuxServer)).union([Tmux.bandoServer])
        Task.detached(priority: .userInitiated) {
            var found: [String: Set<String>] = [:]
            for server in servers {
                if let tmux = try? Tmux(server: server) { found[server] = Set(tmux.listSessions()) }
            }
            await MainActor.run {
                if found != self.liveTmux { self.liveTmux = found }
                self.tmuxRefreshing = false
            }
        }
    }

    /// O terminal pode anexar? Enquanto a primeira leitura não chega, confia no
    /// estado gravado no banco.
    func canAttach(_ s: Session) -> Bool {
        guard s.status.isLive else { return false }
        guard let names = liveTmux[s.tmuxServer] else { return true }
        return names.contains(s.tmuxName)
    }

    /// Lê o contexto das sessões na tela (fora da main thread). O transcript
    /// só é relido quando a sessão muda, e cada leitura é de um arquivo só.
    @ObservationIgnored private var contextStamp: [String: Date] = [:]
    func refreshContexts() {
        let visible = Set([selection].compactMap { $0 } + (gridMode ? gridCells.prefix(cellCount).compactMap { $0 } : []))
        let targets = sessions.filter { visible.contains($0.id) && $0.nativeId != nil && contextStamp[$0.id] != $0.updatedAt }
        guard !targets.isEmpty else { return }
        for s in targets { contextStamp[s.id] = s.updatedAt }
        let prices = self.prices
        Task.detached(priority: .utility) {
            var found: [String: ContextSummary] = [:]
            for s in targets { if let c = ContextSummary.load(nativeId: s.nativeId, prices: prices) { found[s.id] = c } }
            let result = found
            await MainActor.run { self.contexts.merge(result) { _, n in n } }
        }
    }

    // MARK: - Consultas para a interface

    func session(_ id: String?) -> Session? { id.flatMap { id in sessions.first { $0.id == id } } }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    var selectedSession: Session? { session(selection) }

    /// Sessões agrupadas por urgência, como na lateral.
    var groups: [(title: String, sessions: [Session])] {
        let visible = sessions.filter { !$0.hidden }
        func pick(_ statuses: Set<SessionStatus>) -> [Session] {
            visible.filter { statuses.contains($0.status) && !$0.pinned }.sorted { $0.statusChangedAt > $1.statusChangedAt }
        }
        return [
            ("Fixadas", visible.filter(\.pinned).sorted { $0.status.urgency < $1.status.urgency }),
            ("Esperando você", pick([.waiting])),
            ("Com erro", pick([.error])),
            ("Pronto para revisar", pick([.review])),
            ("Trabalhando", pick([.working, .starting])),
            ("Na fila", pick([.queued])),
            ("Ociosas", pick([.idle])),
        ].filter { !$0.sessions.isEmpty }
    }

    var finishedSessions: [Session] {
        sessions.filter { ($0.status == .stopped || $0.status == .exited) && !$0.hidden && !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var counts: (waiting: Int, working: Int, review: Int) {
        (sessions.filter { $0.status == .waiting }.count,
         sessions.filter { $0.status == .working || $0.status == .starting }.count,
         sessions.filter { $0.status == .review }.count)
    }

    /// Ordem de navegação por teclado (⌘1…⌘9, ⌘J).
    var orderedSessions: [Session] { groups.flatMap(\.sessions) }

    // MARK: - Ações

    func select(_ id: String?) {
        selection = id
        if id != nil { route = .sessions }
        refreshContexts()
        guard let id, let s = session(id) else { return }
        if s.status == .review, let service {
            Task.detached { try? service.markSeen(id) }
        }
        if gridMode, let cell = gridSessions.firstIndex(where: { $0.id == id }) { focusedCell = cell }
    }

    func selectNextWaiting() {
        let waiting = sessions.filter { $0.status == .waiting || $0.status == .review }
            .sorted { $0.status.urgency < $1.status.urgency }
        guard !waiting.isEmpty else { return }
        let idx = waiting.firstIndex { $0.id == selection }.map { ($0 + 1) % waiting.count } ?? 0
        select(waiting[idx].id)
    }

    func selectIndex(_ i: Int) {
        let list = orderedSessions
        if i < list.count { select(list[i].id) }
    }

    func run(_ title: String, _ action: @escaping @Sendable (SessionService) throws -> Void) {
        guard let service else { return }
        Task.detached {
            do { try action(service) } catch {
                await MainActor.run { self.showError(title, error) }
            }
        }
    }

    /// Roda uma ação que cria sessão e já abre a nova.
    func runReturning(_ title: String, _ action: @escaping @Sendable (SessionService) throws -> Session) {
        guard let service else { return }
        Task.detached {
            do {
                let s = try action(service)
                await MainActor.run {
                    self.refreshSessions()
                    if self.gridMode { self.showInGrid(s.id) }
                    self.select(s.id)
                }
            } catch {
                await MainActor.run { self.showError(title, error) }
            }
        }
    }

    /// Troca de agente em segundo plano, mostrando o andamento no rodapé.
    func swapAgent(_ id: String, agent: String, provider: String?, model modelName: String?, handoff: HandoffMode) {
        guard let service else { return }
        toast = "Trocando de agente…"
        Task.detached {
            do {
                try service.swapAgent(id, agent: agent, provider: provider, model: modelName, handoff: handoff) { msg in
                    Task { @MainActor in self.toast = msg }
                }
                await MainActor.run {
                    self.toast = nil
                    self.refreshSessions()
                }
            } catch {
                await MainActor.run { self.toast = nil; self.showError("Trocar agente", error) }
            }
        }
    }

    func stopSession(_ id: String) { run("Parar") { _ = try $0.stop(id) } }

    /// Toda parada e todo apagar passam por um modal de confirmação.
    func requestStop(_ ids: [String]) { if !ids.isEmpty { stopRequest = StopRequest(sessionIds: ids) } }
    func requestDelete(_ ids: [String]) { if !ids.isEmpty { deleteRequest = DeleteRequest(sessionIds: ids) } }

    /// Para várias sessões de uma vez. Worktrees e branches ficam; cada uma pode ser retomada.
    func stopSessions(_ ids: [String]) {
        guard let service else { return }
        Task.detached {
            var failures: [Error] = []
            for id in ids {
                do { _ = try service.stop(id) } catch { failures.append(error) }
            }
            await MainActor.run {
                self.refreshSessions()
                if let first = failures.first { self.showError("Parar sessões", first) }
            }
        }
    }
    func resumeSession(_ id: String) { run("Retomar") { _ = try $0.resume(id) } }

    /// Tira projetos da lateral escondendo as sessões paradas deles. Nada é
    /// apagado; as sessões vão para "ocultas" e o projeto volta com sessão nova.
    func hideProjects(_ ids: Set<String>) {
        projectSelection.subtract(ids)
        let targets = sessions.filter { ids.contains($0.projectId) && !$0.hidden && !$0.status.isLive && $0.status != .queued }.map(\.id)
        guard let service, !targets.isEmpty else { return }
        Task.detached {
            for id in targets { try? service.setHidden(id, true) }
            await MainActor.run { self.refreshSessions() }
        }
    }

    func toggleMulti(_ id: String) {
        if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
    }

    /// Apaga várias sessões e seus worktrees. Sem `force`, as que têm trabalho
    /// não salvo ficam (a trava continua valendo); devolve quantas ficaram.
    func deleteSessions(_ ids: [String], force: Set<String>) {
        guard let service else { return }
        multiSelection.subtract(ids)
        Task.detached {
            var failures: [Error] = []
            for id in ids {
                do {
                    try service.delete(id, options: .init(removeWorktree: true, deleteBranch: false, force: force.contains(id)))
                } catch BandoError.unsafeDelete {
                    continue
                } catch { failures.append(error) }
            }
            await MainActor.run {
                self.refreshSessions()
                if let first = failures.first { self.showError("Apagar sessões", first) }
            }
        }
    }

    func deleteSession(_ id: String, force: Bool = false) {
        guard let service else { return }
        Task.detached {
            do {
                try service.delete(id, options: .init(removeWorktree: true, deleteBranch: false, force: force))
            } catch BandoError.unsafeDelete(let why) {
                await MainActor.run { self.confirmForceDelete(id, why: why) }
            } catch {
                await MainActor.run { self.showError("Apagar", error) }
            }
        }
    }

    private func confirmForceDelete(_ id: String, why: String) {
        let alert = NSAlert()
        alert.messageText = "Apagar mesmo assim?"
        alert.informativeText = "\(why.prefix(1).uppercased() + why.dropFirst()). Esse trabalho será perdido."
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Apagar").hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { deleteSession(id, force: true) }
    }

    func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    func reveal(_ s: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.worktreePath)])
    }

    // MARK: - Grade

    /// Limite de sessões na grade (colunas × linhas escolhidas, até 4×4).
    var cellCount: Int { gridCols * gridRows }
    /// Sessões que estão na grade, na ordem (só as que ainda existem).
    var gridSessions: [Session] { gridCells.compactMap { session($0) }.prefix(cellCount).map { $0 } }

    static func validFractions(_ f: [Double]?, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard let f, f.count == count, f.allSatisfy({ $0 > 0.05 }) else { return Array(repeating: 1 / Double(count), count: count) }
        let total = f.reduce(0, +)
        return f.map { $0 / total }
    }

    /// Proporções para o formato exibido agora (zera quando o número muda).
    func fractions(columns: Bool, count: Int) -> [Double] {
        Self.validFractions(columns ? colFractions : rowFractions, count: count)
    }

    /// Define o limite da grade (até 4×4). 1×1 volta para uma sessão.
    func setGrid(cols: Int, rows: Int) {
        let c = min(max(cols, 1), Self.maxGrid), r = min(max(rows, 1), Self.maxGrid)
        if c == 1 && r == 1 { gridMode = false; save(); return }
        gridCols = c; gridRows = r
        gridMode = true
        compactGrid()
        if gridSessions.isEmpty { autoFillGrid() }
        focusedCell = min(focusedCell, max(gridSessions.count - 1, 0))
        save()
    }

    func setSingle() { gridMode = false; save() }

    /// Abre só uma sessão no painel. A grade fica guardada para voltar com ⌥⌘G.
    func openAlone(_ id: String) {
        setSingle()
        select(id)
    }

    func toggleGrid() {
        if gridMode { setSingle() } else { setGrid(cols: max(gridCols, 2), rows: max(gridRows, 1)) }
    }

    /// Remove da lista sessões que não existem mais e células vazias.
    func compactGrid() {
        gridCells = gridCells.compactMap { $0 }.filter { session($0) != nil }.map { Optional($0) }
    }

    func equalize(columns: Bool) {
        if columns { colFractions = [] } else { rowFractions = [] }
        save()
    }

    /// Move a divisória entre `index` e `index + 1` (fração do total).
    func resize(columns: Bool, at index: Int, count: Int, by delta: Double, persist: Bool) {
        var f = fractions(columns: columns, count: count)
        guard index + 1 < f.count else { return }
        let minimum = 0.12
        let d = max(min(delta, f[index + 1] - minimum), minimum - f[index])
        f[index] += d; f[index + 1] -= d
        if columns { colFractions = f } else { rowFractions = f }
        if persist { save() }
    }

    /// Preenche a grade com as sessões vivas, as que esperam você primeiro.
    func autoFillGrid() {
        let live = sessions.filter { $0.status.isLive && !$0.hidden }.sorted { $0.status.urgency < $1.status.urgency }
        gridCells = live.prefix(cellCount).map { Optional($0.id) }
        save()
    }

    func emptyGrid() {
        gridCells = []
        save()
    }

    var gridIsFull: Bool { gridSessions.count >= cellCount }

    /// Põe a sessão na posição `index`: troca de lugar se já estava na grade,
    /// substitui se a posição existe, senão acrescenta.
    func place(_ id: String, inCell index: Int) {
        compactGrid()
        var ids = gridCells.compactMap { $0 }
        if let from = ids.firstIndex(of: id) {
            if index < ids.count { ids.swapAt(from, index) }
        } else if index < ids.count {
            ids[index] = id
        } else if ids.count < cellCount {
            ids.append(id)
        }
        gridCells = ids.map { Optional($0) }
        focusedCell = ids.firstIndex(of: id) ?? 0
        save()
    }

    /// Soltar na grade: uma sessão, ou "project:<id>" para as sessões ativas
    /// do projeto. Entra na posição `slot` (as outras andam uma casa); com
    /// `replace`, troca a sessão daquela célula.
    @discardableResult
    func dropIntoGrid(_ payloads: [String], at slot: Int, replace: Bool) -> Bool {
        var ids: [String] = []
        for p in payloads {
            if p.hasPrefix("project:") {
                let pid = String(p.dropFirst("project:".count))
                ids += sessions.filter { $0.projectId == pid && $0.status.isLive }
                    .sorted { $0.status.urgency < $1.status.urgency }.map(\.id)
            } else if session(p) != nil {
                ids.append(p)
            }
        }
        guard let first = ids.first else { return false }
        if !gridMode { setGrid(cols: max(gridCols, 2), rows: max(gridRows, 1)) }
        compactGrid()
        if replace {
            place(first, inCell: slot)
            return true
        }
        var cells = gridCells.compactMap { $0 }
        // Grade cheia: cresce para o formato recomendado em vez de substituir.
        let needed = min(cells.count + ids.filter { !cells.contains($0) }.count, Self.maxGrid * Self.maxGrid)
        if needed > cellCount {
            let shape = SessionGrid.shape(needed, chosen: (0, 0), fit: Self.maxGrid)
            gridCols = shape.0; gridRows = shape.1
            colFractions = []; rowFractions = []
        }
        var at = min(slot, cells.count)
        for id in ids {
            if let from = cells.firstIndex(of: id) {
                cells.remove(at: from)
                if from < at { at -= 1 }
            }
            guard cells.count < cellCount else { break }
            cells.insert(id, at: min(at, cells.count))
            at += 1
        }
        gridCells = cells.map { Optional($0) }
        focusedCell = cells.firstIndex(of: first) ?? 0
        save()
        return true
    }

    func showInGrid(_ id: String) {
        if !gridMode { setGrid(cols: max(gridCols, 2), rows: max(gridRows, 1)) }
        compactGrid()
        if gridCells.contains(id) { focusedCell = gridCells.firstIndex(of: id) ?? 0; return }
        if gridIsFull {
            place(id, inCell: focusedCell)
        } else {
            gridCells.append(id)
            focusedCell = gridCells.count - 1
            save()
        }
    }

    func removeFromGrid(_ id: String) {
        gridCells.removeAll { $0 == id }
        focusedCell = min(focusedCell, max(gridCells.count - 1, 0))
        save()
    }

    func clearCell(_ cell: Int) {
        compactGrid()
        guard cell < gridCells.count else { return }
        gridCells.remove(at: cell)
        save()
    }

    // MARK: - Notificações

    /// Notifica só o que mudou e só quando você não está olhando a sessão.
    private func notifyTransitions(_ fresh: [Session]) {
        defer { lastStatus = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0.status) }) }
        guard !lastStatus.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        for s in fresh {
            guard let before = lastStatus[s.id], before != s.status else { continue }
            let looking = NSApp.isActive && (selection == s.id || (gridMode && gridCells.prefix(cellCount).contains(s.id)))
            guard !looking else { continue }
            let title: String
            switch s.status {
            case .waiting: title = "\(s.name) está esperando você"
            case .review: title = "\(s.name) terminou"
            case .error: title = "\(s.name) falhou"
            default: continue
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = s.statusDetail ?? s.agent
            content.sound = s.status == .waiting ? .default : nil
            content.userInfo = ["session": s.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(s.id)-\(s.status.rawValue)", content: content, trigger: nil))
        }
    }

    private func updateDockBadge() {
        let n = counts.waiting
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}

/// Atalhos de grade (o usuário também escolhe qualquer combinação até 4×4).
struct GridPreset: Identifiable, Hashable {
    let cols: Int, rows: Int
    var id: String { "\(cols)x\(rows)" }
    var label: String { cols == 1 && rows == 1 ? "Uma sessão" : "\(cols) × \(rows)" }
    static let all: [GridPreset] = [
        .init(cols: 1, rows: 1), .init(cols: 2, rows: 1), .init(cols: 1, rows: 2), .init(cols: 2, rows: 2),
        .init(cols: 3, rows: 2), .init(cols: 3, rows: 3), .init(cols: 4, rows: 4),
    ]
}

extension Int {
    func nonZero(or fallback: Int) -> Int { self == 0 ? fallback : self }
}

extension AppModel.Route {
    var projectId: String? {
        switch self {
        case .project(let id): id
        case .composer(let id): id
        case .sessions: nil
        }
    }
}

struct StopRequest: Identifiable {
    let id = UUID()
    let sessionIds: [String]
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let sessionIds: [String]
}
