import Foundation
import Darwin
import XCTest
@testable import WorseCleaner

final class ReadRetryTests: XCTestCase {
    func testInterruptedReadsPreserveBytesAcrossShortReads() {
        let expected: [UInt8] = [11, 22, 33, 44]
        var calls = 0
        var offset = 0
        let result = WCLaunchServices.readStoreBytes(byteCount: expected.count) { buffer, requested in
            calls += 1
            if calls == 1 || calls == 3 {
                errno = EINTR
                return -1
            }
            let count = min(2, min(requested, expected.count - offset))
            for i in 0..<count { buffer[i] = expected[offset + i] }
            offset += count
            return count
        }
        XCTAssertEqual(result, Data(expected))
        XCTAssertEqual(calls, 4)
    }

    func testOtherReadErrorsAreNotRetried() {
        var calls = 0
        let result = WCLaunchServices.readStoreBytes(byteCount: 4) { _, _ in
            calls += 1
            errno = EACCES
            return -1
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls, 1)
    }

    func testPrematureEOFRejectsPartialData() {
        var calls = 0
        let result = WCLaunchServices.readStoreBytes(byteCount: 4) { buffer, _ in
            calls += 1
            if calls == 1 { buffer[0] = 42; return 1 }
            return 0
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls, 2)
    }

    func testInvalidLengthsRejectWithoutAcceptingExtraBytes() {
        XCTAssertNil(WCLaunchServices.readStoreBytes(byteCount: 1) { _, _ in 2 })
        var calls = 0
        XCTAssertNil(WCLaunchServices.readStoreBytes(byteCount: -1) { _, _ in calls += 1; return 0 })
        XCTAssertNil(WCLaunchServices.readStoreBytes(byteCount: 64 * 1024 * 1024 + 1) { _, _ in calls += 1; return 0 })
        XCTAssertEqual(calls, 0)
    }
}
