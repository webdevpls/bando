import Foundation
import GRDB

/// Regras de negócio das sessões. Usado pelo CLI e pelo app.
public final class SessionService: @unchecked Sendable {
    public let store: BandoStore
    public let config: BandoConfig
    public var paths: BandoPaths { store.paths }

    public init(store: BandoStore, config: BandoConfig) {
        self.store = store
        self.config = config
    }

    public convenience init() throws {
        try self.init(store: BandoStore(), config: BandoConfig.load())
    }

    // MARK: - Projetos

    /// Projeto do caminho (raiz do repositório git, ou a própria pasta),
    /// registrando se ainda não existir.
    @discardableResult
    public func ensureProject(at path: String) throws -> Project {
        let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let root = (try? Git())?.repositoryRoot(of: standardized) ?? standardized
        if let existing = try store.pool.read({ db in
            try Project.filter(Column("path") == root).fetchOne(db)
        }) {
            return existing
        }
        let name = root == Project.generalPath ? Project.generalName : URL(fileURLWithPath: root).lastPathComponent
        let project = Project(name: name, path: root)
        try store.pool.write { db in try project.insert(db) }
        ChangeNotifier.post()
        return project
    }

    /// Projeto "Geral" (pasta pessoal), criado na primeira vez.
    public func generalProject() throws -> Project {
        try ensureProject(at: Project.generalPath)
    }

    public func findProject(_ ref: String) throws -> Project {
        let all = try store.projects()
        if let p = all.first(where: { $0.id == ref || $0.name == ref || $0.path == ref }) { return p }
        let byPrefix = all.filter { $0.id.hasPrefix(ref) }
        if byPrefix.count == 1 { return byPrefix[0] }
        if FileManager.default.fileExists(atPath: (ref as NSString).expandingTildeInPath) {
            return try ensureProject(at: ref)
        }
        throw BandoError.notFound("projeto \(ref)")
    }

    // MARK: - Criar

    public struct NewSession: Sendable {
        public var project: Project
        public var prompt: String?
        public var name: String?
        public var agent: String
        public var provider: String?
        public var model: String?
        public var branch: String?
        public var baseBranch: String?
        public var useWorktree: Bool
        public var dependsOn: String?
        /// false: só cria (quem chama inicia de outro jeito, ex.: fork).
        public var startNow: Bool

        public init(project: Project, prompt: String?, name: String? = nil, agent: String, provider: String? = nil,
                    model: String? = nil, branch: String? = nil, baseBranch: String? = nil,
                    useWorktree: Bool = true, dependsOn: String? = nil, startNow: Bool = true) {
            self.project = project; self.prompt = prompt; self.name = name; self.agent = agent
            self.provider = provider; self.model = model; self.branch = branch; self.baseBranch = baseBranch
            self.useWorktree = useWorktree; self.dependsOn = dependsOn; self.startNow = startNow
        }
    }

    /// Cria a sessão (worktree + registro) e inicia, ou deixa na fila se
    /// depender de outra que ainda não terminou.
    public func create(_ req: NewSession) throws -> Session {
        let agent = try config.agent(req.agent)
        if let p = req.provider {
            let provider = try config.provider(p)
            guard provider.supports(agent: agent.id) else {
                throw ConfigError.providerNotForAgent(provider: provider.id, agent: agent.id)
            }
        }
        let parent = try req.dependsOn.map { try store.findSession($0) }

        let id = UUID().uuidString.lowercased()
        let baseName = req.name ?? req.prompt.map { String($0.prefix(60)) } ?? "sessão \(String(id.prefix(4)))"
        let slug = Slug.make(req.name ?? req.prompt ?? "sessao") + "-" + String(id.prefix(4))

        var worktree = req.project.path
        var branch: String? = nil
        var base: String? = nil
        // Pasta sem git (como o "Geral"): a sessão roda direto nela, sem worktree.
        let isRepo = (try? Git())?.repositoryRoot(of: req.project.path) != nil
        let useWorktree = req.useWorktree && isRepo
        if useWorktree {
            let git = try Git()
            branch = req.branch ?? "bando/\(slug)"
            base = req.baseBranch ?? req.project.baseBranch ?? git.currentBranch(req.project.path)
            let root = req.project.worktreeRoot.map { URL(fileURLWithPath: $0) }
                ?? BandoPaths.worktreeRoot(forRepository: URL(fileURLWithPath: req.project.path))
            worktree = root.appendingPathComponent(slug).path
            try git.addWorktree(repo: req.project.path, path: worktree, branch: branch!, base: base)
        }

        let waiting = parent.map { !$0.status.releasesDependents && $0.status != .error } ?? false
        let session = Session(
            id: id, projectId: req.project.id, name: baseName, prompt: req.prompt,
            agent: agent.id, provider: req.provider, model: req.model,
            worktreePath: worktree, branch: branch, baseBranch: base, usesWorktree: useWorktree,
            tmuxName: "bando_\(String(id.prefix(8)))",
            status: waiting ? .queued : .starting, dependsOn: parent?.id
        )
        try store.pool.write { db in
            try session.insert(db)
            var e = SessionEvent(sessionId: id, kind: "created", status: session.status)
            try e.insert(db)
            try db.execute(sql: "UPDATE project SET lastUsedAt = ? WHERE id = ?", arguments: [Date(), req.project.id])
        }
        ChangeNotifier.post()
        if !waiting && req.startNow { try start(session, mode: .fresh) }
        return try store.session(id) ?? session
    }

