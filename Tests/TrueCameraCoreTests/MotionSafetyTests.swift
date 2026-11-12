import XCTest
@testable import TrueCameraCore

final class MotionSafetyTests: XCTestCase {
    func testNonfiniteGyroAndYawSamplesCannotPoisonTheHistory() throws {
        var history = MotionHistory()
        history.append(MotionReading(time:1,gx:0,gy:-1,gz:0,rateZ:0))
        history.append(MotionReading(time:2,gx:0,gy:-1,gz:0,rateZ:0,rateX:.nan))
        history.append(MotionReading(time:3,gx:0,gy:-1,gz:0,rateZ:0,rateY:.infinity))
        history.append(MotionReading(time:4,gx:0,gy:-1,gz:0,rateZ:0,yaw:-.infinity))
        XCTAssertEqual(history.readings.count,1)
        XCTAssertEqual(try XCTUnwrap(history.sample(at:1)).time,1)
    }

    func testSensorInterruptionDoesNotInventIntermediateMotion() throws {
        var history = MotionHistory()
        history.append(MotionReading(time:1,gx:0,gy:-1,gz:0,rateZ:0,rateY:1))
        history.append(MotionReading(time:2,gx:0,gy:-1,gz:0,rateZ:0,rateY:-1))
        XCTAssertNil(history.sample(at:1.5,maxInterpolationGap:0.1))
        XCTAssertEqual(try XCTUnwrap(history.sample(at:1,maxInterpolationGap:0.1)).rateY,1)
        XCTAssertEqual(try XCTUnwrap(history.sample(at:2,maxInterpolationGap:0.1)).rateY,-1)
    }

    func testOrdinarySensorCadenceStillInterpolates() throws {
        var history = MotionHistory()
        history.append(MotionReading(time:1,gx:0,gy:-1,gz:0,rateZ:0,rateX:1,rateY:2))
        history.append(MotionReading(time:1.01,gx:0.02,gy:-0.98,gz:0,rateZ:0.2,rateX:3,rateY:4))
        let sample = try XCTUnwrap(history.sample(at:1.005,maxInterpolationGap:0.1))
        XCTAssertEqual(sample.rateX,2,accuracy:1e-10)
        XCTAssertEqual(sample.rateY,3,accuracy:1e-10)
        XCTAssertEqual(sample.rateZ,0.1,accuracy:1e-10)
    }

    func testInvalidTimingArgumentsAndOverflowingGeometryAreRejected() {
        var history = MotionHistory()
        history.append(MotionReading(time:1,gx:0,gy:-1,gz:0,rateZ:0))
        XCTAssertNil(history.sample(at:1,tolerance:.nan))
        XCTAssertNil(history.sample(at:1,tolerance:-0.1))
        XCTAssertNil(history.sample(at:1,maxInterpolationGap:0))
        XCTAssertThrowsError(try CropGeometry.plan(source:Size2(1,1),
            output:Size2(Double.greatestFiniteMagnitude,Double.greatestFiniteMagnitude),
            angle:0,fullTurn:true))
    }
}
