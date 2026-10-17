// SPDX-License-Identifier: Apache-2.0
//
// Reports which programs the login Keychain lets read PairVox's API-key item without asking, and (with --probe)
// proves it from a second process using a throwaway dummy item. Never reads or prints the real key.
//
//   scripts/check-keychain-access.sh [--json] [--probe]
import Foundation
import Security

let service = "app.pairvox.PairVox", account = "anthropic-api-key"
let args = CommandLine.arguments
let json = args.contains("--json"), probe = args.contains("--probe")

struct Report: Codable {
    var item: String
    var found: Bool
    var unrestricted: Bool?        // any program may read it without a prompt
    var trustedApplications: Int?  // programs trusted to read it without a prompt (nil if unrestricted or unknown)
    var promptsOthers: Bool?       // a program that is not trusted gets an approval prompt
    var probe: String?             // result of the cross-process read of the dummy item
    var verdict: String
}

func itemRef(service: String, account: String) -> SecKeychainItem? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account, kSecReturnRef as String: true]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let ref = out else { return nil }
    return (ref as! SecKeychainItem)
}

/// Looks at the item's access list. This does not read the secret and does not prompt.
func inspect(_ item: SecKeychainItem) -> (unrestricted: Bool, trusted: Int, prompts: Bool)? {
    var access: SecAccess?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return nil }
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return nil }
    var unrestricted = false, trusted = 0
    for acl in acls {
        let auths = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
        guard auths.contains("ACLAuthorizationDecrypt") || auths.contains("ACLAuthorizationAny") else { continue }
        var apps: CFArray?, description: CFString?, selector = SecKeychainPromptSelector()
        guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess else { continue }
        if let apps = apps as? [SecTrustedApplication] { trusted += apps.count } else { unrestricted = true }
        _ = selector
    }
    return (unrestricted, trusted, !unrestricted)
}

func verdict(_ unrestricted: Bool, _ trusted: Int) -> String {
    if unrestricted { return "UNSAFE: any program running as you can read this item without a prompt." }
    return "OK: only \(trusted) trusted program(s) can read it silently; any other program triggers a Keychain prompt."
}

func realItem() -> Report {
    guard let item = itemRef(service: service, account: account) else {
        return Report(item: "\(service) / \(account)", found: false, verdict: "No API key is saved, nothing to check.")
    }
    guard let r = inspect(item) else {
        return Report(item: "\(service) / \(account)", found: true, verdict: "Could not read the access list.")
    }
    return Report(item: "\(service) / \(account)", found: true, unrestricted: r.unrestricted,
                  trustedApplications: r.unrestricted ? nil : r.trusted, promptsOthers: r.prompts,
                  verdict: verdict(r.unrestricted, r.trusted))
}

/// Creates a dummy item exactly like KeychainStore does, then reads it from another process (`security`).
func probeDummy() -> String {
    let dummyService = "app.pairvox.keychain-check", dummyAccount = "probe-\(getpid())"
    let secret = "pairvox-dummy-secret"
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dummyService,
                              kSecAttrAccount as String: dummyAccount, kSecAttrLabel as String: "PairVox keychain check (temporary)",
                              kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked, kSecValueData as String: Data(secret.utf8)]
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return "could not create the dummy item" }
    defer {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dummyService,
                       kSecAttrAccount as String: dummyAccount] as CFDictionary)
    }
    var acl = "access list unreadable"
    if let ref = itemRef(service: dummyService, account: dummyAccount), let r = inspect(ref) {
        acl = r.unrestricted ? "access list: any program" : "access list: \(r.trusted) trusted program(s)"
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", dummyService, "-a", dummyAccount, "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return "could not start /usr/bin/security" }
    let deadline = Date().addingTimeInterval(10)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate(); return "BLOCKED: a second program was held at an approval prompt (timed out after 10 s); \(acl)" }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text == secret { return "UNSAFE: a second program read the item silently; \(acl)" }
    return "BLOCKED: a second program was refused (exit \(p.terminationStatus)); \(acl)"
}

var report = realItem()
if probe { report.probe = probeDummy() }
if json {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try! enc.encode(report), encoding: .utf8)!)
} else {
    print("Item:    \(report.item)")
    print("Present: \(report.found ? "yes" : "no")")
    if let u = report.unrestricted { print("Any program may read it silently: \(u ? "YES" : "no")") }
    if let t = report.trustedApplications { print("Trusted programs: \(t)") }
    if let pr = report.probe { print("Cross-process probe (dummy item): \(pr)") }
    print(report.verdict)
}
let bad = report.verdict.hasPrefix("UNSAFE") || (report.probe?.hasPrefix("UNSAFE") ?? false)
exit(bad ? 1 : 0)
