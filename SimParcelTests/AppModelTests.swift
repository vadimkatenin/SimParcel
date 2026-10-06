import Testing

@MainActor
struct AppModelTests {
    @Test func explainsInaccessibleFile() {
        let failure = """
        Failed to import '/Users/russellzarse/Downloads/HT4HpOiWgAA4ayd.jpeg', error [PHPhotosErrorDomain] 3302: The operation couldn’t be completed. (PHPhotosErrorDomain error 3302.)
        An error was encountered processing the command (domain=com.apple.CoreSimulator.LaunchdSimError, code=133):
        Multiple errors were returned; see stderr
        """

        #expect(AppModel().parseFailure(failure) == "File Inaccessible")
    }

    @Test func ignoresUnknownFailures() {
        #expect(AppModel().parseFailure("Something else went wrong") == nil)
    }
}
