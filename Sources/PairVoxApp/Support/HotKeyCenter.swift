// SPDX-License-Identifier: Apache-2.0

import Carbon.HIToolbox
import Foundation

/// A global hold-to-talk hotkey (default ⌃⌥Space) via Carbon's
/// RegisterEventHotKey, which needs no Accessibility permission.
final class HotKeyCenter {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    deinit { unregister() }

    /// Registers keyCode + Carbon modifiers (e.g. kVK_Space, controlKey | optionKey).
    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        unregister()
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) { center.onPress?() }
                if kind == UInt32(kEventHotKeyReleased) { center.onRelease?() }
            }
            return noErr
        }, 2, &types, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5056_4F58), id: 1) // 'PVOX'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
