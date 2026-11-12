import XCTest
@testable import TrueCameraCore

final class ExposurePolicyTests: XCTestCase {
    func testNeuralFocusIgnoresOneFrameTargetJumpAndAcceptsConfirmedHandover() {
        var continuity=NeuralFocusContinuity()
        let first=Point2(0.2,0.2), other=Point2(0.8,0.8)
        XCTAssertEqual(continuity.accept(first,confidence:0.9,timestamp:1),first)
        XCTAssertEqual(continuity.accept(other,confidence:0.9,timestamp:1.5),first)
        XCTAssertEqual(continuity.accept(first,confidence:0.9,timestamp:2),first)
        XCTAssertEqual(continuity.accept(other,confidence:0.9,timestamp:2.5),first)
        XCTAssertEqual(continuity.accept(other,confidence:0.9,timestamp:3),other)
    }
    func testNeuralFocusTracksOrdinaryMotionAndResetsAfterGap() {
        var continuity=NeuralFocusContinuity()
        let first=Point2(0.2,0.2), moved=Point2(0.3,0.25), nextScene=Point2(0.8,0.8)
        XCTAssertEqual(continuity.accept(first,confidence:0.9,timestamp:1),first)
        XCTAssertEqual(continuity.accept(moved,confidence:0.9,timestamp:1.5),moved)
        XCTAssertNil(continuity.accept(Point2(.nan,0),confidence:0.9,timestamp:2))
        XCTAssertEqual(continuity.accept(nextScene,confidence:0.9,timestamp:5),nextScene)
    }
    private func scene(_ label:String="landscape")->SceneEvidence {
        var s=SceneEvidence(); s.classifications=[NeuralClassification(label,0.92)]
        s.focusPoint=Point2(0.4,0.3); s.focusConfidence=0.8
        return s
    }
    func testManualOwnershipProducesNoControlChanges() throws {
        var own=AIControlOwnership()
        own.exposure=false; own.focus=false; own.whiteBalance=false; own.aperture=false
        let result=try XCTUnwrap(ExposurePolicy.propose(scene:scene(),telemetry:CameraTelemetry(),
            ownership:own,timestamp:10))
        XCTAssertNil(result.iso); XCTAssertNil(result.shutterSeconds); XCTAssertNil(result.exposureBias)
        XCTAssertNil(result.focusPoint); XCTAssertNil(result.whiteBalanceMode); XCTAssertNil(result.aperture)
    }
    func testNeuralMotionClassChangesRealExposureProposal() throws {
        let t=CameraTelemetry()
        let staticDecision=try XCTUnwrap(ExposurePolicy.propose(scene:scene(),telemetry:t,
            ownership:AIControlOwnership(),timestamp:10))
        let sportsDecision=try XCTUnwrap(ExposurePolicy.propose(scene:scene("sports_running"),telemetry:t,
            ownership:AIControlOwnership(),timestamp:10))
        XCTAssertLessThan(try XCTUnwrap(sportsDecision.shutterSeconds),try XCTUnwrap(staticDecision.shutterSeconds))
        XCTAssertGreaterThan(try XCTUnwrap(sportsDecision.iso),try XCTUnwrap(staticDecision.iso))
        // Exposure stays near the same metered brightness despite the faster shutter.
        XCTAssertEqual(sportsDecision.iso!*sportsDecision.shutterSeconds!,
                       staticDecision.iso!*staticDecision.shutterSeconds!,accuracy:0.03)
    }
    func testMeasuredMotionShortensExposureWithoutChangingPixels() throws {
        let s=scene(); var moving=s; moving.subjectMotion=0.15
        let a=try XCTUnwrap(ExposurePolicy.propose(scene:s,telemetry:CameraTelemetry(),ownership:AIControlOwnership(),timestamp:1))
        let b=try XCTUnwrap(ExposurePolicy.propose(scene:moving,telemetry:CameraTelemetry(),ownership:AIControlOwnership(),timestamp:1))
        XCTAssertLessThan(b.shutterSeconds!,a.shutterSeconds!)
    }
    func testAllProposalsStayInsideActiveHardwareLimitsAndVideoFrameDuration() throws {
        for maximumISO in [100.0,400,3200] {
            for fps in [24.0,60,120,240] {
                var t=CameraTelemetry(); t.maxISO=maximumISO; t.isVideo=true; t.fps=fps
                t.minExposureDuration=1/8000; t.maxExposureDuration=1
                t.iso=maximumISO; t.exposureDuration=1/fps; t.exposureTargetOffset = -4
                var s=scene("bird"); s.subjectMotion=1
                let decision=try XCTUnwrap(ExposurePolicy.propose(scene:s,telemetry:t,
                    ownership:AIControlOwnership(),timestamp:1))
                XCTAssertGreaterThanOrEqual(decision.iso!,t.minISO)
                XCTAssertLessThanOrEqual(decision.iso!,t.maxISO)
                XCTAssertGreaterThanOrEqual(decision.shutterSeconds!,t.minExposureDuration)
                XCTAssertLessThanOrEqual(decision.shutterSeconds!,1/fps+1e-12)
            }
        }
    }
    func testHighlightProtectionIsAnExposureSettingNotAToneCurve() throws {
        var s=scene(); s.clippedHighlightFraction=0.1
        let t=CameraTelemetry()
        let decision=try XCTUnwrap(ExposurePolicy.propose(scene:s,telemetry:t,ownership:AIControlOwnership(),timestamp:1))
        XCTAssertLessThan(decision.exposureBias!,0)
        let ev=log2(decision.iso!*decision.shutterSeconds!/(t.iso*t.exposureDuration))
        XCTAssertGreaterThanOrEqual(ev,-0.400001)
        XCTAssertLessThan(ev,0)
    }
    func testExistingExposureBiasIsNotCountedTwice() throws {
        var t=CameraTelemetry(); t.exposureTargetBias=1; t.exposureTargetOffset=0
        let decision=try XCTUnwrap(ExposurePolicy.propose(scene:scene(),telemetry:t,
            ownership:AIControlOwnership(),timestamp:1,exposureCompensation:1))
        XCTAssertEqual(decision.iso!*decision.shutterSeconds!,t.iso*t.exposureDuration,accuracy:0.001)
    }
    func testUncertainNeuralClassificationDoesNotPretendToMakeExposureDecision() throws {
        var s=SceneEvidence(); s.classifications=[NeuralClassification("unknown",0.05)]
        let result=try XCTUnwrap(ExposurePolicy.propose(scene:s,telemetry:CameraTelemetry(),ownership:AIControlOwnership(),timestamp:1))
        XCTAssertNil(result.iso); XCTAssertNil(result.shutterSeconds); XCTAssertNil(result.aperture)
        XCTAssertNil(result.whiteBalanceMode)
        XCTAssertEqual(result.scene,"Scene uncertain")
    }
    func testSemanticMatchingDoesNotMistakeCathedralForCat() {
        XCTAssertEqual(scene("cathedral").confidence(matching:["cat"]),0)
        XCTAssertEqual(scene("domestic_cat").confidence(matching:["cat"]),0.92)
        XCTAssertEqual(scene("birds").confidence(matching:["bird"]),0.92)
    }
    func testImpossibleFrameDurationIsRejected() {
        var t=CameraTelemetry(); t.isVideo=true; t.fps=240; t.minExposureDuration=0.01
        XCTAssertNil(ExposurePolicy.propose(scene:scene(),telemetry:t,ownership:AIControlOwnership(),timestamp:1))
    }
    func testLensApertureRequiresRealHardwareRange() throws {
        let fixed=try XCTUnwrap(ExposurePolicy.propose(scene:scene(),telemetry:CameraTelemetry(),ownership:AIControlOwnership(),timestamp:1))
        XCTAssertNil(fixed.aperture)
        var t=CameraTelemetry(); t.minAperture=1.8; t.maxAperture=4; t.aperture=1.8
        t.exposureDuration=1/1000; t.iso=t.minISO
        let variable=try XCTUnwrap(ExposurePolicy.propose(scene:scene(),telemetry:t,ownership:AIControlOwnership(),timestamp:1))
        XCTAssertEqual(variable.aperture,4)
        let before=t.iso*t.exposureDuration/pow(t.aperture,2)
        let after=variable.iso!*variable.shutterSeconds!/pow(variable.aperture!,2)
        XCTAssertEqual(before,after,accuracy:0.0001)
        // Closing the aperture must not itself trick the next proposal into
        // reopening it because the resulting shutter is correspondingly longer.
        t.aperture=variable.aperture!; t.iso=variable.iso!; t.exposureDuration=variable.shutterSeconds!
        let next=try XCTUnwrap(ExposurePolicy.propose(scene:scene(),telemetry:t,ownership:AIControlOwnership(),timestamp:2))
        XCTAssertEqual(next.aperture,variable.aperture)
    }
    func testWhiteBalanceUsesNativeMeasurementAndStabilityOwnership() throws {
        let t=CameraTelemetry(), s=scene()
        let measuring=try XCTUnwrap(ExposurePolicy.propose(scene:s,telemetry:t,ownership:AIControlOwnership(),timestamp:1))
        XCTAssertEqual(measuring.whiteBalanceMode,.continuous)
        let stable=try XCTUnwrap(ExposurePolicy.propose(scene:s,telemetry:t,ownership:AIControlOwnership(),timestamp:1,whiteBalanceStable:true))
        XCTAssertEqual(stable.whiteBalanceMode,.holdCurrent)
    }
    func testStaleAndFutureDecisionsCannotApplyToAnotherConfiguration() {
        let decision=CameraDecision(revision:4,timestamp:10,validUntil:11)
        XCTAssertTrue(decision.isCurrent(revision:4,now:10.4))
        XCTAssertFalse(decision.isCurrent(revision:5,now:10.4))
        XCTAssertFalse(decision.isCurrent(revision:4,now:11.01))
        XCTAssertFalse(decision.isCurrent(revision:4,now:9.9))
        XCTAssertFalse(decision.isCurrent(revision:4,now:.nan))
    }
    func testNonFiniteMeasurementsAreRejected() {
        var t=CameraTelemetry(); t.iso = .nan
        XCTAssertNil(ExposurePolicy.propose(scene:scene(),telemetry:t,ownership:AIControlOwnership(),timestamp:1))
        t=CameraTelemetry(); t.maxISO = .infinity
        XCTAssertNil(ExposurePolicy.propose(scene:scene(),telemetry:t,ownership:AIControlOwnership(),timestamp:1))
        var s=scene(); s.subjectMotion = .nan
        XCTAssertNil(ExposurePolicy.propose(scene:s,telemetry:CameraTelemetry(),ownership:AIControlOwnership(),timestamp:1))
        XCTAssertNil(ExposurePolicy.propose(scene:scene(),telemetry:CameraTelemetry(),ownership:AIControlOwnership(),timestamp:.nan))
    }
}
