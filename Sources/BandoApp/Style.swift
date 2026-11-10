import AppKit
import BandoCore
import SwiftUI

extension RGB {
    var color: Color { let (r, g, b) = unit; return Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { let (r, g, b) = unit; return NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// Símbolo do logo desenhado como forma: herda a cor do texto, então fica
/// preto no tema claro e branco no escuro sem precisar de duas imagens.
struct BandoSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        // Coordenadas do SVG original (viewBox 290 195 685 865).
        let outer: [CGPoint] = [(515, 215), (830, 410), (830, 585), (955, 665), (955, 835), (620, 1040), (310, 840), (310, 335)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let inner: [CGPoint] = [(515, 395), (515, 955), (800, 745), (670, 665), (670, 490)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        let box = CGRect(x: 290, y: 195, width: 685, height: 865)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - box.midX * scale, dy = rect.midY - box.midY * scale
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + dx, y: p.y * scale + dy) }
        var p = Path()
        p.addLines(outer.map(t)); p.closeSubpath()
        p.addLines(inner.map(t)); p.closeSubpath()
        return p
    }
}

struct BandoMark: View {
    var size: CGFloat = 16
    var body: some View {
        BandoSymbol()
            .fill(.primary, style: FillStyle(eoFill: true))
            .frame(width: size * 0.8, height: size)
            .accessibilityLabel("bando")
    }
}

/// Estado com cor e forma juntas (quem não distingue cores ainda vê a forma).
struct StatusIcon: View {
    let status: SessionStatus
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch status {
            case .working, .starting:
                ProgressView().controlSize(.mini).frame(width: size, height: size)
            default:
                Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(color)
            }
        }
        .frame(width: size + 2, height: size + 2)
        .tooltip(status.label)
        .accessibilityLabel(status.label)
    }

    var symbol: String {
        switch status {
        case .waiting: "exclamationmark.circle.fill"
        case .review: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .queued: "clock"
        case .idle: "circle"
        case .stopped: "stop.circle"
        case .exited: "checkmark.circle"
        case .working, .starting: "circle.dotted"
        }
    }

    var color: Color {
        switch status {
        case .waiting: .orange
        case .review: .green
        case .error: .red
        case .working, .starting: .blue
        default: .secondary
        }
    }
}

/// Cores de estado (as mesmas do Xirp/Encore, com bom contraste no escuro).
enum StateColor {
    static let working = Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)
    static let waiting = Color(red: 0xFF / 255, green: 0xA4 / 255, blue: 0x2B / 255)
    static let review = Color(red: 0x12 / 255, green: 0x78 / 255, blue: 0xF2 / 255)
    static let failed = Color(red: 0xED / 255, green: 0x2C / 255, blue: 0x3F / 255)
    static let focus = Color(red: 0xFB / 255, green: 0x92 / 255, blue: 0x3C / 255)
    static let cyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let magenta = Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0xF9 / 255)

    static func dot(_ s: SessionStatus) -> Color? {
        switch s {
        case .working, .starting: working
        case .waiting: waiting
        case .review: review
        case .error: failed
        default: nil
        }
    }

    static func label(_ s: SessionStatus) -> String {
        switch s {
        case .working, .starting: "trabalhando"
        case .waiting: "esperando"
        case .review: "pronto"
        case .error: "erro"
        case .queued: "na fila"
        case .idle: "ocioso"
        case .stopped: "parado"
        case .exited: "encerrado"
        }
    }
}

func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "agora" }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) h" }
    return "\(s / 86400) d"
}

/// Cores da interface derivadas do tema: moldura, painel, textos, seleção.
/// Assim qualquer tema (Dracula, Nord...) muda o app inteiro, não só o terminal.
struct UIPalette {
    var isDark: Bool
    var chrome: Color      // moldura (fundo da janela)
    var card: Color        // cartões da lateral e do conteúdo
    var chromeNS: NSColor
    var panel: Color       // painel do conteúdo (fundo do terminal)
    var text: Color
    var secondary: Color
    var tertiary: Color
    var hover: Color
    var selected: Color
    var border: Color
    var accent: Color
    var onAccent: Color

    init(theme: ThemeDefinition?) {
        guard let t = theme else {
            self = UIPalette(theme: ThemeDefinition(
                id: "x", name: "x", appearance: .dark, accent: RGB(r: 230, g: 230, b: 233),
                background: RGB(r: 11, g: 11, b: 13), foreground: RGB(r: 230, g: 230, b: 233),
                cursor: RGB(r: 255, g: 255, b: 255), selection: RGB(r: 42, g: 42, b: 49),
                ansi: Array(repeating: RGB(r: 128, g: 128, b: 128), count: 16)))
            return
        }
        isDark = t.appearance == .dark
        let bg = t.background, fg = t.foreground
        // Moldura um pouco mais escura que o painel no tema escuro, e um pouco
        // mais acinzentada no claro.
        // Escuro: moldura quase preta e cartões um tom acima (padrão do Xirp,
        // #000 e #121212). Claro: moldura acinzentada e cartões no fundo do tema.
        let chromeRGB = isDark ? bg.mixed(with: RGB(r: 0, g: 0, b: 0), 0.6)
                               : bg.mixed(with: RGB(r: 120, g: 120, b: 130), 0.10)
        chrome = chromeRGB.color
        chromeNS = chromeRGB.nsColor
        card = isDark ? bg.mixed(with: RGB(r: 255, g: 255, b: 255), 0.035).color : bg.color
        panel = bg.color
        text = fg.color
        secondary = fg.color.opacity(0.62)
        tertiary = fg.color.opacity(0.4)
        hover = fg.color.opacity(isDark ? 0.06 : 0.05)
        selected = fg.color.opacity(isDark ? 0.14 : 0.10)
        border = fg.color.opacity(isDark ? 0.08 : 0.12)
        accent = t.accent.color
        // Texto sobre o destaque: escolhe o que tiver mais contraste.
        onAccent = t.accent.luminance > 0.55 ? RGB(r: 12, g: 12, b: 14).color : .white
    }
}

