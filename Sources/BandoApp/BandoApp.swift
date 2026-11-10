import AppKit
import BandoCore
import Sparkle
import SwiftUI
import UserNotifications

@main
struct BandoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    private let updater = Updater.shared

    var body: some Scene {
        WindowGroup("Bando", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    delegate.model = model
                    await model.start()
                }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Mostrar ou esconder a lateral") { model.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nova sessão") { model.openComposer() }.keyboardShortcut("n")
                Button("Adicionar projeto…") { model.showAddProject = true }.keyboardShortcut("o")
                Button("Importar workspace…") { model.showImportWorkspace = true }
            }
            CommandMenu("Sessão") {
                Button("Buscar sessão…") { model.showPalette = true }.keyboardShortcut("k")
                Button("Próxima esperando você") { model.selectNextWaiting() }.keyboardShortcut("j")
                Divider()
                ForEach(1...9, id: \.self) { i in
                    Button("Sessão \(i)") { model.selectIndex(i - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i)")))
                }
                Divider()
                Button("Parar…") { if let id = model.selection { model.requestStop([id]) } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.selectedSession?.status.isLive != true)
                Button("Retomar") { if let id = model.selection { model.resumeSession(id) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selectedSession == nil || model.selectedSession?.status.isLive == true)
                Button("Mostrar no Finder") { if let s = model.selectedSession { model.reveal(s) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button(model.showFiles ? "Esconder arquivos" : "Mostrar arquivos") { model.showFiles.toggle() }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Recarregar configuração") { Task { await model.reload() } }
            }
            CommandGroup(replacing: .help) {
                Button("Atalhos de teclado") { model.showShortcuts = true }.keyboardShortcut("/")
                Button("Documentação") { NSWorkspace.shared.open(HelpMenu.repo.appendingPathComponent("blob/main/README.md")) }
                Button("Reportar problema") { NSWorkspace.shared.open(HelpMenu.repo.appendingPathComponent("issues/new")) }
            }
            CommandGroup(after: .toolbar) {
                Button(model.gridMode ? "Mostrar uma sessão" : "Mostrar grade") { model.toggleGrid() }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                ForEach(Array(GridPreset.all.enumerated()), id: \.element) { i, g in
                    Button("Grade \(g.label)") { model.setGrid(cols: g.cols, rows: g.rows) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
                Button("Igualar tamanhos da grade") { model.equalize(columns: true); model.equalize(columns: false) }
                Button("Detalhes da sessão") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Aumentar fonte do terminal") { model.fontSize = min(model.fontSize + 1, 24) }
                    .keyboardShortcut("+")
                Button("Diminuir fonte do terminal") { model.fontSize = max(model.fontSize - 1, 9) }
                    .keyboardShortcut("-")
            }
        }

        Window("Uso e custo", id: "usage") {
            UsageWindow().environment(model)
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .defaultSize(width: 820, height: 760)

        Window("Relatórios", id: "reports") {
            ReportsWindow().environment(model)
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .defaultSize(width: 1000, height: 820)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Fecha o app sem matar as sessões (elas vivem no tmux) e trata cliques nas
/// notificações.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["update"] != nil {
            await MainActor.run {
                NSApp.activate()
                NotificationCenter.default.post(name: Updater.showUpdate, object: nil)
            }
            return
        }
        let id = response.notification.request.content.userInfo["session"] as? String
        await open(session: id)
    }

    func open(session id: String?) {
        NSApp.activate()
        if let id { model?.select(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Sparkle só liga quando o app roda empacotado (Info.plist com SUFeedURL).
///
/// Para a versão nova aparecer logo depois de publicada, além da checagem do
/// Sparkle (a cada hora), o app consulta o appcast ao voltar para a frente e a
/// cada 15 minutos. É um GET de poucos KB; sem versão nova, nada aparece.
///
/// Versão nova encontrada com o app fora de foco: o Sparkle não interrompe e o
/// Bando manda uma notificação do macOS; clicar nela abre a janela "Instalar".
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()
    static let showUpdate = Notification.Name("bando.showUpdate")
    nonisolated private static let notificationId = "bando-update"
    private(set) var controller: SPUStandardUpdaterController?
    /// Versão já baixada (modo automático) esperando para instalar, e como
    /// instalar agora sem esperar o app fechar.
    @Published private(set) var readyVersion: String?
    /// Versão nova encontrada no appcast (ainda não baixada ou não instalada).
    @Published private(set) var availableVersion: String?
    private var installNow: (() -> Void)?
    private var timer: Timer?
    private var lastCheck = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        // Para ver o badge sem publicar versão: abrir com -debugUpdateBadge 9.9.9
        availableVersion = UserDefaults.standard.string(forKey: "debugUpdateBadge")
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
        guard hasFeed else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        observers.append(NotificationCenter.default.addObserver(forName: Self.showUpdate, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let installNow = self.installNow { installNow() } else { self.controller?.checkForUpdates(nil) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuietly(minInterval: 5 * 60) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuietly(minInterval: 10 * 60) }
        }
        timer?.tolerance = 60
    }

    /// Checagem em segundo plano: só mostra algo se houver versão nova.
    private func checkQuietly(minInterval: TimeInterval) {
        guard let updater = controller?.updater, updater.canCheckForUpdates,
              Date().timeIntervalSince(lastCheck) >= minInterval else { return }
        lastCheck = Date()
        updater.checkForUpdatesInBackground()
    }

    /// Reinicia e instala a versão já baixada.
    func installReadyUpdate() { installNow?() }

    /// Badge da barra: instala a já baixada, ou abre a janela do Sparkle.
    func openUpdate() {
        if let installNow { installNow() } else { controller?.checkForUpdates(nil) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { self.availableVersion = nil }
    }

    // MARK: Atualização baixada em segundo plano (SPUUpdaterDelegate)

    /// No modo "baixar e instalar automaticamente" o Sparkle só instalaria ao
    /// fechar o app, sem avisar. O Bando avisa por notificação e pelo menu, e
    /// um clique reinicia e instala na hora.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        // O Sparkle chama os delegates na main thread.
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated {
            self.installNow = install
            self.readyVersion = version
        }
        Task { @MainActor in
            let content = UNMutableNotificationContent()
            content.title = "Bando \(version) pronto para instalar"
            content.body = "Clique para reiniciar e instalar agora. As sessões continuam no tmux."
            content.userInfo = ["update": version]
            let request = UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
        return true
    }

    // MARK: Lembrete gentil (SPUStandardUserDriverDelegate)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Com o app em foco, o Sparkle mostra a janela na hora; fora de foco, quem
    /// avisa é a notificação abaixo.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated, !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            NSApp.requestUserAttention(.informationalRequest)
            let content = UNMutableNotificationContent()
            content.title = "Bando \(version) disponível"
            content.body = "Clique para ver as novidades e instalar. As sessões continuam rodando."
            content.userInfo = ["update": version]
            let request = UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let v = updater.readyVersion {
            Button("Reiniciar e instalar a \(v)") { updater.installReadyUpdate() }
        }
        Button("Procurar atualizações…") { updater.controller?.checkForUpdates(nil) }
            .disabled(updater.controller == nil)
    }
}

/// Badge na barra de cima quando há versão nova: degradê verde, some sozinho
/// quando não há atualização.
struct UpdateBadge: View {
    @ObservedObject var updater = Updater.shared
    @State private var hovering = false

    var body: some View {
        if let version = updater.readyVersion ?? updater.availableVersion {
            let ready = updater.readyVersion != nil
            Button { updater.openUpdate() } label: {
                HStack(spacing: 5) {
                    Image(systemName: ready ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(ready ? "Reiniciar para a \(version)" : "Atualizar para a \(version)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 24)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(red: 0x16 / 255, green: 0xC4 / 255, blue: 0x5A / 255),
                                 Color(red: 0x0E / 255, green: 0x9F / 255, blue: 0x8E / 255)],
                        startPoint: .leading, endPoint: .trailing))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.35 : 0.18)))
                .shadow(color: Color(red: 0x16 / 255, green: 0xC4 / 255, blue: 0x5A / 255).opacity(0.35), radius: hovering ? 6 : 3)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointerCursor()
            .tooltip(ready ? "Reinicia e instala agora. As sessões continuam no tmux." : "Ver as novidades e instalar")
        }
    }
}
