import Foundation
import Testing
@testable import NotesCore

private func body(tag: String = "v1.2.0", url: String = "https://github.com/me/app/releases/tag/v1.2.0") -> Data {
    Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)"}"#.utf8)
}

@Test func latestReleaseDropsTheLeadingV() {
    let release = UpdateCheck.latest(from: body())
    #expect(release?.version == "1.2.0")
    #expect(release?.url.absoluteString == "https://github.com/me/app/releases/tag/v1.2.0")
    #expect(UpdateCheck.latest(from: body(tag: "1.2.0"))?.version == "1.2.0")
}

@Test func latestReleaseRefusesPagesOutsideGitHubOrWithoutHTTPS() {
    #expect(UpdateCheck.latest(from: body(url: "https://example.com/x")) == nil)
    #expect(UpdateCheck.latest(from: body(url: "http://github.com/me/app")) == nil)
    #expect(UpdateCheck.latest(from: body(url: "file:///etc/passwd")) == nil)
}

@Test func latestReleaseNeedsBothFields() {
    #expect(UpdateCheck.latest(from: Data(#"{"tag_name":"v1"}"#.utf8)) == nil)
    #expect(UpdateCheck.latest(from: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
    #expect(UpdateCheck.latest(from: Data("not json".utf8)) == nil)
}

@Test func versionsCompareNumericallyPerPart() {
    #expect(UpdateCheck.isNewer("1.10.0", than: "1.9.0"))
    #expect(UpdateCheck.isNewer("1.0.1", than: "1.0.0"))
    #expect(!UpdateCheck.isNewer("1.0.0", than: "1.0.0"))
    #expect(!UpdateCheck.isNewer("0.9.9", than: "1.0.0"))
}

@Test func endpointAcceptsOnlyOwnerSlashName() {
    #expect(UpdateCheck.endpoint(repository: "me/app")?.absoluteString == "https://api.github.com/repos/me/app/releases/latest")
    #expect(UpdateCheck.endpoint(repository: "me/app.v2-x_y") != nil)
    #expect(UpdateCheck.endpoint(repository: "me") == nil)
    #expect(UpdateCheck.endpoint(repository: "me/app/extra") == nil)
    #expect(UpdateCheck.endpoint(repository: "../x/y?z") == nil)
}

private func release(body: String? = "Notes", assets: [(String, String)]) -> Data {
    let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }.joined(separator: ",")
    let bodyJSON = body.map { #""\#($0)""# } ?? "null"
    let page = "https://github.com/me/app/releases/tag/v1.2.0"
    return Data(#"{"tag_name":"v1.2.0","html_url":"\#(page)","body":\#(bodyJSON),"assets":[\#(list)]}"#.utf8)
}

private let downloads = "https://github.com/me/app/releases/download/v1.2.0/"

@Test func releaseReadsNotesAndMatchingAssets() {
    let data = release(assets: [
        ("App-1.2.0.zip", downloads + "App-1.2.0.zip"),
        ("App-1.2.0.zip.sha256", downloads + "App-1.2.0.zip.sha256")
    ])
    let found = UpdateCheck.latest(from: data, product: "App", repository: "me/app")
    #expect(found?.notes == "Notes")
    #expect(found?.zip?.absoluteString == downloads + "App-1.2.0.zip")
    #expect(found?.checksum?.absoluteString == downloads + "App-1.2.0.zip.sha256")
}

@Test func releaseWithoutBodyOrAssetsStillParses() {
    for data in [body(), release(body: nil, assets: [])] {
        let found = UpdateCheck.latest(from: data, product: "App", repository: "me/app")
        #expect(found?.version == "1.2.0")
        #expect(found?.notes == "")
        #expect(found?.zip == nil && found?.checksum == nil)
    }
}

@Test func assetsOnOtherHostsSchemesOrPathsAreAbsent() {
    let data = release(assets: [
        ("App-1.2.0.zip", "https://example.com/releases/download/App-1.2.0.zip"),
        ("App-1.2.0.zip.sha256", "http://github.com/me/app/releases/download/v1.2.0/App-1.2.0.zip.sha256")
    ])
    #expect(UpdateCheck.latest(from: data, product: "App", repository: "me/app")?.zip == nil)
    #expect(UpdateCheck.latest(from: data, product: "App", repository: "me/app")?.checksum == nil)
    let other = release(assets: [
        ("App-1.2.0.zip", "https://github.com/me/app/raw/main/App-1.2.0.zip"),
        ("App-1.2.0.zip.sha256", downloads + "App-1.2.0.zip.sha256")
    ])
    let found = UpdateCheck.latest(from: other, product: "App", repository: "me/app")
    #expect(found?.zip == nil)
    #expect(found?.checksum != nil)
}

@Test func assetsWithOtherNamesAreIgnored() {
    let data = release(assets: [
        ("App-1.1.0.zip", downloads + "App-1.1.0.zip"),
        ("App-1.2.0.zip.sha256.txt", downloads + "x"),
        ("App-1.2.0.dmg", downloads + "App-1.2.0.dmg"),
        ("App-1.2.0.zip", downloads + "App-1.2.0.zip")
    ])
    let found = UpdateCheck.latest(from: data, product: "App", repository: "me/app")
    #expect(found?.zip?.lastPathComponent == "App-1.2.0.zip")
    #expect(found?.checksum == nil)
    #expect(UpdateCheck.latest(from: data)?.zip == nil)
}

@Test func checksumFileParses() {
    let digest = String(repeating: "ab", count: 32)
    let upper = digest.uppercased()
    #expect(UpdateCheck.parseChecksum("\(digest)  App-1.2.0.zip\n")?.digest == digest)
    #expect(UpdateCheck.parseChecksum("\(digest)  App-1.2.0.zip")?.file == "App-1.2.0.zip")
    #expect(UpdateCheck.parseChecksum("\(digest) *App.zip")?.file == "App.zip")
    #expect(UpdateCheck.parseChecksum("\n\n\(upper)  App.zip\nother line\n")?.digest == digest)
    #expect(UpdateCheck.parseChecksum(String(digest.dropLast()) + "  App.zip") == nil)
    #expect(UpdateCheck.parseChecksum(digest + "0  App.zip") == nil)
    #expect(UpdateCheck.parseChecksum(String(repeating: "g", count: 64) + "  App.zip") == nil)
    #expect(UpdateCheck.parseChecksum(digest) == nil)
    #expect(UpdateCheck.parseChecksum(digest + "  ") == nil)
    #expect(UpdateCheck.parseChecksum("") == nil)
}

@Test func installKindFollowsPrecedence() {
    func kind(_ path: String, cask: Bool, writable: Bool) -> InstallKind {
        UpdateCheck.installKind(
            bundlePath: path, product: "Tabieum",
            hasCaskroom: { $0 == "tabieum" && cask }, isWritable: { _ in writable })
    }
    #expect(kind("/Applications/Tabieum.app", cask: true, writable: true) == .homebrew)
    #expect(kind("/private/var/AppTranslocation/X/d/Tabieum.app", cask: false, writable: true) == .fixed(.translocated))
    #expect(kind("/Applications/Tabieum.app", cask: false, writable: false) == .fixed(.notWritable))
    #expect(kind("/Applications/Tabieum.app", cask: false, writable: true) == .replaceable)
}
