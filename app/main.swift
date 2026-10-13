// Lecture Notes: paste a YouTube link, get English study notes as a PDF.
// The heavy lifting is done by engine.py (yt-dlp -> mlx-whisper -> Muse Spark -> PDF);
// this app queues links, runs the engine one at a time, and shows progress.
import SwiftUI
import AppKit
import UserNotifications

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Lecture Notes")
let notesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/Lecture Notes")
let engineDir = supportDir.appendingPathComponent("engine")

struct Job: Codable, Identifiable {
    var id = UUID()
    var url: String
    var title: String?
    var stage = "waiting"
    var progress = 0.0
    var pdf: String?
    var error: String?
    var created = Date()

    var finished: Bool { stage == "done" || stage == "error" }

    var statusText: String {
        switch stage {
        case "waiting": return "Waiting…"
        case "preparing": return "Getting ready…"
        case "downloading": return "Downloading…"
        case "listening": return "Listening to the lecture…"
        case "writing": return "Writing notes…"
        case "saving": return "Making the PDF…"
        case "done": return "Ready"
        default: return "Something went wrong"
        }
    }

    // Rough share of total time each stage takes, so one bar moves steadily.
    var overall: Double {
        let spans: [String: (Double, Double)] = [
            "preparing": (0, 0.03), "downloading": (0.03, 0.12), "listening": (0.12, 0.72),
            "writing": (0.72, 0.97), "saving": (0.97, 1.0), "done": (1, 1),
        ]
        guard let (a, b) = spans[stage] else { return 0 }
        return a + (b - a) * progress
    }
}

