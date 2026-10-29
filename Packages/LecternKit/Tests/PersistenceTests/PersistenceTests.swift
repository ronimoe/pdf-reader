import Testing
@testable import Persistence

@Suite struct PersistenceTests {
    @Test func moduleLinks() { _ = PersistenceModule.self }
}
