import AppKit
import HasteKit
import Observation
import SwiftUI

/// A complete, app-side snapshot of the mouse configuration (NGenuity "profile").
struct MouseProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var dpi: DPISettings
    var polling: PollingRate
    var lighting: LightingConfig
    var buttons: [UInt8: ButtonAction]
    /// Bundle identifiers that activate this profile when frontmost.
    var linkedApps: [String] = []
}

@MainActor
@Observable
final class ProfileManager {
    private(set) var profiles: [MouseProfile] = []
    var autoSwitch: Bool { didSet { UserDefaults.standard.set(autoSwitch, forKey: "profiles.autoSwitch") } }
    /// Profile applied when no linked app is frontmost (nil = leave as is).
    var defaultProfileID: UUID? { didSet { UserDefaults.standard.set(defaultProfileID?.uuidString, forKey: "profiles.default") } }
    private(set) var activeProfileID: UUID?

    private let store: MouseStore
    private var observer: NSObjectProtocol?

    init(store: MouseStore) {
        self.store = store
        autoSwitch = UserDefaults.standard.bool(forKey: "profiles.autoSwitch")
        defaultProfileID = UserDefaults.standard.string(forKey: "profiles.default").flatMap(UUID.init)
        if let data = UserDefaults.standard.data(forKey: "profiles.v1"),
           let p = try? JSONDecoder().decode([MouseProfile].self, from: data) { profiles = p }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontmostChanged(bundle) }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "profiles.v1") }
    }

    func captureCurrent(named name: String) {
        guard let dpi = store.dpi else { return }
        let p = MouseProfile(name: name, dpi: dpi, polling: store.polling ?? .hz1000, lighting: store.lighting,
                             buttons: Dictionary(uniqueKeysWithValues: store.buttons.map { ($0.key.rawValue, $0.value) }))
        profiles.append(p)
        activeProfileID = p.id
        persist()
    }

    func update(_ p: MouseProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
        persist()
    }

    func overwriteWithCurrent(_ p: MouseProfile) {
        guard let dpi = store.dpi else { return }
        var q = p
        q.dpi = dpi
        q.polling = store.polling ?? q.polling
        q.lighting = store.lighting
        q.buttons = Dictionary(uniqueKeysWithValues: store.buttons.map { ($0.key.rawValue, $0.value) })
        update(q)
    }

    func delete(_ p: MouseProfile) {
        profiles.removeAll { $0.id == p.id }
        if defaultProfileID == p.id { defaultProfileID = nil }
        persist()
    }

    func apply(_ p: MouseProfile, persistToFlash: Bool = true) {
        activeProfileID = p.id
        let buttons = Dictionary(uniqueKeysWithValues: p.buttons.compactMap { k, v in
            PhysicalButton(rawValue: k).map { ($0, v) }
        })
        store.applyProfile(dpi: p.dpi, polling: p.polling, lighting: p.lighting, buttons: buttons,
                           saveToFlash: persistToFlash)
    }

    private func frontmostChanged(_ bundleID: String?) {
        guard autoSwitch, let bundleID else { return }
        if let p = profiles.first(where: { $0.linkedApps.contains(bundleID) }) {
            if p.id != activeProfileID { apply(p, persistToFlash: false) }
        } else if let d = profiles.first(where: { $0.id == defaultProfileID }), d.id != activeProfileID {
            apply(d, persistToFlash: false)
        }
    }
}

// MARK: - UI

struct ProfilesPage: View {
    @Environment(MouseStore.self) private var store
    @Environment(ProfileManager.self) private var profiles
    @ViewState private var newName = ""

    var body: some View {
        @Bindable var profiles = profiles
        VStack(alignment: .leading) {
            PageSection(title: "Profiles",
                    subtitle: "Save complete setups (DPI, polling, lighting, buttons) and switch between them here or from the menu bar. The mouse itself stores one active setup.") {
                HStack {
                    TextField("New profile name", text: $newName).frame(width: 240)
                    Button("Save current settings") {
                        profiles.captureCurrent(named: newName.isEmpty ? "Profile \(profiles.profiles.count + 1)" : newName)
                        newName = ""
                    }
                    .disabled(store.dpi == nil)
                }
                if profiles.profiles.isEmpty {
                    Text("No profiles yet.").foregroundStyle(.secondary)
                }
                ForEach(profiles.profiles) { p in
                    ProfileRow(profile: p)
                }
            }
            PageSection(title: "Automatic switching",
                    subtitle: "Switch profile when a linked app comes to the front (like NGenuity's game profiles). Automatic switches are applied without rewriting the mouse's flash memory.") {
                Toggle("Switch profiles automatically", isOn: $profiles.autoSwitch)
                Picker("When no linked app is active", selection: $profiles.defaultProfileID) {
                    Text("Keep current settings").tag(UUID?.none)
                    ForEach(profiles.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .frame(maxWidth: 420)
                .disabled(!profiles.autoSwitch)
            }
        }
    }
}

struct ProfileRow: View {
    @Environment(ProfileManager.self) private var profiles
    @Environment(MouseStore.self) private var store
    let profile: MouseProfile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: profiles.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profiles.activeProfileID == profile.id ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if !profile.linkedApps.isEmpty {
                    HStack {
                        ForEach(profile.linkedApps, id: \.self) { id in
                            HStack(spacing: 3) {
                                Text(appName(id)).font(.caption)
                                Button { var p = profile; p.linkedApps.removeAll { $0 == id }; profiles.update(p) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.borderless).font(.caption)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Spacer()
            Menu("Link app") {
                ForEach(runningApps, id: \.bundleIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                        guard let id = app.bundleIdentifier, !profile.linkedApps.contains(id) else { return }
                        var p = profile; p.linkedApps.append(id); profiles.update(p)
                    }
                }
            }
            .frame(width: 100)
            Button("Apply") { profiles.apply(profile) }.disabled(store.connection != .ready)
            Menu {
                Button("Update from current settings") { profiles.overwriteWithCurrent(profile) }
                Button("Delete", role: .destructive) { profiles.delete(profile) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 34)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        let dpis = profile.dpi.profiles.filter(\.enabled).map { "\($0.dpi)" }.joined(separator: "/")
        return "DPI \(dpis) · \(profile.polling.label) · \(profile.lighting.effect.label)"
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}

/// Compact profile switcher for the popover.
struct ProfileQuickPicker: View {
    @Environment(ProfileManager.self) private var profiles
    var body: some View {
        if !profiles.profiles.isEmpty {
            HStack {
                Text("Profile").font(.subheadline.weight(.semibold))
                Spacer()
                Menu(profiles.profiles.first { $0.id == profiles.activeProfileID }?.name ?? "Choose…") {
                    ForEach(profiles.profiles) { p in Button(p.name) { profiles.apply(p) } }
                }
                .frame(width: 160)
            }
        }
    }
}
