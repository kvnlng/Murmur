//
//  SessionPassphrasePrompt.swift
//  MurmurCore
//
//  The two places an analyst types a `.mur` passphrase (X63-D): an accessory
//  view on the save panel, and a prompt when opening a sealed package.
//
//  AppKit rather than SwiftUI because both hang off `NSSavePanel` /
//  `NSAlert`, which are system-modal and take AppKit views.
//
//  ## Rules this surface exists to keep
//
//  - The passphrase is never logged, never written to disk, never put in a URL
//    or an accessibility label. It exists as a `String` for as long as the
//    save or open takes.
//  - **No "remember this passphrase."** A Keychain-held copy would quietly
//    convert the portable model back into a device-bound one — the thing the
//    passphrase design exists to avoid. It is a reasonable later addition and
//    it is not this change.
//  - **No recovery.** Stated once, plainly, where the analyst decides — not
//    discovered afterwards.
//

import AppKit

public enum SessionPassphrasePrompt {

    /// Accessory view for the save panel: a checkbox that reveals a secure
    /// field. Encryption is OPTIONAL per save, so the default is off and the
    /// analyst opts in.
    public final class SaveAccessory: NSView {

        private let toggle = NSButton(checkboxWithTitle: "Encrypt with a passphrase", target: nil, action: nil)
        private let field = NSSecureTextField(frame: .zero)
        private let warning = NSTextField(labelWithString: "If you lose this passphrase the session cannot be opened. There is no recovery.")

        /// The passphrase to seal with, or nil when the analyst left it off.
        public var passphrase: String? {
            guard toggle.state == .on else { return nil }
            let value = field.stringValue
            return value.isEmpty ? nil : value
        }

        public init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 78))
            toggle.target = self
            toggle.action = #selector(toggleChanged)
            field.placeholderString = "Passphrase"
            field.isEnabled = false
            warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            warning.textColor = .secondaryLabelColor
            warning.isHidden = true
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 2

            for view in [toggle, field, warning] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                toggle.topAnchor.constraint(equalTo: topAnchor),
                toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                field.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 6),
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                warning.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
                warning.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                warning.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func toggleChanged() {
            let on = toggle.state == .on
            field.isEnabled = on
            warning.isHidden = !on
            if on { window?.makeFirstResponder(field) } else { field.stringValue = "" }
        }
    }

    /// Ask for the passphrase of a sealed package. Returns nil when the analyst
    /// cancels — which must read as "not now", never as a failed open.
    @MainActor
    public static func askToOpen(fileName: String, retryAfterFailure: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = retryAfterFailure
            ? "That passphrase didn't open \(fileName)."
            : "\(fileName) is encrypted."
        alert.informativeText = retryAfterFailure
            ? "Check for typos or a different keyboard layout, and try again."
            : "Enter the passphrase it was saved with."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }
}

/// Opening a `.mur` that may be sealed, including the retry loop.
///
/// Lives here rather than in `ContentView` for two reasons: it kept the view
/// over SwiftLint's 1000-line file cap, which Xcode Cloud fails the build on;
/// and with the prompt injected, the retry BEHAVIOUR is unit-testable without
/// a modal.
public enum SessionPackageOpener {

    /// What a prompt returns: a passphrase to try, or the analyst's cancel.
    public enum PromptResult: Equatable {
        case passphrase(String)
        case cancelled
    }

    /// Read a package, asking for a passphrase if it is sealed.
    ///
    /// A wrong passphrase RE-ASKS rather than dead-ending — mistyping is the
    /// overwhelmingly likely cause, and sending the analyst back through the
    /// Open panel would treat a typo like a damaged file. Cancelling returns
    /// nil: "not now" is not an error and must not surface as one.
    ///
    /// `prompt` receives whether the previous attempt failed, so the wording
    /// can differ between the first ask and a retry.
    public static func read(
        packageURL: URL,
        into workingDirectory: URL,
        prompt: (_ retryAfterFailure: Bool) -> PromptResult
    ) throws -> MurSessionPackage.ReadResult? {
        do {
            return try MurSessionPackage.read(packageURL: packageURL, into: workingDirectory)
        } catch MurSessionError.passphraseRequired {
            // fall through to the prompt
        }
        var retry = false
        while true {
            guard case .passphrase(let passphrase) = prompt(retry) else { return nil }
            do {
                return try MurSessionPackage.read(
                    packageURL: packageURL, into: workingDirectory, passphrase: passphrase
                )
            } catch MurSessionError.wrongPassphrase {
                retry = true
            }
        }
    }
}
