//
//  KeychainStoreTests.swift
//  ListingForgeTests
//
//  The session token lives here, so a silent write failure would log the
//  seller out on every launch. These exercise the real Keychain.
//
//  Serialized: every KeychainStore instance shares one service, so concurrent
//  tests on the same account would race.
//

import Foundation
import Testing
@testable import ListingForge

@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {

    private let key = "listingforge.tests.session"

    @Test("A stored value reads back byte for byte")
    func roundTrip() {
        let store = KeychainStore()
        defer { store.delete(key) }
        let payload = Data("session-token".utf8)

        store.set(payload, for: key)

        #expect(store.data(for: key) == payload)
    }

    @Test("Writing the same key replaces the previous value")
    func overwriteReplaces() {
        let store = KeychainStore()
        defer { store.delete(key) }

        store.set(Data("first".utf8), for: key)
        store.set(Data("second".utf8), for: key)

        // set() deletes before adding; without that, SecItemAdd would return
        // errSecDuplicateItem and the stale token would survive.
        #expect(store.data(for: key) == Data("second".utf8))
    }

    @Test("Deleting removes the value")
    func deleteRemoves() {
        let store = KeychainStore()
        store.set(Data("session-token".utf8), for: key)

        store.delete(key)

        #expect(store.data(for: key) == nil)
    }

    @Test("Reading a key that was never written returns nil")
    func missingKeyIsNil() {
        let store = KeychainStore()
        #expect(store.data(for: "listingforge.tests.never-written") == nil)
    }

    @Test("Deleting a key that does not exist is harmless")
    func deleteMissingKeyIsSafe() {
        let store = KeychainStore()
        store.delete("listingforge.tests.never-written")
        #expect(store.data(for: "listingforge.tests.never-written") == nil)
    }

    @Test("Separate keys do not overwrite each other")
    func keysAreIndependent() {
        let store = KeychainStore()
        defer {
            store.delete("listingforge.tests.a")
            store.delete("listingforge.tests.b")
        }

        store.set(Data("a".utf8), for: "listingforge.tests.a")
        store.set(Data("b".utf8), for: "listingforge.tests.b")

        #expect(store.data(for: "listingforge.tests.a") == Data("a".utf8))
        #expect(store.data(for: "listingforge.tests.b") == Data("b".utf8))
    }
}
