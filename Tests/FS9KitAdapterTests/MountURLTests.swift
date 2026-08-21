import Testing
import Foundation
import NineP
import NinePClient
@testable import FS9KitAdapter

/// The mount URL is the whole configuration surface of an FSKit mount: FSKit
/// skips `probeResource` for a URL resource, so a URL that parses wrong is a
/// mount that fails with a bare errno and no explanation.
@Suite("Mount URL parsing")
struct MountURLTests {

    @Test("the ordinary form: host, port, tree")
    func ordinary() throws {
        let spec = try MountSpec.parse("9p://files.example.com:1564/exports")
        #expect(spec.endpoint == .tcp(host: "files.example.com", port: 1564))
        #expect(spec.aname == "exports")
        #expect(spec.readOnly == false)
        #expect(spec.volumeName == "exports")
    }

    @Test("the port defaults to 564, 9P's registered port")
    func defaultPort() throws {
        let spec = try MountSpec.parse("9p://files.example.com/exports")
        #expect(spec.endpoint == .tcp(host: "files.example.com", port: 564))
        #expect(P9.defaultPort == 564)
    }

    @Test("no path means an empty aname, which is what most servers want")
    func emptyAname() throws {
        #expect(try MountSpec.parse("9p://host/").aname == "")
        #expect(try MountSpec.parse("9p://host").aname == "")
        // With no tree to name it after, the volume takes the host's name.
        #expect(try MountSpec.parse("9p://host").volumeName == "host")
    }

    @Test("a nested aname keeps its slashes and names the volume after its last component")
    func nestedAname() throws {
        let spec = try MountSpec.parse("9p://host/srv/exports/home")
        #expect(spec.aname == "srv/exports/home")
        #expect(spec.volumeName == "home")
    }

    /// `9p` is not a legal RFC 3986 scheme — schemes must start with a letter —
    /// so `URL(string:)` rejects it and `mount(8)` builds its resource with
    /// exactly that call. `p9` is registered as the spelling that always works.
    @Test("all three tcp spellings parse the same", arguments: ["9p", "9pfs", "p9"])
    func schemes(scheme: String) throws {
        let spec = try MountSpec.parse("\(scheme)://host:564/tree")
        #expect(spec.endpoint == .tcp(host: "host", port: 564))
        #expect(spec.canonicalTarget == "9p://host:564/tree")
    }

    @Test("scheme matching is case-insensitive, as FSSupportedSchemes promises")
    func schemeCase() throws {
        #expect(try MountSpec.parse("9P://host/x").aname == "x")
    }

    @Test("a unix socket path is the URL path, and aname comes from the query")
    func unixSocket() throws {
        let spec = try MountSpec.parse("9p+unix:///run/9p/socket?aname=share")
        #expect(spec.endpoint == .unix(path: "/run/9p/socket"))
        #expect(spec.aname == "share")
        #expect(spec.volumeName == "share")
    }

    @Test("a unix socket with no aname attaches to the default tree")
    func unixSocketNoAname() throws {
        let spec = try MountSpec.parse("9p+unix:///tmp/9p.sock")
        #expect(spec.endpoint == .unix(path: "/tmp/9p.sock"))
        #expect(spec.aname == "")
        #expect(spec.volumeName == "9p.sock")
    }

