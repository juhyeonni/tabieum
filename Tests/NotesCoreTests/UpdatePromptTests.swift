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

@Test func replaceableCopyOffersInstallFirst() {
    let value = prompt(.replaceable)
    #expect(value.buttons.map(\.title) == ["Install and Relaunch", "Open Release Page", "Later"])
    #expect(value.buttons.map(\.action) == [.install, .openReleasePage, .later])
    #expect(value.command == nil)
    #expect(!value.info.contains("Homebrew"))
}

@Test func fixedCopiesSayWhyTheyCannotBeReplaced() {
    let folder = prompt(.fixed(.notWritable))
    #expect(folder.info.hasSuffix("Tabieum can't replace the app in its folder because the folder is not writable."))
    let moved = prompt(.fixed(.translocated))
    #expect(moved.info.hasSuffix(
        "This copy runs from a temporary location, so Tabieum can't replace it. Move it to /Applications and open it again."))
    for value in [folder, moved] {
        #expect(value.buttons.map(\.title) == ["Open Release Page", "Later"])
        #expect(value.buttons.map(\.action) == [.openReleasePage, .later])
        #expect(value.command == nil)
    }
}

@Test func progressLinesMarkDoneCurrentAndTodo() {
    func marks(_ step: UpdateProgress.Step) -> [UpdateProgress.Mark] {
        UpdateProgress.lines(step: step).map(\.mark)
    }
    #expect(marks(.downloading) == [.done, .current, .todo, .todo, .todo])
    #expect(marks(.replacing) == [.done, .done, .done, .current, .todo])
    for (fraction, text) in [(0.0, "Downloading (0%)"), (0.63, "Downloading (63%)"), (1.0, "Downloading (100%)")] {
        #expect(UpdateProgress.lines(step: .downloading, fraction: fraction).map(\.text) == [
            "Release found", text, "Check the checksum and the signature", "Replace the app", "Relaunch"
        ])
    }
}

@Test func everyFailureHasAReasonAndThePromptKeepsTheCurrentVersion() {
    let failures: [UpdateFailure] = [
        .missingAsset, .addressNotAllowed, .download("x"), .checksumFileUnreadable, .checksumNamesOtherFile,
        .checksumMismatch, .unsafeArchive, .unpackFailed, .appMissing, .wrongBundle, .wrongVersion, .notNewer,
        .signature("x"), .replaceFailed("x"), .cancelled
    ]
    #expect(failures.allSatisfy { !$0.reason.isEmpty })
    let value = UpdateFailurePrompt(failure: .checksumMismatch, product: "Tabieum", version: "0.4.2")
    #expect(value.title == "Couldn't install Tabieum 0.4.2")
    #expect(value.info.hasSuffix("Your current version is unchanged."))
    #expect(value.buttons.map(\.title) == ["Open Release Page", "Close"])
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