    // MARK: - Iniciar, retomar, parar

    /// Abre a sessão tmux rodando `bando run`, que inicia o agente.
    public func start(_ session: Session, mode: StartMode) throws {
        let tmux = try Tmux(server: session.tmuxServer)
        guard !tmux.hasSession(session.tmuxName) else { return }
        var args = ["run", session.id]
        switch mode {
        case .fresh: break
        case .resume: args.append("--resume")
        case .fork(let native): args += ["--fork", native]
        case .handoff(let prompt): args += ["--prompt", prompt]
        }
        // Marca antes de abrir o tmux: o supervisor pode mudar o estado logo em seguida.
        let kind: String
        switch mode {
        case .fresh: kind = "start"
        case .resume: kind = "resume"
        case .fork: kind = "fork"
        case .handoff: kind = "swap-agent"
        }
        try transition(session.id, to: .starting, kind: kind)
        do {
            try tmux.newSession(
                name: session.tmuxName, cwd: session.worktreePath,
                command: [BandoCLI.path()] + args,
                env: sessionEnvironment(session)
            )
        } catch {
            try? transition(session.id, to: .error, kind: "start-failed", detail: error.localizedDescription)
            throw error
        }
    }

    public enum StartMode: Sendable, Equatable {
        case fresh, resume
        /// Nova conversa a partir de outra (`fork` do agente).
        case fork(String)
        /// Começa do zero com este texto como tarefa (troca de agente).
        case handoff(String)
    }

    /// Variáveis passadas ao tmux. O tmux cria a sessão com o ambiente do
    /// servidor (de quem o iniciou primeiro), então as pastas do Bando precisam
    /// ir explicitamente. Nunca inclui segredos.
    func sessionEnvironment(_ session: Session) -> [String: String] {
        var env = ["BANDO_SESSION_ID": session.id, "BANDO_PROJECT_ID": session.projectId,
                   "BANDO_CONFIG_DIR": paths.configDir.path, "BANDO_STATE_DIR": paths.stateDir.path]
        let current = ProcessInfo.processInfo.environment
        for key in ["BANDO_CLI", "LANG", "LC_ALL"] where current[key] != nil { env[key] = current[key] }
        return env
    }

    public func resume(_ ref: String) throws -> Session {
        let s = try store.findSession(ref)
        try start(s, mode: .resume)
        return try store.session(s.id) ?? s
    }

    public func stop(_ ref: String) throws -> Session {
        let s = try store.findSession(ref)
        // Marca antes de matar: o supervisor recebe SIGHUP e não deve gravar erro.
        try transition(s.id, to: .stopped, kind: "stop")
        if let tmux = try? Tmux(server: s.tmuxServer), tmux.hasSession(s.tmuxName) {
            try tmux.kill(s.tmuxName)
        }
        return try store.session(s.id) ?? s
    }

    public func message(_ ref: String, text: String, enter: Bool = true) throws {
        let s = try store.findSession(ref)
        let tmux = try Tmux(server: s.tmuxServer)
        guard tmux.hasSession(s.tmuxName) else { throw BandoError.invalid("A sessão \(s.name) não está rodando") }
        try tmux.send(s.tmuxName, text: text, enter: enter)
        try record(s.id, kind: "message", detail: String(text.prefix(200)))
    }

