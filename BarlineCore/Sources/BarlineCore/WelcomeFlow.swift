//
//  WelcomeFlow.swift
//  Barline
//

/// The steps of Barline's first-run walkthrough, in order.
public enum WelcomeStep: String, CaseIterable, Sendable {
    case welcome
    case accessibility
    case screenRecording
    case barSetup
    case done
}

/// Decisions for the first-run walkthrough. The walkthrough explains
/// permissions and requests each one only when the user clicks to grant it.
/// Every step can be skipped, and nothing it shows blocks using the app.
public enum WelcomeFlow {
    /// Whether to present the walkthrough when Barline launches.
    ///
    /// - Parameters:
    ///   - isEligible: `false` for development and test builds, which must never
    ///     open a window on their own.
    ///   - isFreshInstall: This install has not yet finished the walkthrough
    ///     since Barline first found its preferences empty. The marker is written
    ///     before anything else touches preferences and survives the relaunch
    ///     after moving into Applications, which runs migrations first. Users
    ///     upgrading from an earlier version never have it, so they are not
    ///     shown the walkthrough.
    ///   - isCompleted: The user finished, skipped, or closed the walkthrough.
    ///   - savedStep: The step recorded when the walkthrough was last left open.
    public static func shouldPresentAtLaunch(
        isEligible: Bool,
        isFreshInstall: Bool,
        isCompleted: Bool,
        savedStep: WelcomeStep?
    ) -> Bool {
        guard isEligible, !isCompleted else {
            return false
        }
        // A walkthrough interrupted by a relaunch, such as macOS's Quit &
        // Reopen after a Screen Recording grant, resumes even though its first
        // launch already wrote preferences.
        if let savedStep, savedStep != .done {
            return true
        }
        return isFreshInstall
    }

    /// The step to show when the walkthrough opens.
    public static func openingStep(savedStep: WelcomeStep?) -> WelcomeStep {
        guard let savedStep, savedStep != .done else {
            return .welcome
        }
        return savedStep
    }

    public static func step(after step: WelcomeStep) -> WelcomeStep {
        let steps = WelcomeStep.allCases
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            return .done
        }
        return steps[index + 1]
    }

    public static func step(before step: WelcomeStep) -> WelcomeStep? {
        let steps = WelcomeStep.allCases
        guard let index = steps.firstIndex(of: step), index > 0, step != .done else {
            return nil
        }
        return steps[index - 1]
    }

    /// What the bar setup step must tell the user before they open the layout
    /// editor. Mirrors the layout editor's own checks, in the same order, so the
    /// walkthrough never promises something the editor then refuses.
    public enum BarSetupNotice: Equatable, Sendable {
        case ready
        case needsAccessibility
        case menuBarAutoHides
        case needsScreenRecording
    }

    public static func barSetupNotice(
        hasAccessibility: Bool,
        menuBarAutoHides: Bool,
        hasScreenRecording: Bool,
        platform: WelcomeMenuBarPlatform = .macOS26
    ) -> BarSetupNotice {
        if !hasAccessibility {
            return .needsAccessibility
        }
        if menuBarAutoHides {
            return .menuBarAutoHides
        }
        // The macOS 27 layout editor works from the Accessibility inventory
        // alone; only macOS 26 needs captured item images to show it.
        if !hasScreenRecording, platform.layoutEditorNeedsScreenRecording {
            return .needsScreenRecording
        }
        return .ready
    }
}

/// The menu bar model the running system provides. macOS 27 replaced the
/// per-item status windows Barline arranges on macOS 26, so how items move
/// between sections, and what Screen Recording is for, differ between them.
public enum WelcomeMenuBarPlatform: Sendable, CaseIterable {
    case macOS26
    case macOS27

    public var layoutEditorNeedsScreenRecording: Bool {
        self == .macOS26
    }
}

/// Walkthrough copy that must describe the running system accurately.
public enum WelcomeCopy {
    public static func screenRecordingMessage(for platform: WelcomeMenuBarPlatform) -> String {
        switch platform {
        case .macOS26:
            "Barline uses Screen Recording for the layout editor, which shows images of your menu bar items, and to match your menu bar’s appearance. You can still arrange items without it."
        case .macOS27:
            "Barline uses Screen Recording to match the Barline Bar to your menu bar’s appearance. Arranging items doesn’t need it."
        }
    }

    public static func barSetupInstruction(for platform: WelcomeMenuBarPlatform) -> String {
        switch platform {
        case .macOS26:
            "Hold ⌘ Command and drag an item in the menu bar to move it between sections."
        case .macOS27:
            "Open the layout editor and click an item to move it between sections. An app’s items move together. ⌘ Command-dragging in the menu bar only changes their order."
        }
    }

    public static func menuBarAutoHidesNotice(for platform: WelcomeMenuBarPlatform) -> String {
        switch platform {
        case .macOS26:
            "Your menu bar hides automatically, so the layout editor can’t show it. ⌘ Command-dragging items in the menu bar still works."
        case .macOS27:
            "Your menu bar hides automatically, so the layout editor can’t show it. Turn off automatic menu bar hiding in System Settings to arrange items."
        }
    }

    /// Shown only on macOS 26, where the layout editor needs item images.
    public static let needsScreenRecordingNotice =
        "The layout editor needs Screen Recording. ⌘ Command-dragging items in the menu bar works without it."
}
