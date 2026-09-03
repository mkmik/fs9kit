import SwiftUI
import AppKit
import FS9KitAdapter

/// The container app.
///
/// An FSKit module is an app extension, and an app extension needs a host
/// application that LaunchServices can see. That is this app's entire job. It
/// deliberately does no mounting itself: `mount -F` needs `sudo`, and asking a
/// GUI app for an admin password to shell out to `mount` is worse for the user
/// than showing them the one command to paste.
@main
struct FS9KitApp: App {
    var body: some Scene {
        Window("FS9Kit", id: "main") {
            ContentView()
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}

/// The extension's bundle identifier, which must match
/// `PRODUCT_BUNDLE_IDENTIFIER` for the FS9KitExtension target in `project.yml`.
let extensionBundleIdentifier = "com.fs9kit.FS9KitApp.FS9KitExtension"

// MARK: - Extension status

enum ExtensionStatus: Equatable {
    case unknown
    case notRegistered
    case registeredButDisabled
    case enabled
    case failed(String)

    var summary: String {
        switch self {
        case .unknown: "Checking…"
        case .notRegistered: "Not registered"
        case .registeredButDisabled: "Registered, but switched off"
        case .enabled: "Enabled"
        case let .failed(reason): "Could not tell (\(reason))"
        }
    }

    var colour: Color {
        switch self {
        case .enabled: .green
        case .registeredButDisabled, .notRegistered: .orange
        case .unknown: .secondary
        case .failed: .red
        }
    }

    var advice: String {
        switch self {
        case .enabled:
            "The extension is on. Mount with the command below."
        case .registeredButDisabled:
            """
            macOS knows about the extension but it is switched off. Turn it on in \
            System Settings → General → Login Items & Extensions → File System \
            Extensions, then come back and press Refresh.
            """
        case .notRegistered:
            """
            macOS has not seen the extension. It is registered when the app is \
            launched from a location LaunchServices scans — in practice, move \
            FS9Kit.app to /Applications and open it once. If it still does not \
            appear, see macos/README.md for the pluginkit commands.
            """
        case .unknown, .failed:
            "Press Refresh to check again; macos/README.md has the manual commands."
        }
    }
}

/// Asks `pluginkit` whether the extension is registered and enabled.
///
/// `pluginkit(8)` is unofficial but it is what every project in this space
/// uses, and it is the same tool the README tells the user to run. FSKit's own
/// `FSClient` can enumerate installed modules, but reading enablement through
/// it needs care that a status label does not justify.
///
/// `pluginkit -m -A -i <id>` prints one line per matching plug-in; the first
/// character is `+` for enabled, `-` for disabled, `?` for unknown.
@MainActor
func readExtensionStatus() -> ExtensionStatus {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    process.arguments = ["-m", "-A", "-i", extensionBundleIdentifier]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .notRegistered }
        if output.hasPrefix("+") { return .enabled }
        if output.hasPrefix("-") { return .registeredButDisabled }
        return .registeredButDisabled
    } catch {
        return .failed(error.localizedDescription)
    }
}

// MARK: - View

struct ContentView: View {
    @State private var status: ExtensionStatus = .unknown
    @State private var server = "127.0.0.1"
    @State private var port = "564"
    @State private var tree = ""
    @State private var mountPoint = "/Volumes/fs9kit"
    @State private var readOnly = false
    @State private var copied = false

    /// The command the user should paste. Built through the same parser the
    /// extension uses, so a URL this app shows is a URL the extension accepts.
    var mountURL: String {
        var url = "9p://\(server)"
        if let port = Int(port), port != 564 { url += ":\(port)" }
        url += "/" + tree.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return url
    }

    var mountCommand: String {
        let options = readOnly ? " -o ro" : ""
        return "sudo /sbin/mount -F -t fs9kit\(options) \(mountURL) \(mountPoint)"
    }

    var urlIsValid: Bool { (try? MountSpec.parse(mountURL)) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                statusSection
                Divider()
                mountSection
                Divider()
                helpSection
            }
            .padding(24)
        }
        .task { status = readExtensionStatus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FS9Kit").font(.largeTitle.bold())
            Text("Mounts a 9P server as a macOS volume, with no kernel extension.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status.colour).frame(width: 10, height: 10)
                Text(status.summary).font(.headline)
                Spacer()
                Button("Refresh") { status = readExtensionStatus() }
            }
            Text(status.advice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings → Login Items & Extensions") {
                // The pane that holds the File System Extensions list. There is
                // no public API to open the FSKit sheet directly before
                // macOS 27's FSClient.openFileSystemExtensionsSettings().
                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var mountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mount command").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Server"); TextField("host", text: $server)
                }
                GridRow {
                    Text("Port"); TextField("564", text: $port).frame(width: 100)
                }
                GridRow {
                    Text("Tree (aname)"); TextField("usually empty", text: $tree)
                }
                GridRow {
                    Text("Mount point"); TextField("/Volumes/fs9kit", text: $mountPoint)
                }
                GridRow {
                    Text(""); Toggle("Read-only", isOn: $readOnly)
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(mountCommand)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(copied ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mountCommand, forType: .string)
                    copied = true
                }
                .disabled(!urlIsValid)
                if !urlIsValid {
                    Text("That is not a URL the extension will accept.")
                        .font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("Unmount: sudo diskutil unmount \(mountPoint)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onChange(of: mountCommand) { copied = false }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to enable this").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("The switch is per-user and there is no system-wide or pre-login equivalent.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private let steps = [
        "Move FS9Kit.app to /Applications and open it once, so LaunchServices registers the extension.",
        "Open System Settings → General → Login Items & Extensions.",
        "Scroll to Extensions, find File System Extensions, and click the ⓘ.",
        "Switch fs9kit on.",
        "Paste the command above into Terminal. mount -F needs sudo.",
    ]
}
