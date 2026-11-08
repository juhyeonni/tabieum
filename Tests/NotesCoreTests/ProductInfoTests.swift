import Testing
@testable import NotesCore

@Test func readsNameBundleIdentifierAndURLScheme() {
    let info = ProductInfo(infoDictionary: [
        "CFBundleName": "tabieum",
        "CFBundleIdentifier": "dev.example.tabieum",
        "CFBundleURLTypes": [["CFBundleURLSchemes": ["tabieum"]]],
    ])
    #expect(info?.name == "tabieum")
    #expect(info?.bundleIdentifier == "dev.example.tabieum")
    #expect(info?.urlScheme == "tabieum")
}

@Test func urlSchemeIsOptional() {
    let info = ProductInfo(infoDictionary: [
        "CFBundleName": "tabieum",
        "CFBundleIdentifier": "dev.example.tabieum",
    ])
    #expect(info?.urlScheme == nil)
}

@Test func missingNameOrIdentifierYieldsNil() {
    #expect(ProductInfo(infoDictionary: ["CFBundleName": "tabieum"]) == nil)
    #expect(ProductInfo(infoDictionary: ["CFBundleIdentifier": "dev.example.tabieum"]) == nil)
}

@Test func productInfoReadsTheReleasesRepository() {
    let base: [String: Any] = ["CFBundleName": "tabieum", "CFBundleIdentifier": "dev.example.tabieum"]
    #expect(ProductInfo(infoDictionary: base)?.repository == nil)
    #expect(ProductInfo(infoDictionary: base.merging(["ReleasesRepository": "me/app"]) { $1 })?.repository == "me/app")
}

@Test func productInfoReadsTheVersion() {
    let base: [String: Any] = ["CFBundleName": "tabieum", "CFBundleIdentifier": "dev.example.tabieum"]
    #expect(ProductInfo(infoDictionary: base)?.version == "0")
    #expect(ProductInfo(infoDictionary: base.merging(["CFBundleShortVersionString": "1.2.3"]) { $1 })?.version == "1.2.3")
}
