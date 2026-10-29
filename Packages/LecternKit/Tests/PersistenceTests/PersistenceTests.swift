import Foundation
import ReaderCore
import Testing
@testable import Persistence

@Suite struct InMemoryPasswordStoreTests {
    @Test func storesReplacesAndRemoves() throws {
        let store = InMemoryPasswordStore()
        let key = DocumentKey(rawValue: "id:0102")
        #expect(try store.password(for: key) == nil)
        try store.setPassword("first", for: key)
        try store.setPassword("second", for: key)
        #expect(try store.password(for: key) == "second")
        try store.removePassword(for: key)
        #expect(try store.password(for: key) == nil)
        try store.removePassword(for: key)
    }

    @Test func keysAreIndependent() throws {
        let store = InMemoryPasswordStore([DocumentKey(rawValue: "id:01"): "one"])
        #expect(try store.password(for: DocumentKey(rawValue: "id:02")) == nil)
        #expect(try store.password(for: DocumentKey(rawValue: "id:01")) == "one")
    }
}

/// Touches the real login keychain, so it only runs when asked for:
/// `LECTERN_KEYCHAIN_TESTS=1 swift test`. Items use a test-only service name
/// and are removed afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_KEYCHAIN_TESTS"] == "1"))
struct KeychainPasswordStoreTests {
    @Test func roundTripsThroughTheKeychain() throws {
        let store = KeychainPasswordStore(service: "io.github.ronimoe.Lectern.tests")
        let key = DocumentKey(rawValue: "id:test-\(UUID().uuidString)")
        defer { try? store.removePassword(for: key) }

        #expect(try store.password(for: key) == nil)
        try store.setPassword("sésame", for: key)
        #expect(try store.password(for: key) == "sésame")
        try store.setPassword("changed", for: key)
        #expect(try store.password(for: key) == "changed")
        try store.removePassword(for: key)
        #expect(try store.password(for: key) == nil)
    }
}
