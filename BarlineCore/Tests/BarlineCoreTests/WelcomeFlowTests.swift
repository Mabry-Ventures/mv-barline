//
//  WelcomeFlowTests.swift
//  Barline
//

@testable import BarlineCore
import Testing

@Suite("First-run walkthrough")
struct WelcomeFlowTests {
    @Test("A fresh install presents the walkthrough at launch")
    func freshInstallPresents() {
        #expect(
            WelcomeFlow.shouldPresentAtLaunch(
                isEligible: true,
                isFreshInstall: true,
                isCompleted: false,
                savedStep: nil
            )
        )
    }

    @Test("A fresh install relaunched after moving into Applications still presents")
    func freshInstallSurvivesRelocationRelaunch() {
        // The first process ran migrations before offering the move, so the
        // relocated copy finds preferences. The first-run marker, not an empty
        // domain, decides.
        #expect(
            WelcomeFlow.shouldPresentAtLaunch(
                isEligible: true,
                isFreshInstall: true,
                isCompleted: false,
                savedStep: nil
            )
        )
    }

    @Test("Users upgrading with existing preferences are not interrupted")
    func upgradeDoesNotPresent() {
        #expect(
            !WelcomeFlow.shouldPresentAtLaunch(
                isEligible: true,
                isFreshInstall: false,
                isCompleted: false,
                savedStep: nil
            )
        )
    }

    @Test("A walkthrough interrupted by a relaunch resumes")
    func interruptedWalkthroughResumes() {
        for step in [WelcomeStep.welcome, .accessibility, .screenRecording, .barSetup] {
            #expect(
                WelcomeFlow.shouldPresentAtLaunch(
                    isEligible: true,
                    isFreshInstall: false,
                    isCompleted: false,
                    savedStep: step
                )
            )
            #expect(WelcomeFlow.openingStep(savedStep: step) == step)
        }
    }

    @Test("Completed, skipped, or closed walkthroughs never reappear on their own")
    func completedDoesNotPresent() {
        for savedStep in [nil, WelcomeStep.screenRecording, .done] {
            for isFreshInstall in [false, true] {
                #expect(
                    !WelcomeFlow.shouldPresentAtLaunch(
                        isEligible: true,
                        isFreshInstall: isFreshInstall,
                        isCompleted: true,
                        savedStep: savedStep
                    )
                )
            }
        }
    }

    @Test("Development builds never open the walkthrough on launch")
    func ineligibleBuildsDoNotPresent() {
        #expect(
            !WelcomeFlow.shouldPresentAtLaunch(
                isEligible: false,
                isFreshInstall: true,
                isCompleted: false,
                savedStep: .accessibility
            )
        )
    }

    @Test("A saved done step does not resume and opens at the beginning")
    func doneStepIsNotResumed() {
        #expect(
            WelcomeFlow.shouldPresentAtLaunch(
                isEligible: true,
                isFreshInstall: false,
                isCompleted: false,
                savedStep: .done
            ) == false
        )
        #expect(WelcomeFlow.openingStep(savedStep: .done) == .welcome)
        #expect(WelcomeFlow.openingStep(savedStep: nil) == .welcome)
    }

    @Test("Steps run welcome, accessibility, screen recording, bar setup, done")
    func stepOrder() {
        #expect(WelcomeFlow.step(after: .welcome) == .accessibility)
        #expect(WelcomeFlow.step(after: .accessibility) == .screenRecording)
        #expect(WelcomeFlow.step(after: .screenRecording) == .barSetup)
        #expect(WelcomeFlow.step(after: .barSetup) == .done)
        #expect(WelcomeFlow.step(after: .done) == .done)

        #expect(WelcomeFlow.step(before: .welcome) == nil)
        #expect(WelcomeFlow.step(before: .accessibility) == .welcome)
        #expect(WelcomeFlow.step(before: .barSetup) == .screenRecording)
        #expect(WelcomeFlow.step(before: .done) == nil)
    }

    @Test("Bar setup notices follow the layout editor's own precedence")
    func barSetupNotices() {
        #expect(
            WelcomeFlow.barSetupNotice(hasAccessibility: true, menuBarAutoHides: false, hasScreenRecording: true)
                == .ready
        )
        #expect(
            WelcomeFlow.barSetupNotice(hasAccessibility: false, menuBarAutoHides: true, hasScreenRecording: false)
                == .needsAccessibility
        )
        #expect(
            WelcomeFlow.barSetupNotice(hasAccessibility: true, menuBarAutoHides: true, hasScreenRecording: false)
                == .menuBarAutoHides
        )
        #expect(
            WelcomeFlow.barSetupNotice(hasAccessibility: true, menuBarAutoHides: false, hasScreenRecording: false)
                == .needsScreenRecording
        )
    }
}

@Suite("Walkthrough copy per macOS version")
struct WelcomeCopyTests {
    @Test("macOS 27 never claims the layout editor needs Screen Recording")
    func macOS27SkipsScreenRecordingNotice() {
        #expect(
            WelcomeFlow.barSetupNotice(
                hasAccessibility: true,
                menuBarAutoHides: false,
                hasScreenRecording: false,
                platform: .macOS27
            ) == .ready
        )
        #expect(!WelcomeCopy.screenRecordingMessage(for: .macOS27).contains("images of your menu bar items"))
    }

    @Test("macOS 26 still asks for Screen Recording before the editor can show items")
    func macOS26KeepsScreenRecordingNotice() {
        #expect(
            WelcomeFlow.barSetupNotice(
                hasAccessibility: true,
                menuBarAutoHides: false,
                hasScreenRecording: false,
                platform: .macOS26
            ) == .needsScreenRecording
        )
    }

    @Test("Only macOS 26 tells people ⌘ Command-drag moves items between sections")
    func commandDragInstructionMatchesPlatform() {
        #expect(WelcomeCopy.barSetupInstruction(for: .macOS26).contains("move it between sections"))
        #expect(WelcomeCopy.barSetupInstruction(for: .macOS27).contains("only changes their order"))
        #expect(!WelcomeCopy.menuBarAutoHidesNotice(for: .macOS27).contains("Command-dragging items in the menu bar still works"))
    }

    @Test("Each platform has its own copy")
    func copyDiffersByPlatform() {
        #expect(WelcomeCopy.screenRecordingMessage(for: .macOS26) != WelcomeCopy.screenRecordingMessage(for: .macOS27))
        #expect(WelcomeCopy.barSetupInstruction(for: .macOS26) != WelcomeCopy.barSetupInstruction(for: .macOS27))
    }
}
