import XCTest

final class FoldertoneUITests: XCTestCase {
  @MainActor
  func testSingleFileStartsPlaybackWithoutCreatingPlaylist() {
    let app = XCUIApplication()
    app.launchArguments = ["--empty-library", "--sample-file"]
    app.launch()
    let mini = app.buttons["openPlayer"]
    XCTAssertTrue(mini.waitForExistence(timeout: 20))
    expectation(
      for: NSPredicate(format: "label == %@", "Pause"), evaluatedWith: app.buttons["miniPlayPause"])
    waitForExpectations(timeout: 15)
    app.buttons["playlistPicker"].tap()
    XCTAssertFalse(app.buttons["Sample music"].exists)
    app.buttons["All music"].tap()
    mini.tap()
    XCTAssertTrue(app.navigationBars["Now playing"].waitForExistence(timeout: 5))
    attach(app, name: "Single file playback")
  }

  @MainActor
  func testEmptyLibraryAndMusicPicker() {
    let app = XCUIApplication()
    app.launchArguments = ["--empty-library"]
    app.launch()
    XCTAssertTrue(app.staticTexts["A home for your music."].waitForExistence(timeout: 10))
    // XCTest exposes this native SwiftUI Link as a button.
    XCTAssertTrue(app.buttons["privacyPolicy"].exists, app.debugDescription)
    attach(app, name: "Empty library")
    app.buttons["addMusic"].tap()
    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["A home for your music."].waitForExistence(timeout: 5))
  }

  @MainActor
  func testLibrarySearchAndPlayback() {
    let app = XCUIApplication()
    app.launchArguments = ["--empty-library", "--sample-library"]
    app.launch()
    let first = app.buttons["track-01 - Slow morning"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playAll"])
    waitForExpectations(timeout: 20)
    app.buttons["playlistPicker"].tap()
    app.buttons["Sample music"].tap()
    attach(app, name: "Library")
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("After the rain")
    XCTAssertTrue(app.buttons["track-03 - After the rain"].exists)
    XCTAssertFalse(first.exists)
    search.buttons.firstMatch.tap()
    app.buttons["playAll"].tap()
    let mini = app.buttons["openPlayer"]
    XCTAssertTrue(mini.waitForExistence(timeout: 10))
    let playing = NSPredicate(format: "label == %@", "Pause")
    expectation(for: playing, evaluatedWith: app.buttons["miniPlayPause"])
    waitForExpectations(timeout: 15)
    mini.tap()
    XCTAssertTrue(app.navigationBars["Now playing"].waitForExistence(timeout: 5))
    attach(app, name: "Now playing")
    app.buttons["playerPlayPause"].tap()
    let paused = NSPredicate(format: "label == %@", "Play")
    expectation(for: paused, evaluatedWith: app.buttons["playerPlayPause"])
    waitForExpectations(timeout: 5)
    app.buttons["playerNext"].tap()
    XCTAssertTrue(app.staticTexts["02 - A little further"].waitForExistence(timeout: 5))
    app.buttons["toggleShuffle"].tap()
    XCTAssertEqual(app.buttons["toggleShuffle"].value as? String, "On")
    app.buttons["cycleRepeat"].tap()
    XCTAssertEqual(app.buttons["cycleRepeat"].value as? String, "playlist")
    app.buttons["Up next"].tap()
    XCTAssertTrue(app.navigationBars["Up next"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    app.navigationBars["Now playing"].buttons["Close"].tap()
    XCTAssertFalse(app.buttons["Shuffle"].exists)
    app.buttons["playAll"].tap()
    mini.tap()
    XCTAssertTrue(app.navigationBars["Now playing"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["toggleShuffle"].value as? String, "On")
    app.navigationBars["Now playing"].buttons["Close"].tap()
    app.terminate()
    app.launchArguments = []
    app.launch()
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playAll"])
    waitForExpectations(timeout: 10)
  }

  @MainActor private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
