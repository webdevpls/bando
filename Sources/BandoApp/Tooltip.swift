import AppKit
import SwiftUI

/// Tooltip próprio: balão pequeno abaixo do ícone, com o atalho à parte.
/// Um único painel para o app inteiro; aparece após 0,4 s parado em cima.
extension View {
    /// "Grade (⌥⌘G)" vira texto "Grade" e atalho "⌥⌘G".
    func tooltip(_ text: String) -> some View {
        background(TooltipAnchor(text: text))
            .accessibilityHint(text)
    }
}

private struct TooltipAnchor: NSViewRepresentable {
    @Environment(\.palette) private var p
    let text: String

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.text = text
        view.palette = p
    }

    final class AnchorView: NSView {
        var text = ""
        var palette = UIPalette(theme: nil)
        private var area: NSTrackingArea?

        // Não intercepta cliques: o botão de cima continua recebendo tudo.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(a)
            area = a
        }

        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            TooltipPanel.shared.show(text, palette: palette, below: rect, owner: self)
        }
        override func mouseExited(with event: NSEvent) { TooltipPanel.shared.hide(owner: self) }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { TooltipPanel.shared.hide(owner: self) }
        }
    }
}

@MainActor
final class TooltipPanel {
    static let shared = TooltipPanel()
    private var panel: NSPanel?
    private var pending: Task<Void, Never>?
    private weak var owner: NSView?
    private var clickMonitor: Any?

    func show(_ text: String, palette: UIPalette, below anchor: NSRect, owner: NSView) {
        pending?.cancel()
        self.owner = owner
        // Se já havia um tooltip aberto (passando de ícone em ícone), troca na hora.
        let delay: Duration = panel?.isVisible == true ? .zero : .milliseconds(400)
        pending = Task { [weak self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.owner === owner else { return }
            self.present(text, palette: palette, below: anchor)
        }
    }

    func hide(owner: NSView) {
        guard self.owner === owner else { return }
        pending?.cancel()
        self.owner = nil
        panel?.orderOut(nil)
    }

    private func present(_ text: String, palette: UIPalette, below anchor: NSRect) {
        let (label, shortcut) = Self.split(text)
        let host = NSHostingView(rootView: TooltipBubble(text: label, shortcut: shortcut, p: palette))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY { origin.y = anchor.maxY + 6 }   // sem espaço embaixo: vai para cima
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
                self?.pending?.cancel(); self?.panel?.orderOut(nil); return e
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.collectionBehavior = [.transient, .ignoresCycle]
        panel = p
        return p
    }

    static func split(_ text: String) -> (String, String?) {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return (text, nil) }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard inner.contains(where: { "⌘⌥⌃⇧".contains($0) }) else { return (text, nil) }
        return (text[..<open].trimmingCharacters(in: .whitespaces), String(inner))
    }
}

private struct TooltipBubble: View {
    let text: String
    let shortcut: String?
    let p: UIPalette

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12, weight: .medium))
            if let shortcut {
                Text(shortcut).font(.system(size: 11, weight: .medium)).opacity(0.6)
            }
        }
        .foregroundStyle(p.isDark ? Color.black : Color.white)
        .padding(.horizontal, 9).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.isDark ? p.text : Color(white: 0.1)))
        .fixedSize()
    }
}
