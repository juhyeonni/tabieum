import Foundation
import Testing
@testable import NotesCore

@Suite struct CopyNoteTests {
    static let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    static let body = Encode.gzipBody("Title\nitem\n", [
        Encode.run(6, paragraph: Encode.paragraph(0)), Encode.run(5, paragraph: Encode.paragraph(103, checked: true)), Encode.run(1),
    ])

    func library() throws -> Library {
        let library = try Library()
        try library.account(pk: 1, id: "A-1", name: "iCloud")
        try library.folder(pk: 10, id: "F-10", title: "Notes", account: 1)
        try library.note(pk: 100, id: Self.uuid, title: "Title", folder: 10, created: 1, modified: 2, snippet: nil, body: Self.body)
        try library.note(pk: 102, id: "N-102", title: "Locked", folder: 10, created: 1, modified: 1,
                         snippet: nil, body: Data([1]), locked: 1)
        return library
    }

    @Test func markdownMatchesTheConverter() throws {
        let expected = try NoteBodyDecoder.decode(Self.body).markdown()
        #expect(expected == "# Title\n- [x] item\n")
        let lib = try library()
        #expect(try CopyNote.markdown(key: 100, from: NotesReader(databaseURL: lib.url)) == expected)
    }

    @Test func lockedAndUnknownKeysFail() throws {
        let lib = try library()
        let reader = try NotesReader(databaseURL: lib.url)
        #expect(throws: CopyFailure.locked) { try CopyNote.markdown(key: 102, from: reader) }
        #expect(throws: CopyFailure.locked) { try CopyNote.link(key: 102, from: reader) }
        #expect(throws: CopyFailure.notFound) { try CopyNote.markdown(key: 999, from: reader) }
    }

    @Test func linkParsesBackToTheSameNote() throws {
        let lib = try library()
        let url = try CopyNote.link(key: 100, from: NotesReader(databaseURL: lib.url))
        #expect(url.absoluteString == "applenotes:note/\(Self.uuid)?ownerIdentifier=A-1")
        #expect(NoteLink(url: url)?.identifier == Self.uuid)
    }

    @Test func selectionMustBeExactlyOneNote() throws {
        #expect(try CurrentNote.key(fromSelection: ["x-coredata://ABC/ICNote/p42"]) == 42)
        for ids in [[], ["x-coredata://ABC/ICNote/p1", "x-coredata://ABC/ICNote/p2"], ["x-coredata://ABC/ICFolder/p3"]] {
            #expect(throws: CopyFailure.noCurrentNote) { try CurrentNote.key(fromSelection: ids) }
        }
        #expect(CurrentNote.failure(scriptErrorNumber: -1743) == .automationDenied)
        #expect(CurrentNote.failure(scriptErrorNumber: -600) == .noCurrentNote)
    }
}
