import Foundation
import Testing
@testable import NotesCore

@Suite struct NoteLinkTests {
    let id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"

    @Test func buildsWithAndWithoutOwner() {
        #expect(NoteLink(identifier: id).url.absoluteString == "applenotes:note/\(id)")
        #expect(NoteLink(identifier: id, ownerIdentifier: "ACC-1").url.absoluteString
            == "applenotes:note/\(id)?ownerIdentifier=ACC-1")
    }

    @Test func parsesBothFormsBack() {
        for link in [NoteLink(identifier: id), NoteLink(identifier: id, ownerIdentifier: "ACC-1")] {
            #expect(NoteLink(url: link.url) == link)
        }
        #expect(NoteLink(url: URL(string: "applenotes:note/\(id.lowercased())")!)?.identifier == id.lowercased())
    }

    @Test func rejectsOtherSchemesAndMalformedPaths() {
        for text in ["https://example.com/note/\(id)", "notes://showNote?identifier=\(id)", "applenotes:note/",
                     "applenotes:note/not-a-uuid", "applenotes:folder/\(id)", "applenotes://note/\(id)"] {
            #expect(NoteLink(url: URL(string: text)!) == nil, "\(text)")
        }
    }
}
