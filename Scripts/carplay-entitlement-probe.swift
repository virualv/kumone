// carplay-entitlement-probe.swift — assert an app carries an entitlement the way
// TrollStore will actually read it on install.
//
// Why this exists: TrollStore's installer (RootHelper/main.m) reads the app's
// existing entitlements with
//
//     SecCodeCopySigningInformation(codeRef, kSecCSRequirementInformation, &info)
//     info[kSecCodeInfoEntitlementsDict]
//
// and then re-signs the bundle with whatever it read (falling back to
// application-identifier/get-task-allow/keychain-access-groups when it reads
// nothing). `ldid -S<plist>` — the obvious tool for this — writes an entitlements
// blob that Security.framework rejects:
//
//     $ codesign -d --entitlements :- App.app/App
//     warning: binary contains an invalid entitlements blob.
//              The OS will ignore these entitlements.
//
// so TrollStore reads nil, re-signs with its fallback set, and the restricted
// entitlement is silently dropped — the app then never shows up in CarPlay even
// though `ldid -e` happily prints the entitlement back (it parses the blob
// directly; it does not ask Security.framework). Baking with
// `codesign --force --sign - --entitlements <plist> <app>` produces a blob this
// probe accepts.
//
// Usage: swift Scripts/carplay-entitlement-probe.swift <App.app | Mach-O | .ipa> [entitlement]
// Exits non-zero when the entitlement is not readable, so it is safe to gate CI on.

import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: carplay-entitlement-probe.swift <App.app | Mach-O | .ipa> [entitlement]")
    exit(2)
}

let entitlement = arguments.count >= 3 ? arguments[2] : "com.apple.developer.carplay-audio"
var target = arguments[1]
var scratchDirectory: String?

/// Run a tool and return its raw stdout, or nil when it fails.
func run(_ launchPath: String, _ args: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return data
}

// Accept an .ipa by pulling out its app's main executable, so a downloaded
// release can be checked before it is installed.
if target.hasSuffix(".ipa") {
    guard
        let listingData = run("/usr/bin/unzip", ["-Z1", target]),
        let bundleEntry = String(decoding: listingData, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("Payload/") && $0.hasSuffix(".app/") })
    else {
        print("FAIL: no Payload/*.app in \(target)")
        exit(2)
    }
    // The bundled Info.plist is usually a binary plist, so keep the bytes intact.
    guard
        let plistData = run("/usr/bin/unzip", ["-p", target, bundleEntry + "Info.plist"]),
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
        let plistDictionary = plist as? [String: Any],
        let executable = plistDictionary["CFBundleExecutable"] as? String
    else {
        print("FAIL: cannot read \(bundleEntry)Info.plist from \(target)")
        exit(2)
    }
    let scratch = NSTemporaryDirectory() + "carplay-probe-" + UUID().uuidString
    guard run("/usr/bin/unzip", ["-o", "-j", target, bundleEntry + executable, "-d", scratch]) != nil else {
        print("FAIL: cannot extract \(bundleEntry + executable) from \(target)")
        exit(2)
    }
    scratchDirectory = scratch
    target = scratch + "/" + executable
}

defer {
    if let scratchDirectory {
        try? FileManager.default.removeItem(atPath: scratchDirectory)
    }
}

// Accept an .app bundle and resolve its executable, so the same probe works on a
// build product and on a bundle extracted from an IPA.
var isDirectory: ObjCBool = false
if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue {
    let plistPath = (target as NSString).appendingPathComponent("Info.plist")
    guard
        let plist = NSDictionary(contentsOfFile: plistPath),
        let executable = plist["CFBundleExecutable"] as? String
    else {
        print("FAIL: no CFBundleExecutable in \(plistPath)")
        exit(2)
    }
    target = (target as NSString).appendingPathComponent(executable)
}

var codeRef: SecStaticCode?
let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: target) as CFURL, [], &codeRef)
guard created == errSecSuccess, let codeRef else {
    print("FAIL: SecStaticCodeCreateWithPath(\(target)) -> \(created)")
    exit(1)
}

var info: CFDictionary?
let status = SecCodeCopySigningInformation(
    codeRef,
    SecCSFlags(rawValue: kSecCSRequirementInformation),
    &info
)

guard
    status == errSecSuccess,
    let dictionary = info as? [String: Any],
    let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
else {
    print("FAIL: TrollStore would read no entitlements from \(target) (status \(status)).")
    print("      Bake them with codesign, not ldid.")
    exit(1)
}

guard let value = entitlements[entitlement] as? NSNumber, value.boolValue else {
    print("FAIL: \(entitlement) is not readable on \(target).")
    print("      entitlements seen: \(entitlements.keys.sorted())")
    exit(1)
}

print("OK: \(entitlement) is readable — TrollStore will preserve it on install.")
for key in entitlements.keys.sorted() {
    print("    \(key) = \(entitlements[key] ?? "")")
}
