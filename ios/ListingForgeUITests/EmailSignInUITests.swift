//
//  EmailSignInUITests.swift
//  ListingForgeUITests
//
//  End-to-end smoke test for M1: drives the real UI against the real API.
//
//  REQUIRES the configured backend running with Supabase configured. It is
//  the only test here that talks to a live server — everything in
//  ListingForgeTests uses a stubbed URLProtocol instead. Skipped automatically
//  unless RUN_LIVE_AUTH_TESTS=1 is explicitly set; it can send email.
//

import XCTest

final class EmailSignInUITests: XCTestCase {

    private var apiBaseURL: URL? {
        guard let value = Bundle(for: EmailSignInUITests.self)
            .object(forInfoDictionaryKey: "API_BASE_URL") as? String else { return nil }
        return URL(string: value)
    }

    /// The host machine and the simulator share a network stack, so the test
    /// process can check the same origin the app will call.
    ///
    /// This probes the sign-in route rather than `/api/health`, because health
    /// never touches Supabase: a backend running without database credentials
    /// answers health with 200 and then fails the flow, which used to make this
    /// test fail instead of skip.
    private func backendIsReachable() -> Bool {
        guard let apiBaseURL else { return false }
        var reachable = false
        let done = expectation(description: "sign-in route")

        var request = URLRequest(url: apiBaseURL.appendingPathComponent("api/auth/email/request-code"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"email":"uitest-probe@example.com"}"#.utf8)
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            reachable = (200..<300).contains(status)
            done.fulfill()
        }.resume()

        wait(for: [done], timeout: 15)
        return reachable
    }

    /// Taps and waits until the field actually holds keyboard focus.
    ///
    /// `hasKeyboardFocus` is read by key so the check works whether or not the
    /// software keyboard is showing — with a hardware keyboard attached
    /// (simulator ⌘K) it never appears, and waiting on `app.keyboards` alone
    /// would hang.
    @MainActor
    private func focus(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        element.tap()
        let deadline = Date().addingTimeInterval(timeout)
        var retried = false

        while Date() < deadline {
            if (element.value(forKey: "hasKeyboardFocus") as? Bool) == true { return true }
            if element.hasFocus { return true }
            if !retried, Date() > deadline.addingTimeInterval(-timeout / 2) {
                element.tap()
                retried = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Waits until the field reports the text that was typed into it.
    @MainActor
    private func wait(for element: XCUIElement, toHaveValueContaining text: String,
                      timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String)?.contains(text) == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func wait(forEnabled element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Returns the app to the signed-out state if a previous run left a session.
    ///
    /// The session lives in the simulator Keychain and survives reinstalls, so
    /// this test used to land on Settings and fail looking for a field that was
    /// never on screen. The precondition is now established rather than assumed.
    @MainActor
    private func signOutIfNeeded(_ app: XCUIApplication) {
        let emailField = app.textFields["Email"]
        if emailField.waitForExistence(timeout: 5) { return }

        let settingsTab = app.tabBars.buttons["Settings"]
        guard settingsTab.waitForExistence(timeout: 5) else { return }
        settingsTab.tap()

        let signOut = app.buttons["Sign Out"]
        guard signOut.waitForExistence(timeout: 5) else { return }
        signOut.tap()

        XCTAssertTrue(emailField.waitForExistence(timeout: 10),
                      "Signing out did not return the app to the sign-in screen.")
    }

    @MainActor
    func testEmailSignInReachesTheAPI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_LIVE_AUTH_TESTS"] == "1",
                          "Live email delivery requires explicit opt-in: RUN_LIVE_AUTH_TESTS=1.")
        try XCTSkipUnless(backendIsReachable(), "The configured backend is unavailable.")

        let app = XCUIApplication()
        app.launch()
        signOutIfNeeded(app)

        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), "Auth screen did not appear")

        // A tap is asynchronous. Typing before focus lands throws "Neither
        // element nor any descendant has keyboard focus" — the exact failure
        // that made this test flaky. Wait for focus, and retry the tap once,
        // before typing.
        XCTAssertTrue(focus(email), "The email field never took keyboard focus.")
        email.typeText("uitest@example.com")
        XCTAssertTrue(
            wait(for: email, toHaveValueContaining: "uitest@example.com"),
            "Typing did not reach the field; it still reads \(email.value ?? "nil")."
        )

        // SwiftUI re-renders a frame or two after the binding changes, so the
        // button's enabled state is waited for rather than read immediately.
        let submit = app.buttons["Continue with email"]
        XCTAssertTrue(wait(forEnabled: submit), "Button never enabled for a valid address.")
        submit.tap()

        // The code field only appears after the API returns 200: reaching it
        // proves the app reached the configured API and received a successful
        // response. It does not prove that the email was delivered.
        let codeField = app.textFields["6-digit code"]
        XCTAssertTrue(
            codeField.waitForExistence(timeout: 20),
            "No code field — the request failed. On-screen error: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
    }
}
