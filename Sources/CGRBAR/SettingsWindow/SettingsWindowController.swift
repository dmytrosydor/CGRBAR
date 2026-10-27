import AppKit
import Observation
import SwiftUI

/// Live data for the menu bar preview in the settings window.
@MainActor
@Observable
final class MeterPreviewModel {
    var segments: [MeterSegment] = []
    var layout = MeterLayout()
}

/// Shows the settings window. The window and its SwiftUI tree only exist
/// while it is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: Settings
    private let preview: MeterPreviewModel
    private var window: NSWindow?

    init(settings: Settings, preview: MeterPreviewModel) {
        self.settings = settings
        self.preview = preview
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, preview: preview))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "CGRBAR Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Hosts a `MeterView` in SwiftUI, so the preview uses the real renderer.
struct MeterPreview: NSViewRepresentable {
    let segments: [MeterSegment]
    let layout: MeterLayout

    func makeNSView(context: Context) -> MeterView {
        MeterView()
    }

    func updateNSView(_ view: MeterView, context: Context) {
        view.update(segments, layout: layout)
    }
}
