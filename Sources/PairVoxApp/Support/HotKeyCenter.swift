// SPDX-License-Identifier: Apache-2.0

import Carbon.HIToolbox
import Foundation

/// Global hotkeys (work while another app is in front) via Carbon's RegisterEventHotKey,
/// which needs no Accessibility permission. Each key has a numeric id; press and release are
/// reported separately so hold-to-talk works.
final class HotKeyCenter {
    var onPress: ((UInt32) -> Void)?
    var onRelease: ((UInt32) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    deinit { unregisterAll() }

    /// Registers keyCode + Carbon modifiers (e.g. kVK_Space, controlKey | optionKey) under `id`.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        installHandlerIfNeeded()
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5056_4F58), id: id) // 'PVOX'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) { center.onPress?(hotKeyID.id) }
                if kind == UInt32(kEventHotKeyReleased) { center.onRelease?(hotKeyID.id) }
            }
            return noErr
        }, 2, &types, selfPtr, &handlerRef)
    }
}
