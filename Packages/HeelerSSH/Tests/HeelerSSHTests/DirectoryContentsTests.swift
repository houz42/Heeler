import Foundation
import Testing

@testable import HeelerSSH

// SPDX-License-Identifier: Apache-2.0
//
// The full-contents directory listing (files kept alongside directories)
// that the composer's dynamic slash-command discovery consumes. The
// directories-only listing's own tests live in DirectoryListingTests.

@Test("full-contents listings keep files and drop only dot entries")
func fullContentsListingsKeepFiles() {
    let contents = SSHSFTPDirectoryContents(rawEntries: [
        (name: ".", isDirectory: true),
        (name: "..", isDirectory: true),
        (name: "deploy.md", isDirectory: false),
        (name: "skills", isDirectory: true),
        (name: ".hidden", isDirectory: true),
    ])
    #expect(contents.entries.map(\.name) == [".hidden", "deploy.md", "skills"])
    #expect(
        contents.entries.map(\.isDirectory) == [true, false, true])
    #expect(!contents.truncated)
}

@Test("full-contents listings sort by name")
func fullContentsListingsSortByName() {
    let contents = SSHSFTPDirectoryContents(rawEntries: [
        (name: "bravo.md", isDirectory: false),
        (name: "alpha", isDirectory: true),
    ])
    #expect(contents.entries.map(\.name) == ["alpha", "bravo.md"])
}

@Test("full-contents listings cap at 500 entries and report truncation")
func fullContentsListingsCapAtMaximumEntries() {
    #expect(SSHSFTPDirectoryContents.maximumEntries == 500)
    let over = (0..<502).map { (name: "entry-\($0)", isDirectory: $0 % 2 == 0) }
    let truncated = SSHSFTPDirectoryContents(rawEntries: over)
    #expect(truncated.entries.count == 500)
    #expect(truncated.truncated)
}
