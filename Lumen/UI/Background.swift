import SwiftUI
import UIKit

/// Very slow drift. The animation is handed to the render server once (repeatForever),
/// so SwiftUI does no work per frame.
private struct SlowDrift: ViewModifier {
    var swayX: CGFloat = 0
    var swayY: CGFloat = 0
    var seconds: Double = 60

    @State private var sx: Double = -1
    @State private var sy: Double = -1

    func body(content: Content) -> some View {
        content
            .offset(x: swayX * CGFloat(sx), y: swayY * CGFloat(sy))
            .onAppear {
                withAnimation(.easeInOut(duration: seconds).repeatForever(autoreverses: true)) { sx = 1 }
                withAnimation(.easeInOut(duration: seconds * 1.31).repeatForever(autoreverses: true)) { sy = 1 }
            }
    }
}

/// App wallpaper: plain black, plain white, or a colourful blur made from the song cover that
/// floats very slowly.
struct AnimatedBackground: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    var isActive: Bool = true
    @State private var blurred: UIImage? = nil
    @State private var blurVersion = 0

    private var key: String {
        "\(settings.data.theme.rawValue)|\(settings.data.artworkBlur)|\(engine.currentTrack?.id ?? "-")|\(engine.artwork != nil)"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch settings.data.theme {
                case .black:
                    Color.black
                case .white:
                    Color.white
                case .blur:
                    if settings.data.artworkBlur {
                        colorful(size: geo.size)
                    } else {
                        sharpCover(size: geo.size)
                    }
                case .color:
                    customColor
                case .image:
                    customImage(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: key) { await rebuild() }
    }

    /// Okładka bez rozmycia (przycisk "Rozmycie okładki" wyłączony).
    private func sharpCover(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let art = engine.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            Color.black.opacity(settings.data.dim)
        }
    }

    private var customColor: some View {
        let a = Color(hex: settings.data.backgroundColorHex)
        let b = Color(hex: settings.data.backgroundColor2Hex)
        return Group {
            if settings.data.backgroundGradient {
                LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
            } else {
                a
            }
        }
    }

    private func customImage(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let img = settings.backgroundImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(settings.data.imageBlur ? 1.15 : 1)   // zasłania jasne brzegi po rozmyciu
                    .blur(radius: settings.data.imageBlur ? settings.data.imageBlurRadius : 0)
                    .clipped()
            }
            Color.black.opacity(settings.data.dim)
        }
    }

    private var colors: [Color] {
        let palette = engine.palette.prefix(5).map { Color(uiColor: $0) }
        return palette.isEmpty ? [Color(white: 0.28), Color(white: 0.16)] : palette
    }

    private func colorful(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let img = blurred {
                // Rozciągnięte na cały ekran (bez kadrowania do środka), więc widać WSZYSTKIE kolory okładki.
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width * 1.25, height: size.height * 1.25)
                    .modifier(SlowDrift(swayX: size.width * 0.05, swayY: size.height * 0.04, seconds: 80))
                    .opacity(0.9)
                    .id(blurVersion)
                    .transition(.opacity)
            }
            blobs(size: size)
                .id(blurVersion)
                .transition(.opacity)
            Color.black.opacity(settings.data.dim)
        }
    }

    private func blobs(size: CGSize) -> some View {
        let big = max(size.width, size.height) * 0.85
        let list = colors
        // Każdy kolor ma swój róg ekranu, więc kolory się nie zlewają w jedną plamę na środku.
        let anchors: [(CGFloat, CGFloat)] = [(0.2, 0.18), (0.85, 0.3), (0.22, 0.78), (0.82, 0.86), (0.5, 0.5)]
        return ZStack {
            ForEach(0..<list.count, id: \.self) { i in
                let a = anchors[i % anchors.count]
                Circle()
                    .fill(RadialGradient(colors: [list[i].opacity(0.85), list[i].opacity(0)],
                                         center: .center, startRadius: 0, endRadius: big * 0.5))
                    .frame(width: big, height: big)
                    .modifier(SlowDrift(swayX: size.width * 0.16, swayY: size.height * 0.12,
                                        seconds: 55 + Double(i) * 19))
                    .position(x: size.width * a.0, y: size.height * a.1)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func rebuild() async {
        guard settings.data.theme == .blur, let src = engine.artwork else {
            if engine.artwork == nil { blurred = nil }
            return
        }
        let result = await Task.detached(priority: .utility) { ArtworkLoader.blurred(src, radius: 9, saturation: 1.6) }.value
        // Płynne przejście kolorów (rozmyty obraz i plamy zmieniają się z wygaszaniem, a nie skokiem).
        withAnimation(.easeInOut(duration: 1.3)) {
            blurred = result
            blurVersion += 1
        }
    }
}