extension RGB {
    func mixed(with o: RGB, _ amount: Double) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) * (1 - amount) + Double(b) * amount) }
        return RGB(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b))
    }
    var luminance: Double { let (r, g, b) = unit; return 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = UIPalette(theme: nil) }
extension EnvironmentValues {
    var palette: UIPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Botão de ícone discreto, como os da barra do Xirp.
struct IconButton: View {
    @Environment(\.palette) private var p
    let symbol: String
    var help: String
    /// 16 pt na barra de cima (navegação), 14 pt nas ações dos painéis.
    var size: CGFloat = 14
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(hovering ? p.text : p.secondary)
                .frame(width: size + 14, height: size + 12)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? p.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .tooltip(help)
    }
}

/// Botão principal com o destaque do tema.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    /// Cor no lugar do destaque (vermelho para ações que interrompem).
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 30)
            .foregroundStyle(tint == nil ? p.onAccent : .white)
            .background(RoundedRectangle(cornerRadius: 6).fill((tint ?? p.accent).opacity(configuration.isPressed ? 0.85 : 1)))
            .opacity(enabled ? 1 : 0.45)
            .pointerCursor()
    }
}

/// Botão secundário: contorno fino, fundo só no hover.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View { OutlineBody(configuration: configuration, p: p, enabled: enabled) }

    private struct OutlineBody: View {
        let configuration: Configuration
        let p: UIPalette
        let enabled: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).frame(height: 30)
                .foregroundStyle(p.text)
                .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? p.selected : (hovering ? p.hover : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border.opacity(2)))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .pointerCursor()
        }
    }
}

/// Cabeçalho de modal: título, descrição curta em cinza e ícone pequeno opcional.
struct DialogHeader: View {
    @Environment(\.palette) private var p
    let title: String
    var description: String? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(p.secondary) }
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
            }
            if let description {
                Text(description).font(.system(size: 12.5)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rótulo de campo, 12 pt médio.
struct FieldLabel: View {
    @Environment(\.palette) private var p
    let text: String
    var hint: String? = nil
    init(_ text: String, hint: String? = nil) { self.text = text; self.hint = hint }
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
            if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(p.tertiary) }
        }
    }
}

/// Campo com borda fina e cantos de 6 pt (texto, menu ou editor).
struct FieldBox: ViewModifier {
    @Environment(\.palette) private var p
    var height: CGFloat? = 30
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.panel.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border.opacity(2)))
    }
}

extension View {
    func fieldBox(height: CGFloat? = 30) -> some View { modifier(FieldBox(height: height)) }

    /// Moldura comum dos modais: fundo do tema, margem de 20 pt e largura fixa.
    func dialog(width: CGFloat, palette p: UIPalette) -> some View {
        self
            .padding(20)
            .frame(width: width)
            .background(p.card)
            .foregroundStyle(p.text)
            .environment(\.palette, p)
            .environment(\.colorScheme, p.isDark ? .dark : .light)
    }
}

/// Linha divisória fina entre blocos de um modal.
struct DialogDivider: View {
    @Environment(\.palette) private var p
    var body: some View { Rectangle().fill(p.border).frame(height: 1) }
}

/// Barra de título transparente pintada com a cor da moldura do tema. Os
/// controles do topo ficam na barra de ferramentas nativa (clicáveis e
/// alinhados com os botões da janela).
struct WindowChrome: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(nsView.window) }
    }

    private func apply(_ w: NSWindow?) {
        guard let w else { return }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = color
        w.toolbar?.showsBaselineSeparator = false
    }
}

/// Área que arrasta a janela (fundo da barra superior). Clique duplo maximiza,
/// como na barra de título do sistema.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Mãozinha ao passar o mouse em algo clicável.
struct PointerCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
                .onHover { inside in
                    if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                    if !inside, pushed { NSCursor.pop(); pushed = false }
                }
                .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
        }
    }
}

extension View {
    func pointerCursor() -> some View { modifier(PointerCursor()) }
}

/// Seletor com a mesma cara dos campos: valor atual e setas à direita.
struct SelectField<T: Hashable>: View {
    @Environment(\.palette) private var p
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var placeholder = "Escolha…"

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].label) { selection = options[i].value }
            }
        } label: {
            HStack(spacing: 6) {
                let current = options.first { $0.value == selection }?.label
                Text(current ?? placeholder).foregroundStyle(current == nil ? p.tertiary : p.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fieldBox()
        .pointerCursor()
    }
}

/// Rótulo de seção dentro de popover: 11 pt médio, cinza.
struct PopoverLabel: View {
    @Environment(\.palette) private var p
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(p.tertiary)
    }
}
