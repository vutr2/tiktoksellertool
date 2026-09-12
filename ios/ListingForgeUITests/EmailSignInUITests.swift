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

    @MainActor
    func testEmailSignInReachesTheAPI() throws {
        try XCTSkipUnless(backendIsReachable(), "Backend not running — start it with `make api`.")

        let app = XCUIApplication()
        app.launch()

        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), "Auth screen did not appear")

        email.tap()
        email.typeText("uitest@example.com")

        let submit = app.buttons["Continue with email"]
        XCTAssertTrue(submit.isEnabled, "Button should enable once the address contains @")
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
