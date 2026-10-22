import AppKit
import SwiftUI

// Exercises the production NSViewRepresentable and its native action, using
// fictional model names only. No window is shown and no client is connected.
private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main struct ModelSwitchUIChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try rejectedSelectionKeepsOriginal()
            try acceptedSelectionTracksState()
            try refreshRepairsNativeSelection()
            print("PASS: 3 native model-menu regression checks")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func popup(in view: NSView) -> SelectedTitlePopup? {
        if let result = view as? SelectedTitlePopup { return result }
        for child in view.subviews {
            if let result = popup(in: child) { return result }
        }
        return nil
    }

    @MainActor private static func rendered(_ host: NSHostingView<NativePopup>) throws -> SelectedTitlePopup {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if let result = popup(in: host) { return result }
        } while Date() < deadline
        throw CheckFailure(message: "SwiftUI did not create its native model menu")
    }

    private static let options = [PopupOption(id: "codex:shared", title: "Codex Model"),
                                  PopupOption(id: "claude:shared", title: "Opus")]

    @MainActor private static func control(selection: String, onSelect: @escaping (String) -> Void) -> NativePopup {
        NativePopup(options: options, selection: selection, accessibilityLabel: "Model", onSelect: onSelect)
    }

    @MainActor private static func click(_ id: String, in popup: SelectedTitlePopup) throws {
        guard let item = popup.itemArray.first(where: { $0.representedObject as? String == id }),
              let coordinator = popup.target as? NativePopup.Coordinator else {
            throw CheckFailure(message: "Missing native model item or production coordinator")
        }
        // AppKit changes its selected item before invoking the target action.
        popup.select(item)
        coordinator.changed(popup)
    }

    @MainActor private static func rejectedSelectionKeepsOriginal() throws {
        for source in options {
            let target = options.first { $0.id != source.id }!
            var requested: [String] = []
            weak var displayedPopup: SelectedTitlePopup?
            var selectedDuringCallback: String?
            let host = NSHostingView(rootView: control(selection: source.id) {
                requested.append($0)
                selectedDuringCallback = displayedPopup?.selectedItem?.representedObject as? String
            })
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
            let native = try rendered(host)
            displayedPopup = native
            try click(target.id, in: native)
            // Both a cancelled confirmation and creating a separate note leave
            // the source's published selection unchanged, so no update is owed.
            try require(requested == [target.id], "The requested model was not forwarded exactly once")
            try require(selectedDuringCallback == source.id,
                        "The source displays the target model while its confirmation is open")
            try require(native.selectedItem?.representedObject as? String == source.id,
                        "Unchanged source note displays the other backend's model")
            try require(native.titleOfSelectedItem == source.title, "Source menu displays the wrong model name")
            try click(target.id, in: native)
            try require(requested == [target.id, target.id], "Cancelling prevented choosing the same target again")
            try require(native.selectedItem?.representedObject as? String == source.id,
                        "Repeating the model choice changed the unchanged source display")
            withExtendedLifetime(host) {}
        }
    }

    @MainActor private static func acceptedSelectionTracksState() throws {
        var accepted = "codex:shared"
        let host = NSHostingView(rootView: control(selection: accepted) { accepted = $0 })
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        let native = try rendered(host)
        try click("claude:shared", in: native)
        try require(accepted == "claude:shared", "Accepted model was not stored")
        host.rootView = control(selection: accepted) { accepted = $0 }
        _ = try rendered(host)
        try require(native.selectedItem?.representedObject as? String == accepted,
                    "Accepted model is not displayed after SwiftUI updates")
        try require(native.titleOfSelectedItem == "Opus", "Menu exposed the qualified model ID")
        let shortWidth = native.intrinsicContentSize.width
        host.rootView = control(selection: "codex:shared") { accepted = $0 }
        _ = try rendered(host)
        try require(native.intrinsicContentSize.width > shortWidth,
                    "Menu width did not follow the authoritative model title")
    }

    @MainActor private static func refreshRepairsNativeSelection() throws {
        let source = "codex:shared"
        let host = NSHostingView(rootView: control(selection: source) { _ in })
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        let native = try rendered(host)
        native.selectItem(at: 1)
        // Force an unrelated SwiftUI update while both the options and cached
        // published selection retain exactly their previous values.
        var next = control(selection: source) { _ in }
        next.enabled = false
        host.rootView = next
        _ = try rendered(host)
        try require(!native.isEnabled, "The regression check did not trigger updateNSView")
        try require(native.selectedItem?.representedObject as? String == source,
                    "Cached menu state prevented reconciliation with the source model")
    }
}