    public struct DeleteOptions: Sendable {
        public var removeWorktree = true
        public var deleteBranch = false
        public var force = false
        public init(removeWorktree: Bool = true, deleteBranch: Bool = false, force: Bool = false) {
            self.removeWorktree = removeWorktree; self.deleteBranch = deleteBranch; self.force = force
        }
    }

    /// Apaga a sessão. Recusa se o worktree tiver trabalho não salvo, a menos
    /// que `force` esteja ligado.
    /// Motivo para não apagar o worktree sem confirmação (mudança não commitada
    /// ou commit sem push), ou nil se é seguro.
    public func deleteBlocker(_ ref: String) throws -> String? {
        let s = try store.findSession(ref)
        guard s.usesWorktree, FileManager.default.fileExists(atPath: s.worktreePath) else { return nil }
        let git = try Git()
        if git.hasUncommittedChanges(s.worktreePath) {
            return "\(s.worktreePath) tem mudanças não commitadas"
        }
        let ahead = git.unpushedCommits(s.worktreePath, base: s.baseBranch)
        if ahead > 0 {
            return "o branch \(s.branch ?? "?") tem \(ahead) commit(s) que não estão no remoto nem em \(s.baseBranch ?? "base")"
        }
        return nil
    }

    public func delete(_ ref: String, options: DeleteOptions) throws {
        let s = try store.findSession(ref)
        let project = try store.project(s.projectId)
        if options.removeWorktree && !options.force, let why = try deleteBlocker(s.id) {
            throw BandoError.unsafeDelete(why)
        }
        if let tmux = try? Tmux(server: s.tmuxServer), tmux.hasSession(s.tmuxName) { try tmux.kill(s.tmuxName) }
        if s.usesWorktree, options.removeWorktree, let project, FileManager.default.fileExists(atPath: s.worktreePath) {
            let git = try Git()
            try git.removeWorktree(repo: project.path, path: s.worktreePath, force: options.force)
            if options.deleteBranch, let branch = s.branch {
                try git.deleteBranch(repo: project.path, branch: branch, force: options.force)
            }
        }
        _ = try store.pool.write { db in try Session.deleteOne(db, key: s.id) }
        ChangeNotifier.post()
    }

    // MARK: - Ações do menu da sessão

    public func rename(_ id: String, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw BandoError.invalid("O nome não pode ficar vazio") }
        try update(id) { $0.name = clean }
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws { try update(id) { $0.pinned = pinned } }
    public func setHidden(_ id: String, _ hidden: Bool) throws { try update(id) { $0.hidden = hidden } }

    /// Define (ou remove) a sessão da qual esta depende. Recusa ciclos.
    public func setDependency(_ id: String, parent: String?) throws {
        if let parent {
            var cursor: String? = parent
            var seen = Set<String>()
            while let c = cursor, seen.insert(c).inserted {
                if c == id { throw BandoError.invalid("Isso criaria uma dependência circular") }
                cursor = try store.session(c)?.dependsOn
            }
        }
        try update(id) { $0.dependsOn = parent }
        // Se estava na fila e a nova dependência já terminou (ou foi removida), inicia.
        guard let s = try store.session(id), s.status == .queued else { return }
        let parentDone = try parent.flatMap { try store.session($0) }?.status.releasesDependents ?? true
        if parentDone { try start(s, mode: .fresh) }
    }

