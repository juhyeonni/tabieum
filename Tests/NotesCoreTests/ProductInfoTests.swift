import Testing
@testable import NotesCore

@Test func readsNameBundleIdentifierAndURLScheme() {
    let info = ProductInfo(infoDictionary: [
        "CFBundleName": "NoteKit",
        "CFBundleIdentifier": "dev.example.notekit",
        "CFBundleURLTypes": [["CFBundleURLSchemes": ["notekit"]]],
    ])
    #expect(info?.name == "NoteKit")
    #expect(info?.bundleIdentifier == "dev.example.notekit")
    #expect(info?.urlScheme == "notekit")
}

@Test func urlSchemeIsOptional() {
    let info = ProductInfo(infoDictionary: [
        "CFBundleName": "NoteKit",
        "CFBundleIdentifier": "dev.example.notekit",
    ])
    #expect(info?.urlScheme == nil)
}

@Test func missingNameOrIdentifierYieldsNil() {
    #expect(ProductInfo(infoDictionary: ["CFBundleName": "NoteKit"]) == nil)
    #expect(ProductInfo(infoDictionary: ["CFBundleIdentifier": "dev.example.notekit"]) == nil)
}