    @Test("a unix socket URL may not carry a host")
    func unixSocketWithHost() {
        #expect(throws: MountURLError.unexpectedAuthority("host")) {
            try MountSpec.parse("9p+unix://host/run/socket")
        }
    }

    @Test("an IPv6 literal keeps its brackets out of the host")
    func ipv6() throws {
        let spec = try MountSpec.parse("9p://[fe80::1]:564/tree")
        #expect(spec.endpoint == .tcp(host: "fe80::1", port: 564))
        #expect(spec.canonicalTarget == "9p://[fe80::1]:564/tree")
    }

    @Test("an IPv6 literal without a port still gets the default")
    func ipv6DefaultPort() throws {
        #expect(try MountSpec.parse("9p://[::1]/x").endpoint == .tcp(host: "::1", port: 564))
    }

    @Test("percent-encoding is decoded in the aname")
    func percentEncodedPath() throws {
        #expect(try MountSpec.parse("9p://host/my%20share").aname == "my share")
        #expect(try MountSpec.parse("9p://host/a%2Fb").aname == "a/b")
    }

    @Test("a truncated percent escape is refused rather than guessed at")
    func badPercentEncoding() {
        #expect(throws: MountURLError.invalidPercentEncoding("bad%zz")) {
            try MountSpec.parse("9p://host/bad%zz")
        }
    }

    @Test("userinfo sets the 9P uname")
    func userInfo() throws {
        let spec = try MountSpec.parse("9p://alice@host/tree")
        #expect(spec.uname == "alice")
        #expect(spec.endpoint == .tcp(host: "host", port: 564))
    }

    @Test("an explicit uname= wins over userinfo")
    func unameOverridesUserInfo() throws {
        #expect(try MountSpec.parse("9p://alice@host/t?uname=bob").uname == "bob")
    }

    @Test("uname defaults to the current user only when the URL says nothing")
    func unameDefault() throws {
        let spec = try MountSpec.parse("9p://host/t")
        #expect(spec.uname == nil)
        #expect(spec.makeCredentials().uname == NinePCredentials.currentUserName())
    }

    // MARK: - Options

    @Test("ro is a bare flag")
    func readOnlyFlag() throws {
        #expect(try MountSpec.parse("9p://host/t?ro").readOnly)
        #expect(try MountSpec.parse("9p://host/t?rdonly").readOnly)
        #expect(try MountSpec.parse("9p://host/t?readonly=1").readOnly)
        #expect(try MountSpec.parse("9p://host/t?ro=false").readOnly == false)
        #expect(try MountSpec.parse("9p://host/t?rw").readOnly == false)
        #expect(try MountSpec.parse("9p://host/t").readOnly == false)
    }

    @Test("debug is a bare flag too")
    func debugFlag() throws {
        #expect(try MountSpec.parse("9p://host/t?debug").debug)
        #expect(try MountSpec.parse("9p://host/t").debug == false)
    }

    @Test("uid and gid override what the server reports")
    func forcedOwnership() throws {
        let spec = try MountSpec.parse("9p://host/t?uid=501&gid=20")
        #expect(spec.forcedUID == 501)
        #expect(spec.forcedGID == 20)
        #expect(spec.makeVFSOptions().forcedUID == 501)
        #expect(spec.makeVFSOptions().forcedGID == 20)
    }

    @Test("msize takes k and m suffixes")
    func msize() throws {
        #expect(try MountSpec.parse("9p://host/t?msize=65536").msize == 65536)
        #expect(try MountSpec.parse("9p://host/t?msize=64k").msize == 65536)
        #expect(try MountSpec.parse("9p://host/t?msize=1M").msize == 1024 * 1024)
        #expect(try MountSpec.parse("9p://host/t?msize=64k").makeSessionOptions().msize == 65536)
    }

    /// Below 4 KiB a single directory entry may not fit in one message; above
    /// 16 MiB a server is within its rights to refuse the session outright.
    @Test("msize outside the workable range is refused", arguments: ["512", "64M", "0"])
    func msizeOutOfRange(value: String) {
        #expect(throws: MountURLError.invalidOptionValue(option: "msize", value: value)) {
            try MountSpec.parse("9p://host/t?msize=\(value)")
        }
    }

    @Test("the dialect can be pinned")
    func version() throws {
        #expect(try MountSpec.parse("9p://host/t?version=9P2000.L").version == .v9P2000L)
        #expect(try MountSpec.parse("9p://host/t?version=u").version == .v9P2000u)
        #expect(try MountSpec.parse("9p://host/t?version=9P2000").version == .v9P2000)
        #expect(try MountSpec.parse("9p://host/t").version == nil)
        // Pinning a dialect means offering only that one.
        #expect(try MountSpec.parse("9p://host/t?version=L").makeSessionOptions().versions == [.v9P2000L])
        #expect(try MountSpec.parse("9p://host/t").makeSessionOptions().versions.count == 3)
    }

    @Test("an unrecognised dialect is refused rather than silently ignored")
    func badVersion() {
        #expect(throws: MountURLError.invalidOptionValue(option: "version", value: "9P3000")) {
            try MountSpec.parse("9p://host/t?version=9P3000")
        }
    }

    /// A typo in an option must not be silently dropped: a user who wrote
    /// `?read-only` believes the mount is read-only.
    @Test("an unknown option is an error")
    func unknownOption() {
        #expect(throws: MountURLError.unknownOption("read-only")) {
            try MountSpec.parse("9p://host/t?read-only")
        }
    }

    @Test("the fragment is ignored and does not leak into the query")
    func fragment() throws {
        let spec = try MountSpec.parse("9p://host/t#?bogus=1")
        #expect(spec.aname == "t")
    }

    @Test("volname renames the volume")
    func volumeNameOverride() throws {
        #expect(try MountSpec.parse("9p://host/t?volname=Work").volumeName == "Work")
    }

    // MARK: - Malformed input

    @Test("empty input")
    func empty() {
        #expect(throws: MountURLError.empty) { try MountSpec.parse("   ") }
    }

    @Test("something that is not a URL at all")
    func notAURL() {
        #expect(throws: MountURLError.notAURL("host:564")) { try MountSpec.parse("host:564") }
        #expect(throws: MountURLError.notAURL("/tmp/socket")) { try MountSpec.parse("/tmp/socket") }
    }

    @Test("a scheme we do not serve")
    func badScheme() {
        #expect(throws: MountURLError.unsupportedScheme("nfs")) {
            try MountSpec.parse("nfs://host/export")
        }
        #expect(throws: MountURLError.unsupportedScheme("http")) {
            try MountSpec.parse("http://host/")
        }
    }

    @Test("no host")
    func missingHost() {
        #expect(throws: MountURLError.missingHost) { try MountSpec.parse("9p:///tree") }
    }

    @Test("a port that is not a number, or not a port", arguments: ["abc", "0", "65536", "-1", ""])
    func badPort(port: String) {
        #expect(throws: MountURLError.invalidPort(port)) {
            try MountSpec.parse("9p://host:\(port)/tree")
        }
    }

    @Test("a unix URL with no socket path")
    func missingSocketPath() {
        #expect(throws: MountURLError.missingSocketPath) { try MountSpec.parse("9p+unix:///") }
        #expect(throws: MountURLError.missingSocketPath) { try MountSpec.parse("9p+unix://") }
    }

    // MARK: - Canonical target

    /// `fskitd` closes a container whose identifier it does not recognise, so
    /// the identifier — and therefore this string — must depend on the target
    /// and on nothing else.
    @Test("the canonical target ignores options, credentials and spelling")
    func canonicalTargetIsStable() throws {
        let a = try MountSpec.parse("9p://Host.Example:564/tree")
        let b = try MountSpec.parse("p9://host.example/tree?ro&uid=501&msize=64k")
        let c = try MountSpec.parse("9pfs://alice@HOST.example:564/tree?debug")
        #expect(a.canonicalTarget == b.canonicalTarget)
        #expect(b.canonicalTarget == c.canonicalTarget)
    }

    @Test("different trees on one server are different containers")
    func canonicalTargetDistinguishesTrees() throws {
        let a = try MountSpec.parse("9p://host/one")
        let b = try MountSpec.parse("9p://host/two")
        let c = try MountSpec.parse("9p://host:5640/one")
        #expect(a.canonicalTarget != b.canonicalTarget)
        #expect(a.canonicalTarget != c.canonicalTarget)
    }

    @Test("a volume name never contains a path separator or is empty")
    func volumeNameIsSafe() {
        #expect(MountSpec.sanitizeVolumeName("a/b:c") == "a-b-c")
        #expect(MountSpec.sanitizeVolumeName("   ") == "fs9kit")
        #expect(MountSpec.sanitizeVolumeName("") == "fs9kit")
        #expect(MountSpec.sanitizeVolumeName(String(repeating: "x", count: 300)).utf8.count == 255)
    }

    @Test("every advertised scheme parses")
    func everyAdvertisedSchemeParses() throws {
        for scheme in MountSpec.allSchemes {
            let text = MountSpec.unixSchemes.contains(scheme)
                ? "\(scheme):///tmp/s" : "\(scheme)://host/t"
            _ = try MountSpec.parse(text)
        }
    }
}

