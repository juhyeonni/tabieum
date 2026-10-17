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