    /// Troca agente, provider ou modelo mantendo a sessão (worktree, branch, histórico).
    ///
    /// Mesmo agente: retoma a mesma conversa com o provider/modelo novo.
    /// Outro agente: começa uma conversa nova no mesmo worktree, levando o que
    /// `handoff` pedir (resumo escrito pelo agente atual, conversa exportada ou
    /// só a tarefa). `progress` recebe mensagens para mostrar ao usuário.
    public func swapAgent(_ id: String, agent: String, provider: String?, model: String?,
                          handoff: HandoffMode = .summary, progress: (String) -> Void = { _ in }) throws {
        let s = try store.findSession(id)
        let newAgent = try config.agent(agent)
        if let provider {
            guard try config.provider(provider).supports(agent: newAgent.id) else {
                throw ConfigError.providerNotForAgent(provider: provider, agent: newAgent.id)
            }
        }
        let sameAgent = newAgent.id == s.agent
        let tmux = try Tmux(server: s.tmuxServer)
        let live = tmux.hasSession(s.tmuxName)

        var carried: HandoffMode = .none
        if !sameAgent {
            carried = try prepareHandoff(s, mode: handoff, live: live, tmux: tmux, progress: progress)
        }

        if tmux.hasSession(s.tmuxName) { try tmux.kill(s.tmuxName) }
        try update(s.id) {
            $0.agent = newAgent.id
            $0.provider = provider
            $0.model = model
            if !sameAgent { $0.nativeId = nil }
            // Sessão adotada do Xirp passa a rodar no servidor do Bando.
            if $0.tmuxServer != Tmux.bandoServer { $0.tmuxServer = Tmux.bandoServer; $0.tmuxName = "bando_\($0.shortId)" }
        }
        try record(s.id, kind: "swap-agent", detail: "\(s.agent)\(s.provider.map { "·\($0)" } ?? "") → \(newAgent.id)\(provider.map { "·\($0)" } ?? "") (levou: \(carried.rawValue))")
        guard let updated = try store.session(s.id) else { return }
        if sameAgent {
            try start(updated, mode: .resume)
        } else {
            progress("Abrindo \(newAgent.name)…")
            try start(updated, mode: .handoff(handoffPrompt(updated, from: s.agent, carried: carried)))
        }
    }

