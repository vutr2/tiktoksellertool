//
//  ListingForgeUITests.swift
//  ListingForgeUITests
//

import XCTest

final class ListingForgeUITests: XCTestCase {
    @MainActor
    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
    }
}
