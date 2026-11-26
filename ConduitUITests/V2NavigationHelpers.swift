//
//  V2NavigationHelpers.swift
//  ConduitUITests
//
//  Shared navigation for UI tests running against the V2 tab shell.
//

import XCTest

extension XCUIApplication {
    /// V2 opens on Chats, where the tab bar and the profile strip live; if a
    /// conversation is showing instead, Back returns there.
    func returnToV2Tabs(revealing element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { return }
        let candidates = [
            navigationBars.buttons["Chats"],
            navigationBars.buttons["BackButton"],
            navigationBars.buttons["Back"]
        ]
        // Named Back only: a room's first bar button is Leave.
        candidates.first(where: { $0.exists })?.tap()
    }
}

#if LAA_BUILD
extension XCUIApplication {
    var laaSettingsEntry: XCUIElement {
        #if targetEnvironment(macCatalyst)
        buttons["laa.sidebar.app"]
        #else
        buttons["laa.tabbar.app"]
        #endif
    }

    var laaSettingsCardSettings: XCUIElement { buttons["laa.tabbar.settings"] }

    func openLAASettings(file: StaticString = #filePath, line: UInt = #line) {
        let entry = laaSettingsEntry
        guard entry.waitForExistence(timeout: 30), entry.isHittable else {
            XCTFail("Settings entry is missing or not hittable", file: file, line: line)
            return
        }
        entry.tap()
        let settings = laaSettingsCardSettings
        guard settings.waitForExistence(timeout: 10), settings.isHittable else {
            XCTFail("Settings card entry is missing or not hittable", file: file, line: line)
            return
        }
        settings.tap()
    }

    // The glass destinations are real buttons; match their AX label, not the
    // index or value (Work can expose a badge as its value).
    func laaTab(_ title: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
}
#endif