    /// Prepara o arquivo de repasse. Devolve o que de fato foi levado.
    func prepareHandoff(_ s: Session, mode: HandoffMode, live: Bool, tmux: Tmux,
                        progress: (String) -> Void) throws -> HandoffMode {
        let file = Handoff.url(worktree: s.worktreePath)
        switch mode {
        case .none:
            return .none
        case .transcript:
            if s.agent == "claude", let native = s.nativeId,
               let md = Handoff.claudeTranscriptMarkdown(nativeId: native, title: s.name) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try md.write(to: file, atomically: true, encoding: .utf8)
                Handoff.ensureIgnored(worktree: s.worktreePath)
                progress("Conversa exportada para \(Handoff.relativePath)")
                return .transcript
            }
            // Só há exportação do Claude Code; para os outros, pede o resumo.
            progress("Exportação da conversa só existe para o Claude Code; pedindo um resumo ao agente.")
            return try prepareHandoff(s, mode: .summary, live: live, tmux: tmux, progress: progress)
        case .summary:
            guard live else {
                progress("O agente atual não está rodando; seguindo só com a tarefa.")
                return .none
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            Handoff.ensureIgnored(worktree: s.worktreePath)
            let before = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
            let request = Handoff.template(paths: paths).replacingOccurrences(of: "{arquivo}", with: Handoff.relativePath)
            try tmux.send(s.tmuxName, text: request, enter: true)
            try record(s.id, kind: "handoff-request")
            progress("Pedindo ao agente atual o resumo em \(Handoff.relativePath)…")
            // Espera o arquivo aparecer e ficar estável (até 10 min). Espera
            // limitada e iniciada pelo usuário; não é acompanhamento de estado.
            let deadline = Date().addingTimeInterval(600)
            var lastSize: UInt64 = 0, stableSince = Date()
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                guard let mod = attrs?[.modificationDate] as? Date, mod > before,
                      let size = attrs?[.size] as? UInt64, size > 0 else { continue }
                if size != lastSize { lastSize = size; stableSince = Date(); continue }
                let current = try store.session(s.id)?.status
                if Date().timeIntervalSince(stableSince) >= 3 && current != .working { 
                    progress("Resumo pronto (\(size) bytes).")
                    return .summary
                }
            }
            progress("O resumo não ficou pronto em 10 minutos; seguindo só com a tarefa.")
            return .none
        }
    }

    func handoffPrompt(_ s: Session, from previous: String, carried: HandoffMode) -> String {
        let name = config.agents[previous]?.name ?? previous
        var text = "Você está continuando o trabalho desta sessão, que antes estava com o agente \(name)."
        switch carried {
        case .summary: text += " Leia primeiro o arquivo \(Handoff.relativePath): é um resumo escrito por ele, com comandos, decisões e próximos passos."
        case .transcript: text += " Leia primeiro o arquivo \(Handoff.relativePath): é a conversa anterior completa."
        case .none: break
        }
        if let p = s.prompt, !p.isEmpty { text += " Tarefa original: \(p)" }
        text += " Veja também o estado atual do código (git status e git diff) antes de seguir."
        return text
    }

    /// Nova sessão a partir desta: novo worktree saindo do branch atual e,
    /// se o agente suportar, conversa bifurcada da original.
    public func fork(_ id: String) throws -> Session {
        let s = try store.findSession(id)
        guard let project = try store.project(s.projectId) else { throw BandoError.notFound("projeto da sessão") }
        let forked = try create(NewSession(
            project: project, prompt: nil, name: "Fork de \(s.name)", agent: s.agent,
            provider: s.provider, model: s.model, baseBranch: s.branch ?? s.baseBranch,
            useWorktree: s.usesWorktree, startNow: false
        ))
        if let native = s.nativeId {
            try start(forked, mode: .fork(native))
        } else {
            try start(forked, mode: .fresh)
        }
        try record(forked.id, kind: "fork", detail: s.id)
        return try store.session(forked.id) ?? forked
    }

    /// Terminal comum no mesmo worktree, como uma sessão própria (aparece na
    /// lateral e pode ir para a grade).
    public func newTerminal(_ id: String) throws -> Session {
        let s = try store.findSession(id)
        guard let project = try store.project(s.projectId) else { throw BandoError.notFound("projeto da sessão") }
        let tid = UUID().uuidString.lowercased()
        let term = Session(
            id: tid, projectId: project.id, name: "Terminal · \(s.name)", prompt: nil, agent: "shell",
            provider: nil, model: nil, worktreePath: s.worktreePath, branch: s.branch, baseBranch: s.baseBranch,
            usesWorktree: false, tmuxName: "bando_\(tid.prefix(8))", status: .starting
        )
        try store.pool.write { db in
            try term.insert(db)
            var e = SessionEvent(sessionId: tid, kind: "created", status: .starting, detail: "terminal de \(s.id)")
            try e.insert(db)
        }
        try start(term, mode: .fresh)
        return try store.session(tid) ?? term
    }

    func update(_ id: String, _ change: (inout Session) -> Void) throws {
        try store.pool.write { db in
            guard var s = try Session.fetchOne(db, key: id) else { throw BandoError.notFound("sessão \(id)") }
            change(&s)
            s.updatedAt = Date()
            try s.update(db)
        }
        ChangeNotifier.post()
    }

    // MARK: - Estado

    /// Muda o estado, grava o evento, avisa os outros processos, notifica o
    /// usuário quando precisa e libera as sessões da fila.
    public func transition(_ id: String, to status: SessionStatus, kind: String = "status",
                           detail: String? = nil, exitCode: Int? = nil) throws {
        let now = Date()
        let changed: Session? = try store.pool.write { db in
            guard var s = try Session.fetchOne(db, key: id) else { return nil }
            // Parada pelo usuário não vira erro quando o supervisor morre em seguida.
            if s.status == .stopped && (status == .error || status == .exited) && kind == "exit" { return nil }
            let previous = s.status
            // Sem mudança: não grava (hooks como PreToolUse chegam a cada ferramenta).
            if previous == status && detail == s.statusDetail && exitCode == nil { return nil }
            s.status = status
            s.statusDetail = detail
            s.updatedAt = now
            if previous != status { s.statusChangedAt = now }
            if let exitCode { s.exitCode = exitCode }
            if [.exited, .error, .stopped].contains(status) { s.finishedAt = now }
            try s.update(db)
            var e = SessionEvent(sessionId: id, kind: kind, status: status, detail: detail, at: now)
            try e.insert(db)
            return previous == status ? nil : s
        }
        ChangeNotifier.post()
        guard let s = changed else { return }

        switch status {
        case .waiting:
            UserNotifier.notify(title: "\(s.name) está esperando você", body: detail ?? s.agent, paths: paths)
        case .review:
            UserNotifier.notify(title: "\(s.name) terminou", body: "Pronto para revisar", paths: paths)
        case .error:
            UserNotifier.notify(title: "\(s.name) falhou", body: detail ?? "código \(exitCode ?? -1)", paths: paths)
        default: break
        }
        if status.releasesDependents { try startDependents(of: id) }
    }

    public func record(_ id: String, kind: String, detail: String? = nil) throws {
        try store.pool.write { db in
            var e = SessionEvent(sessionId: id, kind: kind, detail: detail)
            try e.insert(db)
        }
    }

    public func setNativeId(_ id: String, nativeId: String) throws {
        try store.pool.write { db in
            try db.execute(sql: "UPDATE session SET nativeId = ?, updatedAt = ? WHERE id = ?",
                           arguments: [nativeId, Date(), id])
        }
        ChangeNotifier.post()
    }

    /// Marca a sessão como vista: `review` vira `idle`.
    public func markSeen(_ id: String) throws {
        let s = try store.session(id)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE session SET seenAt = ? WHERE id = ?", arguments: [Date(), id])
        }
        if s?.status == .review { try transition(id, to: .idle, kind: "seen") } else { ChangeNotifier.post() }
    }

    func startDependents(of id: String) throws {
        let children = try store.pool.read { db in
            try Session.filter(Column("dependsOn") == id && Column("status") == SessionStatus.queued.rawValue).fetchAll(db)
        }
        for child in children {
            do {
                try start(child, mode: .fresh)
            } catch {
                try? transition(child.id, to: .error, kind: "start-failed", detail: error.localizedDescription)
            }
        }
    }

    /// Acerta sessões marcadas como vivas cujo tmux sumiu (máquina reiniciada,
    /// `tmux kill-server`). Chamado ao abrir o app e no `bando ls`.
    public func reconcile() throws {
        let live = try store.sessions().filter { $0.status.isLive }
        var byServer: [String: Set<String>] = [:]
        for s in live where byServer[s.tmuxServer] == nil {
            byServer[s.tmuxServer] = Set((try? Tmux(server: s.tmuxServer))?.listSessions() ?? [])
        }
        for s in live where !(byServer[s.tmuxServer]?.contains(s.tmuxName) ?? false) {
            try transition(s.id, to: .stopped, kind: "reconcile", detail: "sessão tmux não existe mais")
        }
    }

    /// Plano de lançamento do agente para esta sessão (usado pelo `bando run`).
    public func launchPlan(for s: Session, resume: Bool, forkFrom: String? = nil,
                           promptOverride: String? = nil) throws -> (LaunchPlan, AgentDefinition, assignedId: String?) {
        let agent = try config.agent(s.agent)
        let provider = try s.provider.map { try config.provider($0) }
        var mode: LaunchRequest.Mode = .fresh
        if resume { mode = s.nativeId.map { .resume(nativeId: $0) } ?? .continueLast }
        if let forkFrom { mode = .fork(nativeId: forkFrom) }
        let newId = (mode == .fresh && !agent.assignId.isEmpty) ? UUID().uuidString.lowercased() : nil
        let hookArgs = (agent.status == .hooks)
            ? HookPresets.launchArgs(preset: agent.hooks, bandoPath: BandoCLI.path(), sessionId: s.id) : []
        let project = try store.project(s.projectId)
        let servers = mcpServers(for: agent, project: project)
        let mcp = agent.mcp.map {
            McpLaunch.build(servers, adapter: $0, runDir: paths.stateDir.appendingPathComponent("run"), sessionId: s.id)
        } ?? McpLaunch()
        let plan = try LaunchPlan.build(LaunchRequest(
            agent: agent, provider: provider, model: s.model,
            prompt: promptOverride ?? (mode == .fresh ? s.prompt : nil), mode: mode, sessionId: s.id,
            worktree: s.worktreePath, branch: s.branch, newNativeId: newId, hookArgs: hookArgs, mcp: mcp
        ))
        return (plan, agent, newId)
    }

    /// Servidores MCP do Bando que valem para este agente e projeto.
    public func mcpServers(for agent: AgentDefinition, project: Project?) -> [McpServer] {
        guard agent.mcp != nil else { return [] }
        return config.mcp.values.filter { $0.applies(agent: agent.id, project: project) }.sorted { $0.id < $1.id }
    }

    /// Como o estado desta sessão é detectado de fato.
    public func effectiveStatusMode(_ agent: AgentDefinition) -> StatusMode {
        switch agent.status {
        case .hooks: HookPresets.supports(agent.hooks) ? .hooks : (agent.busy != nil || agent.waiting != nil ? .output : .silence)
        default: agent.status
        }
    }
}
