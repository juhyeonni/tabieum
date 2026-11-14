import Foundation
import Testing
@testable import NotesCore

private func release(notes: String = "") -> Release {
    let page = URL(string: "https://github.com/me/app/releases/tag/v0.4.3")!
    return Release(version: "0.4.3", url: page, notes: notes, zip: nil, checksum: nil)
}

private func prompt(_ kind: InstallKind, notes: String = "") -> UpdatePrompt {
    UpdatePrompt(release: release(notes: notes), current: "0.4.2", kind: kind, product: "Tabieum")
}

@Test func promptNamesTheVersionAndWhatYouHave() {
    let value = prompt(.replaceable)
    #expect(value.title == "Tabieum 0.4.3 is available")
    #expect(value.info.hasPrefix("You have 0.4.2."))
}

@Test func replaceableAndFixedCopiesOpenTheReleasePage() {
    for kind: InstallKind in [.replaceable, .fixed(.notWritable), .fixed(.translocated)] {
        let value = prompt(kind)
        #expect(value.buttons.map(\.title) == ["Open Release Page", "Later"])
        #expect(value.buttons.map(\.action) == [.openReleasePage, .later])
        #expect(value.command == nil)
        #expect(!value.info.contains("Homebrew"))
    }
}

@Test func homebrewCopyGetsTheCommand() {
    let value = prompt(.homebrew)
    #expect(value.command == "brew upgrade --cask tabieum")
    #expect(value.info.contains("This copy was installed with Homebrew, so Homebrew should update it."))
    #expect(value.info.contains("Then relaunch Tabieum to use the new version."))
    #expect(value.buttons.map(\.title) == ["Copy Command", "Later"])
    #expect(value.buttons.map(\.action) == [.copyCommand, .later])
}

@Test func releaseNotesBecomeHeadingAndBulletBlocks() {
    let notes = "## New\n\n- Adds `Check for Updates…`\n\n## Fixed\n\n- Fixes `Cmd+K`\n"
    #expect(prompt(.replaceable, notes: notes).notes == [
        .heading("New"), .bullet("Adds `Check for Updates…`"),
        .heading("Fixed"), .bullet("Fixes `Cmd+K`")
    ])
}

@Test func blockReaderHandlesTheOtherShapes() {
    let text = "Intro\r\n\r\n* star\r\n+ plus\r\n  - nested\r\n```sh\nbrew x\n\nbrew y\n```\r\n###### Deep"
    #expect(UpdatePrompt.blocks(from: text) == [
        .paragraph("Intro"), .bullet("star"), .bullet("plus"), .bullet("nested"),
        .code("brew x\n\nbrew y"), .heading("Deep")
    ])
    #expect(UpdatePrompt.blocks(from: "").isEmpty)
    #expect(UpdatePrompt.blocks(from: " \n\n").isEmpty)
}
