import XCTest

final class FoldertoneUITests: XCTestCase {
  @MainActor
  func testSingleFileStartsPlaybackWithoutCreatingPlaylist() {
    let app = launch("--empty-library", "--sample-file")
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
    let app = launch("--empty-library")
    XCTAssertTrue(app.staticTexts["A home for your music."].waitForExistence(timeout: 10))
    // The simulator exposes this SwiftUI Link as a button and an iPhone as a link.
    XCTAssertTrue(
      app.descendants(matching: .any)["privacyPolicy"].exists, app.debugDescription)
    attach(app, name: "Empty library")
    app.buttons["addMusic"].tap()
    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(
      cancel.waitForExistence(timeout: 10) || app.buttons["Open"].exists,
      "The Files picker must appear")
    if cancel.exists {
      cancel.tap()
    } else {
      // On an iPhone the picker can open inside a folder without Cancel; swipe its sheet away
      // from just above its Open button.
      let open = app.buttons["Open"].frame
      let window = app.coordinate(withNormalizedOffset: .zero)
      window.withOffset(CGVector(dx: open.midX, dy: open.minY - 12)).press(
        forDuration: 0.05,
        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    }
    XCTAssertTrue(app.staticTexts["A home for your music."].waitForExistence(timeout: 5))
  }

  @MainActor
  func testLibrarySearchAndPlayback() {
    let app = launch("--empty-library", "--sample-library")
    let first = app.buttons["track-01 - Slow morning"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playAll"])
    waitForExpectations(timeout: 20)
    app.buttons["playlistPicker"].tap()
    app.buttons["Sample music"].tap()
    attach(app, name: "Library")
    let search = app.searchFields.firstMatch
    if !search.waitForExistence(timeout: 2) {
      // On an iPhone the navigation bar drawer keeps search hidden until the list is pulled down.
      app.collectionViews.firstMatch.swipeDown()
    }
    XCTAssertTrue(search.waitForExistence(timeout: 5))
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
    // The mini-player's own button pauses and resumes; a tap must not fall through to a row.
    app.buttons["miniPlayPause"].tap()
    expectation(
      for: NSPredicate(format: "label == %@", "Play"), evaluatedWith: app.buttons["miniPlayPause"])
    waitForExpectations(timeout: 5)
    app.buttons["miniPlayPause"].tap()
    expectation(for: playing, evaluatedWith: app.buttons["miniPlayPause"])
    waitForExpectations(timeout: 5)
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
    launch(into: app)
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playAll"])
    waitForExpectations(timeout: 10)
  }

  @MainActor
  func testRowTogglesAndRemovedSongsReturn() {
    let app = launch("--empty-library", "--sample-library")
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playAll"])
    waitForExpectations(timeout: 20)
    app.buttons["playlistPicker"].tap()
    app.buttons["Sample music"].tap()
    let first = app.buttons["track-01 - Slow morning"]
    let state = app.buttons["miniPlayPause"]
    // The first tap plays the song; tapping the playing song pauses it, then resumes it.
    for (index, wanted) in ["Pause", "Play", "Pause"].enumerated() {
      first.tap()
      if index == 0 { XCTAssertTrue(state.waitForExistence(timeout: 10)) }
      expectation(for: NSPredicate(format: "label == %@", wanted), evaluatedWith: state)
      waitForExpectations(timeout: 10)
    }
    let second = app.buttons["track-02 - A little further"]
    second.press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Remove from Playlist"].waitForExistence(timeout: 5))
    attach(app, name: "Song menu")
    app.buttons["Remove from Playlist"].tap()
    XCTAssertTrue(second.waitForNonExistence(timeout: 5))
    app.terminate()
    launch(into: app)
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    XCTAssertFalse(second.exists, "A removed song must not come back after relaunch")
    app.buttons["sourceSettings"].tap()
    app.buttons["Removed Songs (1)"].tap()
    XCTAssertTrue(app.buttons["restore-02 - A little further"].waitForExistence(timeout: 5))
    attach(app, name: "Removed songs")
    app.buttons["restore-02 - A little further"].tap()
    XCTAssertTrue(app.staticTexts["No Removed Songs"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["Done"].tap()
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    // Swiping a song left offers the same removal.
    let third = app.buttons["track-03 - After the rain"]
    third.swipeLeft()
    app.buttons["Remove"].tap()
    XCTAssertTrue(third.waitForNonExistence(timeout: 5))
  }

  /// README screenshots; scripts/capture-screenshots.sh supplies the folder.
  @MainActor
  func testReadmeScreenshots() throws {
    guard let folder = ProcessInfo.processInfo.environment["FOLDERTONE_SCREENSHOT_FOLDER"] else {
      throw XCTSkip("Run through scripts/capture-screenshots.sh")
    }
    let app = launch("--empty-library", "--library-folder", folder)
    // Play all only after the whole folder is indexed, so it starts from the first track.
    XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 30))
    app.buttons["playAll"].tap()
    let mini = app.buttons["openPlayer"]
    XCTAssertTrue(mini.waitForExistence(timeout: 10))
    expectation(
      for: NSPredicate(format: "label == %@", "Pause"), evaluatedWith: app.buttons["miniPlayPause"])
    waitForExpectations(timeout: 15)
    attach(app, name: "library")
    mini.tap()
    XCTAssertTrue(app.navigationBars["Now playing"].waitForExistence(timeout: 5))
    sleep(2)
    attach(app, name: "player")
  }

  /// Launches with --isolated-storage, so a run on a real iPhone never touches the owner's library.
  @MainActor @discardableResult
  private func launch(
    _ arguments: String..., into app: XCUIApplication = XCUIApplication()
  ) -> XCUIApplication {
    app.launchArguments = ["--isolated-storage"] + arguments
    app.launch()
    return app
  }

  @MainActor private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
