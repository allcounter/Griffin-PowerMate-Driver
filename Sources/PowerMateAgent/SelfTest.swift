import Foundation
import AppKit
import ApplicationServices

// MARK: - Headless self-tests
//
// Three verbs that exercise the hold-key primitives without a PowerMate attached and without
// starting the agent proper. They run before the driver seizes the device or the status item
// is built, so they work while the normally-installed agent is quit but everything else about
// the machine (the stored settings blob, the Accessibility grant) is untouched.
//
//   PowerMateAgent --selftest-hold <seconds>   press the configured hold key, wait, release
//   PowerMateAgent --selftest-decode           decode the live settings blob and report holdKey
//   PowerMateAgent --selftest-overrides        resolve a per-app override against the default
//                                               and check that holdKey/pressTurnOncePerPress
//                                               are inherited
//
// All three print what they did and exit 0; anything else returns and startup continues as usual.

/// Runs a `--selftest-*` verb if one was passed and exits the process. Returns normally when
/// the agent was launched without one.
func runSelfTestIfRequested() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let verb = args.first else { return }
    switch verb {
    case "--selftest-hold":
        runHoldSelfTest(seconds: args.dropFirst().first.flatMap(Double.init) ?? 5)
    case "--selftest-decode":
        runDecodeSelfTest()
    case "--selftest-overrides":
        runOverridesSelfTest()
    default:
        return
    }
    exit(0)
}

private func runHoldSelfTest(seconds: Double) {
    // The global default, not currentSettings(): a self-test run from a terminal would
    // otherwise resolve against whatever app happens to be frontmost, which is not what the
    // operator configured and makes the measurement non-reproducible.
    guard let binding = defaultSettings.holdKey else {
        print("selftest-hold: no hold key configured (defaultAppSettings.holdKey is nil) — nothing to press.")
        exit(1)
    }
    let isModifier = modifierFlag(forKeyCode: binding.keyCode) != nil
    print("selftest-hold: AXIsProcessTrusted=\(AXIsProcessTrusted())")
    print("selftest-hold: key=\(binding.label) keyCode=0x\(String(binding.keyCode, radix: 16, uppercase: true)) "
          + "flags=0x\(String(binding.modifierFlags, radix: 16, uppercase: true)) "
          + "eventType=\(isModifier ? ".flagsChanged" : ".keyDown/.keyUp")")
    print("selftest-hold: DOWN at \(Date())")
    postKeyDown(binding.keyCode, flags: binding.flags)
    Thread.sleep(forTimeInterval: seconds)
    postKeyUp(binding.keyCode, flags: binding.flags)
    print("selftest-hold: UP at \(Date()) (held \(seconds)s)")
}

private func runDecodeSelfTest() {
    // Reads the same UserDefaults key AppOverrides.swift reads, and decodes it with the same
    // AppSettings.init(from:). The point is to prove that a blob written before holdKey existed
    // still decodes — as itself, not as a silently discarded default instance.
    guard let data = defaults.data(forKey: "defaultAppSettings") else {
        print("selftest-decode: no stored defaultAppSettings blob (fresh install) — nothing to check.")
        exit(1)
    }
    print("selftest-decode: stored blob = \(data.count) bytes")
    print("selftest-decode: contains \"holdKey\" key = \(String(data: data, encoding: .utf8)?.contains("holdKey") ?? false)")
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        print("selftest-decode: decoded OK")
        print("selftest-decode:   holdKey           = \(decoded.holdKey.map { "\($0.label) (0x\(String($0.keyCode, radix: 16, uppercase: true)))" } ?? "nil")")
        // Fields that prove the rest of the blob survived rather than falling back wholesale.
        print("selftest-decode:   mode              = \(decoded.mode.rawValue)")
        print("selftest-decode:   clickAction       = \(decoded.clickAction)")
        print("selftest-decode:   longPressAction   = \(decoded.longPressAction)")
        print("selftest-decode:   keypressBindings  = \(decoded.keypressBindings.count) directions")
    } catch {
        print("selftest-decode: FAILED — \(error)")
        exit(1)
    }
}

private func runOverridesSelfTest() {
    // Constructed entirely in memory — no `defaults` or `NSWorkspace` reads. That's the point
    // of extracting resolvedSettings(override:base:) as a pure function: this verb can prove
    // the inheritance rule from a bare `swift build` binary, where --selftest-decode and
    // --selftest-hold legitimately cannot (they depend on the installed app's UserDefaults
    // domain).
    var base = AppSettings()
    base.holdKey = KeyBinding(keyCode: 0x3F, label: "Fn")
    base.pressTurnOncePerPress = true
    base.mode = .scroll

    var override = AppSettings()
    override.mode = .keypress

    var anyFailed = false

    func check(_ name: String, _ actual: Bool, expected: String, actualDescription: String) {
        if actual {
            print("selftest-overrides: PASS \(name) — expected \(expected), got \(actualDescription)")
        } else {
            print("selftest-overrides: FAIL \(name) — expected \(expected), got \(actualDescription)")
            anyFailed = true
        }
    }

    // Test 1: a bare AppSettings() override resolved against a base with a hold key and
    // pressTurnOncePerPress == true comes back carrying BOTH of the base's values.
    let resolved1 = resolvedSettings(override: override, base: base)
    check("inherited holdKey", resolved1.holdKey == base.holdKey,
          expected: "\(String(describing: base.holdKey))", actualDescription: "\(String(describing: resolved1.holdKey))")
    check("inherited pressTurnOncePerPress", resolved1.pressTurnOncePerPress == base.pressTurnOncePerPress,
          expected: "\(base.pressTurnOncePerPress)", actualDescription: "\(resolved1.pressTurnOncePerPress)")

    // Test 2: a field the override genuinely owns (mode) is still respected — the base must
    // not clobber it.
    check("override-owned mode preserved", resolved1.mode == .keypress,
          expected: ".keypress", actualDescription: "\(resolved1.mode)")

    // Test 3: a nil override returns the base unchanged.
    let resolved2 = resolvedSettings(override: nil, base: base)
    check("nil override -> base.mode", resolved2.mode == base.mode,
          expected: "\(base.mode)", actualDescription: "\(resolved2.mode)")
    check("nil override -> base.holdKey", resolved2.holdKey == base.holdKey,
          expected: "\(String(describing: base.holdKey))", actualDescription: "\(String(describing: resolved2.holdKey))")
    check("nil override -> base.pressTurnOncePerPress", resolved2.pressTurnOncePerPress == base.pressTurnOncePerPress,
          expected: "\(base.pressTurnOncePerPress)", actualDescription: "\(resolved2.pressTurnOncePerPress)")

    if anyFailed {
        exit(1)
    }
}
