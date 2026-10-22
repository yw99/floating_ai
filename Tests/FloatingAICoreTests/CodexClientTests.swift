import XCTest
import FloatingAICheckSupport

final class CodexClientTests: XCTestCase {
    func testConnectPaginatesModelsAndDisablesEachMCPWithoutChangingConfig() async throws { try await ProtocolChecks.testConnectPaginatesModelsAndDisablesEachMCPWithoutChangingConfig() }
    func testSplitUnicodeResponsesDuplicateRepliesAndDeclinedServerRequest() async throws { try await ProtocolChecks.testSplitUnicodeResponsesDuplicateRepliesAndDeclinedServerRequest() }
    func testTimeoutDoesNotBreakFutureRequestsAndReconnectIgnoresOldProcess() async throws { try await ProtocolChecks.testTimeoutDoesNotBreakFutureRequestsAndReconnectIgnoresOldProcess() }
    func testTurnOptionsAreSafeAndCompletedNotificationBeforeResponseDoesNotLockThread() async throws { try await ProtocolChecks.testTurnOptionsAreSafeAndCompletedNotificationBeforeResponseDoesNotLockThread() }
    func testCrashFailsPendingAndCanReconnect() async throws { try await ProtocolChecks.testCrashFailsPendingAndCanReconnect() }
    func testErrorCancellationAndMalformedInput() async throws { try await ProtocolChecks.testErrorCancellationAndMalformedInput() }
    func testModernProfileRetainsDynamicEffortsAndLegacyHistory() async throws { try await ProtocolChecks.testModernProfileRetainsDynamicEffortsAndLegacyHistory() }
    func testUnverifiedVersionFailsBeforeAuthenticationOrThreads() async throws { try await ProtocolChecks.testUnverifiedVersionFailsBeforeAuthenticationOrThreads() }
    func testConcurrentThreadsAndInterruption() async throws { try await ProtocolChecks.testConcurrentThreadsAndInterruption() }
    func testPermanentDeletionTargetsOneThreadAndBlocksConcurrentReuse() async throws { try await ProtocolChecks.testPermanentDeletionTargetsOneThreadAndBlocksConcurrentReuse() }
    func testPermanentDeletionRetriesOnlyConfirmedMissingHistories() async throws { try await ProtocolChecks.testPermanentDeletionRetriesOnlyConfirmedMissingHistories() }
    func testPermanentDeletionRejectsLegacyAndBusyThreads() async throws { try await ProtocolChecks.testPermanentDeletionRejectsLegacyAndBusyThreads() }
    func testLiveWebSearchOnFreshAndResumedThreadsKeepsLocalToolsDisabled() async throws { try await ProtocolChecks.testLiveWebSearchOnFreshAndResumedThreadsKeepsLocalToolsDisabled() }
    func testScopedAttachmentReaderCreationSwitchingAndRestore() async throws { try await ProtocolChecks.testScopedAttachmentReaderCreationSwitchingAndRestore() }
    func testAttachmentReaderFailureAndLegacyVersionsDoNotSend() async throws { try await ProtocolChecks.testAttachmentReaderFailureAndLegacyVersionsDoNotSend() }
    func testIndependentAPIKeyAuthenticationAndReconnect() async throws { try await ProtocolChecks.testIndependentAPIKeyAuthenticationAndReconnect() }
    func testAPIKeyBootstrapNotificationsAndRedaction() async throws { try await ProtocolChecks.testAPIKeyBootstrapNotificationsAndRedaction() }
    func testAPIKeyConfigurationFailuresDoNotReceiveCredential() async throws { try await ProtocolChecks.testAPIKeyConfigurationFailuresDoNotReceiveCredential() }
}