/// Pins the reason `p9://` is the scheme the documentation tells people to use.
///
/// `mount(8)` builds the resource with `[NSURL URLWithString:argv[0]]` before
/// the extension is reached, so whatever Foundation refuses to parse can never
/// get to our own parser however lenient that is. RFC 3986 says a scheme
/// begins with a letter, and Foundation enforces it — which rules out `9p`.
@Suite("URL scheme viability")
struct SchemeViabilityTests {
    @Test("Foundation rejects a scheme that starts with a digit")
    func digitLeadingSchemeIsInvalid() {
        #expect(URL(string: "9p://host:564/tree") == nil)
        #expect(URL(string: "9pfs://host/tree") == nil)
    }

    @Test("the schemes we tell people to type do parse")
    func documentedSchemesParse() throws {
        let tcp = try #require(URL(string: "p9://host:564/tree"))
        #expect(tcp.scheme == "p9")
        #expect(tcp.host == "host")
        #expect(tcp.port == 564)

        let unix = try #require(URL(string: "p9+unix:///tmp/ns/9p"))
        #expect(unix.scheme == "p9+unix")
        #expect(unix.path == "/tmp/ns/9p")
    }

    @Test("every advertised scheme is one our own parser accepts")
    func advertisedSchemesAreAccepted() throws {
        for scheme in MountSpec.allSchemes {
            let target = scheme.hasSuffix("+unix")
                ? "\(scheme):///tmp/ns/9p"
                : "\(scheme)://host:564/tree"
            #expect(throws: Never.self, "\(scheme) did not parse") {
                _ = try MountSpec.parse(target)
            }
        }
    }
}
