import AppKit
import HasteKit
import SwiftUI

struct MacrosPage: View {
    @Environment(MouseStore.self) private var store
    @ViewState private var button: PhysicalButton = .forward
    @ViewState private var draft = Macro()
    @ViewState private var selection = Set<Int>()
    @ViewState private var recorder = MacroRecorder()
    @ViewState private var newDelay = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Macros are stored on the mouse and played back by its firmware, so they work in every app — even without this one running. A macro can hold up to \(MacroEncoder.maxEvents) events.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("Button", selection: $button) {
                    ForEach(PhysicalButton.allCases) { b in
                        Text(b.label + (store.macros[b] != nil ? " •" : "")).tag(b)
                    }
                }
                .frame(width: 300)
                Spacer()
                if store.buttons[button] == .macro {
                    Label("Assigned", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                }
            }
            if button == .left {
                Label("Assigning a macro to the left button removes normal left-click.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                TextField("Name", text: $draft.name).frame(width: 220)
                Picker("Playback", selection: $draft.repeatMode) {
                    ForEach(MacroRepeatMode.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 300)
            }

            stepList

            addBar

            HStack {
                let count = MacroEncoder.compile(draft).count
                Text("\(count) / \(MacroEncoder.maxEvents) events")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(count > MacroEncoder.maxEvents ? .red : .secondary)
                Stepper("Gap between events: \(draft.defaultDelay) ms", value: $draft.defaultDelay, in: 0...1000, step: 5)
                    .font(.caption)
                Spacer()
                if store.macros[button] != nil {
                    Button("Delete", role: .destructive) {
                        store.macros[button] = nil
                        store.setButton(button, button.defaultAction)
                        draft = Macro()
                    }
                }
                Button("Save to mouse") { store.uploadMacro(draft, to: button) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.steps.isEmpty || count > MacroEncoder.maxEvents || store.connection != .ready)
            }
        }
        .onAppear(perform: load)
        .onChange(of: button) { _, _ in recorder.stop(); load() }
        .onDisappear { recorder.stop() }
    }

    private func load() {
        draft = store.macros[button] ?? Macro(name: "\(button.label) macro")
        selection = []
    }

    private var stepList: some View {
        List(selection: $selection) {
            ForEach(Array(draft.steps.enumerated()), id: \.offset) { i, step in
                HStack {
                    Image(systemName: icon(step)).frame(width: 18).foregroundStyle(.secondary)
                    if case .delay(let ms) = step {
                        Text("Wait")
                        TextField("ms", value: Binding(get: { ms }, set: { draft.steps[i] = .delay(max(0, min(65_535, $0))) }),
                                  format: .number.grouping(.never))
                            .frame(width: 70)
                        Text("ms")
                    } else {
                        Text(step.label)
                    }
                    Spacer()
                }
                .tag(i)
            }
            .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { draft.steps.remove(atOffsets: $0) }
        }
        .frame(minHeight: 200)
        .overlay {
            if draft.steps.isEmpty {
                Text(recorder.isRecording ? "Recording — type on the keyboard…" : "No steps yet. Press Record or add steps below.")
                    .foregroundStyle(.secondary)
            }
        }
        .onDeleteCommand { draft.steps.remove(atOffsets: IndexSet(selection)); selection = [] }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Button {
                if recorder.isRecording { recorder.stop() } else {
                    recorder.start { step in draft.steps.append(step) }
                }
            } label: {
                Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(recorder.isRecording ? .red : nil)
            .help("Records key presses with their real timing while this window is focused")

            Menu("Add key") {
                ForEach(HIDKeyboard.allKeys, id: \.usage) { k in
                    Button(k.name) { draft.steps += [.keyDown(k.usage), .keyUp(k.usage)] }
                }
            }.frame(width: 110)

            Menu("Add mouse") {
                ForEach(MacroMouseButton.allCases) { b in
                    Button("\(b.label) click") { draft.steps += [.mouseDown(b), .mouseUp(b)] }
                }
                Divider()
                Button("Scroll up") { draft.steps.append(.scroll(1)) }
                Button("Scroll down") { draft.steps.append(.scroll(-1)) }
            }.frame(width: 120)

            Button("Add delay") { draft.steps.append(.delay(newDelay)) }
            Spacer()
            Button("Clear") { draft.steps.removeAll() }.disabled(draft.steps.isEmpty)
        }
    }

    private func icon(_ s: MacroStep) -> String {
        switch s {
        case .keyDown: "arrow.down.to.line"
        case .keyUp: "arrow.up.to.line"
        case .mouseDown, .mouseUp: "computermouse"
        case .scroll: "arrow.up.arrow.down"
        case .delay: "clock"
        }
    }
}

/// Captures keyboard events in this app's windows and turns them into steps,
/// inserting the measured time between events as delay steps.
@Observable
final class MacroRecorder {
    private(set) var isRecording = false
    private var monitor: Any?
    private var last: Date?
    private var flags: NSEvent.ModifierFlags = []

    func start(_ emit: @escaping (MacroStep) -> Void) {
        stop()
        isRecording = true
        last = nil
        flags = NSEvent.modifierFlags
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, let usage = HIDKeyboard.fromMacKeyCode[e.keyCode] else { return e }
            if e.type == .keyDown && e.isARepeat { return nil }
            let now = Date()
            if let last { emit(.delay(min(65_535, Int(now.timeIntervalSince(last) * 1000)))) }
            self.last = now
            switch e.type {
            case .keyDown: emit(.keyDown(usage))
            case .keyUp: emit(.keyUp(usage))
            case .flagsChanged:
                // A modifier went down if its flag is now set and wasn't before.
                let newFlags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                emit(newFlags.rawValue > self.flags.rawValue ? .keyDown(usage) : .keyUp(usage))
                self.flags = newFlags
            default: break
            }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        isRecording = false
    }
}
