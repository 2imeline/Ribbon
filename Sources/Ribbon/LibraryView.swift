import AVKit
import SwiftUI

struct LibraryView: View {
    private static let all = "\u{0}all"
    @StateObject private var model = LibraryModel()
    @State private var selection: String? = LibraryView.all
    @State private var path: [Clip] = []

    private var games: [(name: String, count: Int)] {
        Dictionary(grouping: model.clips, by: \.game)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filtered: [Clip] {
        guard let game = selection, game != Self.all else { return model.clips }
        return model.clips.filter { $0.game == game }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Clips", systemImage: "film.stack").badge(model.clips.count).tag(Self.all)
                if !games.isEmpty {
                    Section("Games") {
                        ForEach(games, id: \.name) { g in
                            Label(g.name, systemImage: "gamecontroller").badge(g.count).tag(g.name)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            NavigationStack(path: $path) {
                ClipGrid(clips: filtered) { path = [$0] }
                    .navigationDestination(for: Clip.self) { clip in
                        ClipPlayerScreen(clip: clip) { path.removeAll() }
                    }
            }
        }
        .toolbar {
            Button { NSWorkspace.shared.open(Library.folder) } label: {
                Label("Open Clips Folder", systemImage: "folder")
            }
        }
        .environmentObject(model)
        .onAppear { model.start(); NSApp.activate() }
        .onDisappear { model.stop() }
        .onChange(of: selection) { path.removeAll() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct DayGroup: Identifiable {
    let day: Date
    let clips: [Clip]
    var id: Date { day }

    var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct ClipGrid: View {
    let clips: [Clip]
    let open: (Clip) -> Void
    @AppStorage(K.hotkeyLabel) private var hotkey = Defaults.hotkeyLabel

    private var days: [DayGroup] {
        Dictionary(grouping: clips) { Calendar.current.startOfDay(for: $0.date) }
            .map { DayGroup(day: $0.key, clips: $0.value) }  // clips stay newest-first
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        if clips.isEmpty {
            ContentUnavailableView("No clips yet", systemImage: "film",
                                   description: Text("Press \(hotkey) in a game to save what just happened."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(days) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title).font(.title3.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 20) {
                                ForEach(group.clips) { clip in ClipCard(clip: clip, open: { open(clip) }) }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct ClipCard: View {
    let clip: Clip
    let open: () -> Void
    @EnvironmentObject private var model: LibraryModel
    @State private var thumb: NSImage?
    @State private var hover = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title).foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if hover {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                .scaleEffect(hover ? 1.015 : 1)
                .animation(.easeOut(duration: 0.15), value: hover)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .onHover { hover = $0 }
                .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }

            if renaming {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.rename(clip.url, to: newName); renaming = false }
                    .onExitCommand { renaming = false }
            } else {
                Text(clip.name)
                    .font(.headline)
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: startRename)
            }
            Text("\(clip.game) · \(clip.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: clip.url) { thumb = await Library.thumbnail(for: clip.url) }
        .contextMenu {
            Button("Play", action: open)
            Button("Rename", action: startRename)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Copy") { Library.copyToPasteboard(clip.url) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(clip.url) }
        }
    }

    private func startRename() {
        newName = clip.name
        renaming = true
    }
}

private final class PlayerViewRef: ObservableObject {
    weak var view: AVPlayerView?
}

private struct PlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let ref: PlayerViewRef

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        ref.view = view
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct ClipPlayerScreen: View {
    let pop: () -> Void
    @EnvironmentObject private var model: LibraryModel
    @StateObject private var ref = PlayerViewRef()
    @State private var player = AVPlayer()
    @State private var url: URL
    @State private var name: String
    @State private var trimming = false

    init(clip: Clip, pop: @escaping () -> Void) {
        self.pop = pop
        _url = State(initialValue: clip.url)
        _name = State(initialValue: clip.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerRepresentable(player: player, ref: ref)
            HStack(spacing: 14) {
                TextField("Clip name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit(commitName)
                Spacer()
                Button(action: trim) { Label("Trim", systemImage: "scissors") }.disabled(trimming)
                Button { Library.copyToPasteboard(url) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the file, then paste it into Discord")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button(role: .destructive) { model.trash(url); pop() } label: { Label("Delete", systemImage: "trash") }
            }
            .labelStyle(.titleAndIcon)
            .padding(16)
            .background(.bar)
        }
        .navigationTitle(name)
        .onAppear { load(url); player.play() }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }

    private func load(_ url: URL, at time: CMTime = .zero) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if time != .zero { player.seek(to: time) }
    }

    private func commitName() {
        guard let new = model.rename(url, to: name) else {
            name = url.deletingPathExtension().lastPathComponent
            return
        }
        if new != url { load(new, at: player.currentTime()) }
        url = new
        name = new.deletingPathExtension().lastPathComponent
    }

    /// Uses AVPlayerView's built-in trim bar, then saves a lossless trimmed copy.
    private func trim() {
        guard let view = ref.view, view.canBeginTrimming else { return }
        trimming = true
        view.beginTrimming { result in
            guard result == .okButton, let item = player.currentItem else { trimming = false; return }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            Task { @MainActor in
                defer { trimming = false }
                do {
                    let out = try await Library.trim(url, from: start, to: end)
                    model.reload()
                    url = out
                    name = out.deletingPathExtension().lastPathComponent
                    load(out)
                } catch {
                    model.error = error.localizedDescription
                }
            }
        }
    }
}
