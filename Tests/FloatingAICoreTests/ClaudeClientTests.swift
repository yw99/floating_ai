import XCTest
import FloatingAICheckSupport

final class ClaudeClientTests: XCTestCase {
    func testCatalogSafetyStreamingAndNativeResume() async throws { try await ClaudeProtocolChecks.testCatalogSafetyStreamingAndNativeResume() }
    func testParallelSessionsInterruptionAndCrashIsolation() async throws { try await ClaudeProtocolChecks.testParallelSessionsInterruptionAndCrashIsolation() }
    func testFailuresApprovalsAndMissingSessions() async throws { try await ClaudeProtocolChecks.testFailuresApprovalsAndMissingSessions() }
    func testCompactedHistoryKeepsOnlyValidArchiveBranches() async throws { try await ClaudeProtocolChecks.testCompactedHistoryKeepsOnlyValidArchiveBranches() }
    func testSessionDeletionIsConfinedAndReapsWriter() async throws { try await ClaudeProtocolChecks.testSessionDeletionIsConfinedAndReapsWriter() }
    func testDeletionFailureKeepsNativeHistory() async throws { try await ClaudeProtocolChecks.testDeletionFailureKeepsNativeHistory() }
    func testScopedAttachmentReaderAndResume() async throws { try await ClaudeProtocolChecks.testScopedAttachmentReaderAndResume() }
    func testAttachmentReaderLimitsAndCancellation() async throws { try await ClaudeProtocolChecks.testAttachmentReaderLimitsAndCancellation() }
}
