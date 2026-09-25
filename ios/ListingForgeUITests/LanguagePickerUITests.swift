//
//  LanguagePickerUITests.swift
//  ListingForgeUITests
//
//  Proves the one thing unit tests cannot: that picking Tiếng Việt on the
//  sign-in screen actually re-renders the app's own text in Vietnamese.
//
//  SwiftUI resolves localized strings against the locale in its environment,
//  which RootView drives from the picker. That behaviour is the foundation the
//  whole translation effort rests on, so it is pinned end to end rather than
//  assumed. No backend required.
//

import XCTest

final class LanguagePickerUITests: XCTestCase {

    private let englishTagline = "Marketplace-ready listings from one photo."
    private let vietnameseTagline = "Listing chuẩn sàn chỉ từ một tấm ảnh."

    @MainActor
    private func launchSignedOut(startingIn language: String) -> XCUIApplication {
        let app = XCUIApplication()
        // UserDefaults reads the argument domain first, so this pins the
        // starting language without touching the simulator's own settings.
        app.launchArguments = ["-listing-output-language", language]
        app.launch()

        // A persisted Keychain session would open the app on Settings instead.
        if !app.textFields["Email"].waitForExistence(timeout: 5) {
            let settings = app.tabBars.buttons["Settings"]
            if settings.waitForExistence(timeout: 5) {
                settings.tap()
                let signOut = app.buttons["Sign Out"]
                if signOut.waitForExistence(timeout: 5) { signOut.tap() }
            }
        }
        return app
    }

    @MainActor
    func testChoosingVietnameseTranslatesTheAppItself() {
        let app = launchSignedOut(startingIn: "en")
        XCTAssertTrue(app.staticTexts[englishTagline].waitForExistence(timeout: 10),
                      "The sign-in screen did not appear in English.")

        app.buttons["Tiếng Việt"].tap()

        XCTAssertTrue(app.staticTexts[vietnameseTagline].waitForExistence(timeout: 5),
                      "Choosing Tiếng Việt did not translate the app's own text.")
        XCTAssertFalse(app.staticTexts[englishTagline].exists,
                       "The English text is still on screen after switching.")
    }

    /// The sign-in screen is only the first screen. This checks that the rest
    /// of the app is translated too, using the demo session so no backend or
    /// real account is involved.
    @MainActor
    func testTheSignedInAppIsTranslatedToo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--screen", "settings", "-listing-output-language", "vi"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Ngôn ngữ listing"].waitForExistence(timeout: 10),
                      "Settings did not render in Vietnamese.")
        XCTAssertTrue(app.buttons["Xem gói và credit"].exists,
                      "A Settings button is still in English.")
        XCTAssertFalse(app.buttons["View plans and credits"].exists,
                       "The English button is still on screen.")
    }

    @MainActor
    func testTheChoiceSurvivesRelaunch() {
        let app = launchSignedOut(startingIn: "vi")

        XCTAssertTrue(app.staticTexts[vietnameseTagline].waitForExistence(timeout: 10),
                      "A saved Vietnamese choice was not applied at launch.")
    }
}