// Splits the engine's stdout into lines. A pipe's readability handler is only ever
// called on one queue at a time, so the lock just keeps the compiler honest.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(Data(data[data.startIndex..<nl]))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var jobs: [Job] = []
    private var running: Process?
    private let file = supportDir.appendingPathComponent("jobs.json")

    init() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = saved.map { j in
                var j = j
                if !j.finished { j.stage = "error"; j.error = "This was interrupted. Click Try Again." }
                return j
            }
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: file) }
    }

    func add(_ url: String) {
        jobs.insert(Job(url: url), at: 0)
        save()
        runNext()
    }

    func retry(_ job: Job) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].stage = "waiting"; jobs[i].error = nil; jobs[i].progress = 0
        save()
        runNext()
    }

    func remove(_ job: Job) {
        guard job.finished || job.stage == "waiting" else { return }
        jobs.removeAll { $0.id == job.id }
        save()
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    func runNext() {
        guard running == nil, let job = jobs.last(where: { $0.stage == "waiting" }) else { return }
        let p = Process()
        // caffeinate keeps the Mac awake for as long as the engine runs.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", engineDir.appendingPathComponent(".venv/bin/python").path,
                       engineDir.appendingPathComponent("engine.py").path, job.url]
        var env = ProcessInfo.processInfo.environment
        env["DYLD_FALLBACK_LIBRARY_PATH"] = "/opt/homebrew/lib"
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        let id = job.id
        let lines = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { h in
            for line in lines.feed(h.availableData) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                nonisolated(unsafe) let msg = obj
                Task { @MainActor in self.handle(id, msg) }
            }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                self.update(id) { j in
                    if !j.finished {
                        j.stage = "error"
                        j.error = j.error ?? "The notes maker stopped unexpectedly (code \(proc.terminationStatus))."
                    }
                }
                self.running = nil
                self.save()
                self.runNext()
            }
        }
        update(id) { $0.stage = "preparing"; $0.progress = 0 }
        do {
            try p.run()
            running = p
        } catch {
            update(id) { $0.stage = "error"; $0.error = "Couldn't start the notes maker: \(error.localizedDescription)" }
            save()
        }
    }

    private func handle(_ id: UUID, _ msg: [String: Any]) {
        guard let stage = msg["stage"] as? String else { return }
        update(id) { j in
            if let t = msg["title"] as? String { j.title = t }
            if stage == "error" {
                j.stage = "error"
                j.error = msg["message"] as? String ?? "Unknown error"
            } else {
                j.stage = stage
                j.progress = msg["progress"] as? Double ?? j.progress
            }
            if let pdf = msg["pdf"] as? String { j.pdf = pdf }
        }
        if stage == "done" || stage == "error" || stage == "listening" && (msg["progress"] as? Double) == 0 {
            save()
        }
        if stage == "done", let job = jobs.first(where: { $0.id == id }) {
            notify("Your notes are ready", job.title ?? "Lecture notes")
            if let pdf = job.pdf { NSWorkspace.shared.open(URL(fileURLWithPath: pdf)) }
        } else if stage == "error" {
            notify("Couldn't make notes", jobs.first(where: { $0.id == id })?.title ?? "Open Lecture Notes to see why.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        NSApp.requestUserAttention(.informationalRequest)
    }
}

func youtubeLink(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count < 500, let u = URL(string: t), let host = u.host?.lowercased() else { return nil }
    let ok = host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix(".youtu.be")
    return ok ? t : nil
}

func isPlaylistOnly(_ s: String) -> Bool {
    guard let c = URLComponents(string: s) else { return false }
    let items = c.queryItems ?? []
    return c.path.contains("playlist") && !items.contains { $0.name == "v" }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var link = ""
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "book.pages.fill").font(.system(size: 30)).foregroundStyle(Color(red: 0.04, green: 0.24, blue: 0.18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lecture Notes").font(.system(size: 24, weight: .semibold))
                    Text("Paste a YouTube link. English notes are saved as a PDF.").foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("https://www.youtube.com/watch?v=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .onSubmit(submit)
                Button(action: submit) {
                    Text("Make Notes").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.04, green: 0.24, blue: 0.18))
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            if let w = warning {
                Text(w).foregroundStyle(.red)
            }

            if store.jobs.isEmpty {
                Spacer()
                Text("Your lectures will appear here.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(store.jobs) { job in JobRow(job: job) }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("Open Notes Folder") {
                    try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(notesDir)
                }
                Spacer()
                Text("Takes about 5–10 minutes per hour of video. You can close this window.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .onAppear(perform: prefill)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in prefill() }
    }

    func prefill() {
        guard link.isEmpty, let s = NSPasteboard.general.string(forType: .string), let url = youtubeLink(s),
              !store.jobs.contains(where: { $0.url == url }) else { return }
        link = url
    }

    func submit() {
        guard let url = youtubeLink(link) else {
            warning = "That doesn't look like a YouTube link. Copy the address of the video and paste it here."
            return
        }
        if isPlaylistOnly(url) {
            warning = "That's a link to a whole playlist. Open one video, copy its link, and paste that here."
            return
        }
        warning = nil
        store.add(url)
        link = ""
    }
}

struct JobRow: View {
    @EnvironmentObject var store: Store
    let job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: job.stage == "done" ? "checkmark.circle.fill" : job.stage == "error" ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(job.stage == "done" ? .green : job.stage == "error" ? .orange : .secondary)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title ?? job.url).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !job.finished && job.stage != "waiting" {
                    ProgressView(value: job.overall)
                }
                Text(job.stage == "error" ? (job.error?.components(separatedBy: "\n\n").first ?? job.statusText) : job.statusText)
                    .font(.callout).foregroundStyle(job.stage == "error" ? .orange : .secondary).lineLimit(2)
            }
            Spacer()
            if job.stage == "done", let pdf = job.pdf {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: pdf)) }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pdf)]) } label: {
                    Image(systemName: "folder")
                }.help("Show in Finder")
            }
            if job.stage == "error" {
                Button("Try Again") { store.retry(job) }
            }
            if job.finished || job.stage == "waiting" {
                Button { store.remove(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove from list (the PDF is kept)")
            }
        }
        .padding(.vertical, 6)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    // Keep running (and working) after the window is closed; clicking the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

@main
struct LectureNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Lecture Notes", id: "main") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 680, height: 520)
    }
}
