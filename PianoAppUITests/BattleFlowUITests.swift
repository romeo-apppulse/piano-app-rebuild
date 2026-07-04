//
//  BattleFlowUITests.swift
//  PianoAppUITests
//
//  End-to-end verification of the flows a screenshot can't prove: attack → HP/log,
//  kill → congrats → next monster → undo reversal, and the miniboss trigger/pause/
//  undo. Every test launches with a deterministic PianoCore fixture in a fresh temp
//  sandbox (see UITestSupport) — the device's real data is never touched.
//
//  Expected numbers come from the fixture arithmetic documented in UITestSupport.swift.
//

import XCTest

final class BattleFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture", fixture]
        app.launch()
        XCTAssertTrue(app.staticTexts["battle.monsterName"].waitForExistence(timeout: 8),
                      "battle screen never appeared")
        return app
    }

    /// Drives the full attack flow: LOG PRACTICE → pick the student → type digits → Attack!
    private func logAttack(_ app: XCUIApplication, student: String, digits: String) {
        app.buttons["battle.logPractice"].tap()
        let studentButton = app.buttons[student].firstMatch
        XCTAssertTrue(studentButton.waitForExistence(timeout: 5), "attack sheet / student button missing")
        studentButton.tap()
        for digit in digits {
            app.buttons[String(digit)].firstMatch.tap()
        }
        app.buttons["attack.confirm"].tap()
    }

    /// Waits until an element's label equals the expected string (UI updates are async).
    private func waitForLabel(_ element: XCUIElement, _ expected: String,
                              timeout: TimeInterval = 6,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", expected)
        let outcome = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout)
        XCTAssertEqual(outcome, .completed,
                       "expected label '\(expected)', got '\(element.exists ? element.label : "<missing>")'",
                       file: file, line: line)
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 8,
                          file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == false")
        let outcome = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: timeout)
        XCTAssertEqual(outcome, .completed, "element never disappeared", file: file, line: line)
    }

    // MARK: - Tests

    /// Plain attack: HP drops, the combat-log line appears in the spec's exact format.
    func testAttackReducesHPAndLogsLine() {
        let app = launch(fixture: "battleReady")
        waitForLabel(app.staticTexts["battle.monsterName"], "Gremlin")
        waitForLabel(app.staticTexts["battle.hp"], "30 / 30 HP")

        logAttack(app, student: "Ann", digits: "5")

        XCTAssertTrue(app.staticTexts["Ann does 5 dmg to the monster!"].waitForExistence(timeout: 6))
        waitForLabel(app.staticTexts["battle.hp"], "25 / 30 HP")
    }

    /// The headline flow: kill → congrats moment → next lineup monster at formula HP →
    /// one Undo fully reverses the kill, the spawn, and the lock-in.
    func testKillFiresCongratsSpawnsNextAndUndoReverses() {
        let app = launch(fixture: "battleReady")
        waitForLabel(app.staticTexts["battle.monsterName"], "Gremlin")

        logAttack(app, student: "Ann", digits: "30")   // exact kill, no carryover

        // Congrats moment shows, then clears on its own (~2.5s input lock).
        let won = app.staticTexts["YOU WON!"]
        XCTAssertTrue(won.waitForExistence(timeout: 6), "congrats overlay never appeared")
        waitGone(won)

        // Next monster from the lineup (Dragon), HP from the frozen-averages formula.
        waitForLabel(app.staticTexts["battle.monsterName"], "Dragon")
        waitForLabel(app.staticTexts["battle.hp"], "90 / 90 HP")   // avg 30 × 3 weeks

        // One undo reverses the entire kill chain.
        app.buttons["battle.undo"].tap()
        waitForLabel(app.staticTexts["battle.monsterName"], "Gremlin")
        waitForLabel(app.staticTexts["battle.hp"], "30 / 30 HP")
    }

    /// Reaching the miniboss slot auto-triggers the shared fight (banner + takeover at
    /// all-students × 6-week HP); a global undo un-triggers it and restores the team.
    func testMinibossTriggerTakeoverAndUndoRestores() {
        let app = launch(fixture: "minibossReady")
        waitForLabel(app.staticTexts["battle.monsterName"], "Gremlin")

        logAttack(app, student: "Ann", digits: "30")   // kill → next slot is the miniboss

        let banner = app.staticTexts["battle.minibossBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 8), "miniboss banner never appeared")
        waitGone(app.staticTexts["YOU WON!"])

        // Takeover: everyone now faces the miniboss at (30+0+0) × 6 = 180 HP.
        waitForLabel(app.staticTexts["battle.monsterName"], "Boss King")
        waitForLabel(app.staticTexts["battle.hp"], "180 / 180 HP")

        // Global undo during the miniboss: un-triggers it, revives the team's monster.
        app.buttons["battle.undo"].tap()
        waitGone(banner)
        waitForLabel(app.staticTexts["battle.monsterName"], "Gremlin")
        waitForLabel(app.staticTexts["battle.hp"], "30 / 30 HP")
    }

    /// Overkill carryover, end to end: 40 vs 30 HP kills the Gremlin and the leftover
    /// 10 lands on the freshly spawned Dragon.
    func testOverkillCarriesOntoNextMonster() {
        let app = launch(fixture: "battleReady")
        waitForLabel(app.staticTexts["battle.monsterName"], "Gremlin")

        logAttack(app, student: "Ann", digits: "40")

        waitGone(app.staticTexts["YOU WON!"], timeout: 10)
        waitForLabel(app.staticTexts["battle.monsterName"], "Dragon")
        // Dragon HP: capped kill entry (30) on one day → avg 30 × 3 = 90; carry 10 → 80 left.
        waitForLabel(app.staticTexts["battle.hp"], "80 / 90 HP")
    }
}
