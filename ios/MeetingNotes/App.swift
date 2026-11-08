import MeetingCore
import SwiftUI

@main
struct MeetingNotesApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MeetingListView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    // Pick up meeting folders added or changed in the Files app.
                    if phase == .active { model.reload(); model.appDidBecomeActive() }
                    if phase == .background { model.appDidEnterBackground() }
                }
        }
    }
}

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showSettings = false
    @State private var path: [String] = []
    /// The meetings waiting for the user to confirm deleting them (one from a swipe, several from Edit).
    @State private var pendingDelete: [Meeting] = []
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var deletedCount = 0
    @AppStorage(Keys.onboarded) private var onboarded = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List(selection: editMode.isEditing ? $selection : nil) {
                ForEach(model.filtered(query)) { m in
                    NavigationLink(value: m.id) { MeetingRow(meeting: m) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { pendingDelete = [m] } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .environment(\.editMode, $editMode)
            .deleteDialog(for: editMode.isEditing ? [] : pendingDelete, onCancel: { pendingDelete = [] }, onDelete: delete)
            .sensoryFeedback(.impact(weight: .light), trigger: deletedCount)
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Tap Record when your meeting starts. The transcript and notes are made on this iPhone, offline."))
                } else if model.filtered(query).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search meetings")
            .navigationTitle("Meetings")
            .navigationDestination(for: String.self) { id in MeetingDetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.meetings.isEmpty {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            selection = []
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .disabled(editMode.isEditing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if editMode.isEditing { editBar } else { recordBar }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environment(model) }
            .sheet(isPresented: Binding(get: { !onboarded && !Benchmark.enabled }, set: { if !$0 { onboarded = true } })) {
                WelcomeView { onboarded = true }
                    .environment(model)
                    .interactiveDismissDisabled()
            }
            .fullScreenCover(isPresented: Binding(get: { model.isRecording }, set: { _ in })) {
                RecordingView { id in path = [id] }.environment(model)
            }
            .alert("Meeting Notes", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                Button("OK") { model.alert = nil }
            } message: { Text(model.alert ?? "") }
        }
    }

    /// In Edit: delete the selected meetings.
    private var editBar: some View {
        HStack {
            Spacer()
            Button(selection.isEmpty ? "Delete" : "Delete (\(selection.count))", role: .destructive) {
                pendingDelete = model.meetings.filter { selection.contains($0.id) }
            }
            .disabled(selection.isEmpty)
            .deleteDialog(for: editMode.isEditing ? pendingDelete : [], onCancel: { pendingDelete = [] }, onDelete: delete)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func delete(_ meetings: [Meeting]) {
        pendingDelete = []
        withAnimation { model.delete(meetings) }
        selection = []
        if model.meetings.isEmpty { editMode = .inactive }
        deletedCount += 1
    }

    private var recordBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.startRecording(language: MeetingLanguage(rawValue: UserDefaults.standard.string(forKey: Keys.language) ?? "") ?? .automatic) }
            } label: {
                Label("Record", systemImage: "mic.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("record")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title).font(.headline)
            HStack(spacing: 6) {
                Text(meeting.created, format: .dateTime.day().month().hour().minute())
                if let d = meeting.meta.duration { Text("· \(formatLength(d))") }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let p = model.progress[meeting.id] {
                Label(p, systemImage: "hourglass").font(.caption).foregroundStyle(.blue)
            } else if meeting.status == "recording" {
                Label("Recording", systemImage: "record.circle").font(.caption).foregroundStyle(.red)
            } else if meeting.status == "failed" {
                Label("Needs attention", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecordingView: View {
    @Environment(AppModel.self) private var model
    /// Opens the meeting after stopping.
    var onStop: (String) -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            if let r = model.recorder {
                let _ = model.recorderState
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    VStack(spacing: 24) {
                        Text(formatDuration(ctx.date.timeIntervalSince(r.start)))
                            .font(.system(size: 72, weight: .light, design: .rounded))
                            .monospacedDigit()
                        LevelMeter(level: r.level())
                            .frame(height: 12)
                            .padding(.horizontal, 40)
                    }
                }
                if r.interrupted {
                    VStack(spacing: 12) {
                        Label("Paused by a call or another app", systemImage: "pause.circle")
                            .foregroundStyle(.orange)
                        Button("Resume recording") { model.resumeRecording() }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Label("Recording. You can lock the screen.", systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                let id = model.recorder?.folder.path
                model.stopRecording()
                if let id { onStop(id) }
            } label: {
                ZStack {
                    Circle().fill(.red).frame(width: 120, height: 120)
                    RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 40, height: 40)
                }
            }
            .accessibilityLabel("Stop recording")
            .accessibilityIdentifier("stop")
            Text("Stop").font(.headline)
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: max(8, g.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .accessibilityLabel("Input level")
    }
}


extension View {
    /// The confirmation before deleting meetings, as an action sheet like Apple's apps: "Delete "Title"?" for one
    /// meeting, "Delete 3 Meetings?" for several. Shown while `meetings` isn't empty.
    func deleteDialog(for meetings: [Meeting], onCancel: @escaping () -> Void, onDelete: @escaping ([Meeting]) -> Void) -> some View {
        let one = meetings.count == 1
        let title = one ? "Delete \u{201C}\(meetings[0].title)\u{201D}?" : "Delete \(meetings.count) Meetings?"
        return confirmationDialog(title, isPresented: Binding(get: { !meetings.isEmpty }, set: { if !$0 { onCancel() } }),
                                  titleVisibility: .visible) {
            Button(one ? "Delete Meeting" : "Delete \(meetings.count) Meetings", role: .destructive) { onDelete(meetings) }
            Button("Cancel", role: .cancel) { onCancel() }
        } message: {
            Text(one ? "The transcript and notes will be deleted. This can't be undone."
                     : "The transcripts and notes will be deleted. This can't be undone.")
        }
    }
}
