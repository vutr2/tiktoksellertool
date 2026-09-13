//
//  EmailSignInUITests.swift
//  ListingForgeUITests
//
//  End-to-end smoke test for M1: drives the real UI against the real API.
//
//  REQUIRES the backend running (`make api`) with Supabase configured. It is
//  the only test here that talks to a live server — everything in
//  ListingForgeTests uses a stubbed URLProtocol instead. Skipped automatically
//  when the server is unreachable so it never fails a normal run.
//

import XCTest

final class EmailSignInUITests: XCTestCase {

    private let apiBaseURL = URL(string: "http://localhost:3000")!

    /// The host machine and the simulator share a network stack, so the test
    /// process can check the same origin the app will call.
    private func backendIsReachable() -> Bool {
        var reachable = false
        let done = expectation(description: "health")
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("api/health"))
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
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

    @MainActor
    func testEmailSignInReachesTheAPI() throws {
        try XCTSkipUnless(backendIsReachable(), "Backend not running — start it with `make api`.")

        let app = XCUIApplication()
        app.launch()

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
        // proves app -> localhost:3000 -> Supabase -> back all worked, and that
        // App Transport Security did not block the cleartext localhost call.
        let codeField = app.textFields["6-digit code"]
        XCTAssertTrue(
            codeField.waitForExistence(timeout: 20),
            "No code field — the request failed. On-screen error: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
    }
}
