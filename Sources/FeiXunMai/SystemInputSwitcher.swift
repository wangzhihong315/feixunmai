import Foundation

/// Switches the macOS default input to the virtual microphone while one or
/// more voice sources are active, and restores the previous input when the
/// last owner ends.
///
/// This exists because the previous implementation only ever called the
/// "restore" path; `switchDefaultInput(toBlackHole: true)` was dead code, so
/// the voice input tool never actually received the FeiXunV/BlackHole stream.
final class SystemInputSwitcher {
    static let shared = SystemInputSwitcher()

    private let defaultsKey = "savedInputDeviceUID"
    private var owners: Set<InputOwner> = []
    private var savedUID: String?
    private var activeTargetUID: String?

    private init() {}

    func begin(owner: InputOwner, target: AudioDeviceInfo) {
        if owners.isEmpty {
            let current = defaultInputDevice()
            if current?.uid != target.uid {
                savedUID = current?.uid
                activeTargetUID = target.uid
                if let savedUID {
                    UserDefaults.standard.set(savedUID, forKey: defaultsKey)
                }
                let ok = setDefaultInputDevice(target)
                FileLog.write(
                    "input → \(target.name) (was \(current?.name ?? "?")) ok=\(ok ? 1 : 0)"
                )
                if Diag.on {
                    NSLog(
                        "VibeDeck[input] default input → %@ (was %@)",
                        target.name,
                        current?.name ?? "?"
                    )
                }
            }
        }
        owners.insert(owner)
    }

    func end(owner: InputOwner) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        restoreIfNeeded()
    }

    /// Restores the saved input. Safe to call at startup (crash recovery) and
    /// at shutdown. If the user manually changed the default input away from
    /// the virtual device while a session was active, their choice is kept.
    func restoreIfNeeded() {
        let saved = savedUID ?? UserDefaults.standard.string(forKey: defaultsKey)
        guard let saved else {
            owners.removeAll()
            return
        }
        let current = defaultInputDevice()
        if let target = activeTargetUID, current?.uid != target {
            // The user changed the input themselves; do not override it.
            clearSaved()
            return
        }
        if let restore = allDevices().first(where: { $0.uid == saved }) {
            let ok = setDefaultInputDevice(restore)
            FileLog.write("input restored → \(restore.name) ok=\(ok ? 1 : 0)")
            if Diag.on { NSLog("VibeDeck[input] restored → %@", restore.name) }
        }
        clearSaved()
    }

    private func clearSaved() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        savedUID = nil
        activeTargetUID = nil
        owners.removeAll()
    }
}
