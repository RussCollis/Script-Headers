import SwiftUI
import AppKit

/// Application entry point. Owns the scripts open in the window.
@main
struct InfoHeadersApp: App {
    @State private var library = HeaderLibrary()

    var body: some Scene {
        Window("Script Scribe", id: "main") {
            ContentView(library: library)
                .frame(minWidth: 1050, minHeight: 680)
        }
        .defaultSize(width: 1250, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Script Scribe") {
                    AboutPanel.show()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { library.isImporting = true }
                    .keyboardShortcut("o")
                Button("Load from Jamf Pro…") { library.isBrowsingJamf = true }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("New from Clipboard") { library.newFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}

/// The app's own disclaimer, shown in About and before anything is pushed to Jamf Pro.
enum AppDisclaimer {
    static let text = "Script Scribe is provided as is, without warranty of any kind. It only changes the comment "
        + "header, but always review the result and test scripts before deploying them. You're responsible "
        + "for anything pushed to Jamf Pro."
}

/// Shows the standard About window with engineer and licence credits.
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let secondary = body.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }
        let bold = body.merging([.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]) { $1 }

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Adds a standard header to Jamf Pro scripts and extension attributes.\n\n", attributes: secondary))
        credits.append(NSAttributedString(string: "Engineer\n", attributes: bold))
        credits.append(NSAttributedString(string: "Russell Collis\n\n", attributes: body))
        credits.append(NSAttributedString(string: "Licence\n", attributes: bold))
        credits.append(NSAttributedString(string: "MIT License\n\n", attributes: body))
        credits.append(NSAttributedString(string: "Disclaimer\n", attributes: bold))
        credits.append(NSAttributedString(string: AppDisclaimer.text, attributes: secondary))

        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}
