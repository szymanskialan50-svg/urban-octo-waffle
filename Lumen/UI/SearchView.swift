import SwiftUI

/// Search state lives outside the view so it survives switching tabs.
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Track] = []
    @Published var loading = false
    @Published var message: String? = nil
}

struct SearchView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @ObservedObject var model: SearchModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @State private var batch: TrackBatch? = nil
    @State private var showImport = false
    @FocusState private var focused: Bool

    private var isLink: Bool { YouTubeURL.parse(model.query) != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Szukaj")
            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            if !settings.api.hasKey {
                keyNotice
            }
            if isLink {
                Button { showImport = true } label: {
                    Label("Importuj ten link z YouTube", systemImage: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .glass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Group {
            if model.loading {
                ProgressView().tint(accentInk).padding(.top, 40)
                Spacer()
            } else if model.results.isEmpty {
                ScrollView {
                    EmptyHint(icon: "magnifyingglass",
                              title: model.message ?? "Szukaj w YouTube",
                              message: model.message == nil ? "Wpisz piosenkę lub wykonawcę albo wklej link z YouTube." : "")
                        .padding(.top, 50)
                }
            } else {
                List {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, t in
                        TrackRow(track: t,
                                 isCurrent: engine.currentTrack?.id == t.id,
                                 onPlay: { engine.play(model.results, startAt: index) },
                                 onAddToPlaylist: { batch = TrackBatch(tracks: [t]) })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(.easeInOut(duration: 0.28), value: model.results.count)
            .animation(.easeInOut(duration: 0.28), value: model.loading)
        }
        .sheet(item: $batch) { b in
            AddToPlaylistSheet(tracks: b.tracks)
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showImport) {
            ImportView(initialText: model.query)
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(ink.opacity(0.7))
            ZStack(alignment: .leading) {
                TextField("Szukaj", text: $model.query, prompt: Text(""))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .foregroundStyle(ink)
                    .onSubmit { runSearch() }
                // Animacja pisania zamiast zwykłego tekstu podpowiedzi.
                if model.query.isEmpty {
                    TypingPlaceholder(phrases: ["Szukaj piosenek…", "Wpisz wykonawcę…", "Wklej link z YouTube…"])
                        .transition(.opacity)
                }
            }
            if !model.query.isEmpty {
                Button {
                    // Czyszczenie z animacją: przycisk znika, a wyniki płynnie się wygaszają.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        model.query = ""
                        model.message = nil
                        model.results = []
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ink.opacity(0.6))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.query.isEmpty)
        .glass(Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }

    private var keyNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Wyszukiwanie niedostępne: ta wersja aplikacji nie ma klucza YouTube API.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink)
        .padding(14)
        .glassCard(radius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func runSearch() {
        let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if isLink { showImport = true; return }
        guard settings.api.hasKey else {
            model.message = "Wyszukiwanie niedostępne"
            return
        }
        focused = false
        model.loading = true
        model.message = nil
        let api = settings.api
        Task {
            do {
                let found = try await api.search(q)
                model.results = found
                if found.isEmpty { model.message = "Brak wyników" }
            } catch let err {
                model.results = []
                model.message = err.localizedDescription
            }
            model.loading = false
        }
    }
}

/// Prosta animacja pisania: tekst podpowiedzi "wpisuje się" literka po literce, chwilę trwa i się wymazuje.
struct TypingPlaceholder: View {
    @Environment(\.ink) private var ink
    let phrases: [String]
    @State private var shown = ""
    @State private var caretOn = true

    var body: some View {
        (Text(shown) + Text("\u{258F}").foregroundColor(caretOn ? ink.opacity(0.6) : .clear))
            .foregroundColor(ink.opacity(0.5))
            .lineLimit(1)
            .allowsHitTesting(false)
            .task { await type() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    caretOn.toggle()
                }
            }
    }

    private func type() async {
        guard !phrases.isEmpty else { return }
        var i = 0
        while !Task.isCancelled {
            let phrase = phrases[i % phrases.count]
            for ch in phrase {
                shown.append(ch)
                try? await Task.sleep(nanoseconds: 70_000_000)
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            while !shown.isEmpty {
                shown.removeLast()
                try? await Task.sleep(nanoseconds: 30_000_000)
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            i += 1
        }
    }
}
