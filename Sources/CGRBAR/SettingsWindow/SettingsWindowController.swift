import AppKit
import SwiftUI

/// Connects the menu bar preview in the settings window to the controller.
/// Updates go straight to the view, bypassing SwiftUI, so a tick never
/// re-lays out the settings form.
@MainActor
final class MeterPreviewModel {
    weak var view: MeterView?

    func update(_ segments: [MeterSegment], layout: MeterLayout) {
        view?.update(segments, layout: layout)
    }
}

/// Shows the settings window. The window and its SwiftUI tree only exist
/// while it is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: Settings
    private let preview: MeterPreviewModel
    private var window: NSWindow?
    /// Fills the preview as soon as it exists, without waiting for a tick.
    var onPreviewAppear: () -> Void = {}

    init(settings: Settings, preview: MeterPreviewModel) {
        self.settings = settings
        self.preview = preview
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, preview: preview, onPreviewAppear: onPreviewAppear))
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
    let model: MeterPreviewModel
    let onAppear: () -> Void

    func makeNSView(context: Context) -> MeterView {
        let view = MeterView()
        model.view = view
        DispatchQueue.main.async(execute: onAppear)
        return view
    }

    func updateNSView(_ view: MeterView, context: Context) {}
}
