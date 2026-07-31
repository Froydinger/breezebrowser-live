// Breeze Native — macOS 27 Apple Intelligence writing-affordance crash workaround.

import Cocoa
import ObjectiveC

/// macOS 27 shows an Apple Intelligence writing affordance ("Campo" is Apple's
/// internal name for it) whenever the pointer crosses an editable region. AppKit
/// does this for every app that accepts text input — Breeze never opts in, and
/// it is unrelated to Nav or anything Breeze builds.
///
/// The affordance is drawn out-of-process and attached through `NSRemoteView`.
/// On the macOS 27 betas that ViewBridge handoff throws an uncaught
/// Objective-C exception while its host window is being ordered on screen:
///
///     -[NSCampoLightweightUIController mouseEnteredTrackingArea:]
///       -> setupHostWindow: -> _doOrderWindow:
///       -> -[NSRemoteView containingWindowWillOrderOnScreen:]   (throws)
///       -> __cxa_rethrow -> std::terminate -> abort
///
/// The exception unwinds through C++ frames into `std::terminate`, so there is
/// no catch point available to us — the process is already dead by the time any
/// Swift code could run. The only fix is to stop the presentation from starting.
///
/// **This is not gated by `writingToolsBehavior`.** That property belongs to the
/// separate `NSWritingTools*` subsystem. Setting it to `.none` on a
/// `WKWebViewConfiguration` was verified inert: a treated and an untreated
/// configuration both leave the resulting view's value at -1, so it changes
/// nothing AppKit reads. Breeze 5.5.2/5.5.3 shipped that non-fix. There is also
/// no public API or user-defaults key for Campo — it lives in private
/// `CampoUI*` frameworks.
///
/// So neutralize the two entry points that begin the presentation. With them
/// inert the affordance simply never appears, which is indistinguishable from
/// the pointer never entering the field. Nothing else in AppKit is touched.
///
/// Every lookup — class, selector, and full method signature — is verified
/// before patching, so if Apple renames, removes, re-signatures, or fixes any
/// of this, `install()` silently does nothing and Breeze behaves normally.
enum CampoCrashWorkaround {
    private static var installed = false

    /// Both targets are `-(void)method:(id)arg` → "v24@0:8@16". Verifying the
    /// encoding means a signature change on Apple's side makes us skip rather
    /// than install a block with a mismatched calling convention.
    private static let expectedEncoding = "v24@0:8@16"

    private static let targets = [
        // Installs the tracking areas that watch for the pointer entering an
        // editable region. No tracking areas → the flow never begins.
        "setupTrackingAreasForViewHelper:",
        // The entry point actually named in every crash report. Neutralized as
        // well, in case tracking areas were installed before we patched.
        "mouseEnteredTrackingArea:",
    ]

    /// Call once, as early as possible in launch — before any window exists and
    /// therefore before any tracking area can be installed.
    static func install() {
        guard !installed else { return }
        installed = true

        guard let cls = NSClassFromString("NSCampoLightweightUIController") else { return }

        let noop: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
        let noopIMP = imp_implementationWithBlock(noop)

        for name in targets {
            let sel = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, sel),
                  let encoding = method_getTypeEncoding(method),
                  String(cString: encoding) == expectedEncoding
            else { continue }
            method_setImplementation(method, noopIMP)
        }
    }
}
