#if canImport(XCTest)
import XCTest

// The Args struct lives in the ScreenMuseCLI executable target, which cannot be imported
// directly by a test target. We duplicate the struct here for unit testing.
// If the struct is ever moved to ScreenMuseCore, this copy can be removed.

private struct Args {
    let positional: [String]
    let flags: [String: String]
    let boolFlags: Set<String>

    init(_ args: [String]) {
        var pos: [String] = []
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count && !args[i+1].hasPrefix("--") {
                    flags[key] = args[i+1]
                    i += 2
                } else {
                    bools.insert(key)
                    i += 1
                }
            } else {
                pos.append(a)
                i += 1
            }
        }
        self.positional = pos
        self.flags = flags
        self.boolFlags = bools
    }

    subscript(_ key: String) -> String? { flags[key] }
    func has(_ key: String) -> Bool { boolFlags.contains(key) || flags[key] != nil }
    func bool(_ key: String) -> Bool { boolFlags.contains(key) }
}

final class CLIArgsTests: XCTestCase {

    // MARK: - Positional Arguments

    func testSinglePositionalArgument() {
        let args = Args(["start"])
        XCTAssertEqual(args.positional, ["start"])
        XCTAssertTrue(args.flags.isEmpty)
        XCTAssertTrue(args.boolFlags.isEmpty)
    }

    func testMultiplePositionalArguments() {
        let args = Args(["start", "recording"])
        XCTAssertEqual(args.positional, ["start", "recording"])
    }

    // MARK: - Key-Value Flags

    func testKeyValueFlag() {
        let args = Args(["start", "--name", "demo", "--quality", "high"])
        XCTAssertEqual(args.positional, ["start"])
        XCTAssertEqual(args.flags["name"], "demo")
        XCTAssertEqual(args.flags["quality"], "high")
    }

    func testSubscriptAccess() {
        let args = Args(["--port", "9000"])
        XCTAssertEqual(args["port"], "9000")
        XCTAssertNil(args["missing"])
    }

    // MARK: - Boolean Flags

    func testBooleanFlag() {
        let args = Args(["stop", "--json"])
        XCTAssertEqual(args.positional, ["stop"])
        XCTAssertTrue(args.boolFlags.contains("json"))
        XCTAssertTrue(args.bool("json"))
    }

    func testBooleanFlagBeforePositional() {
        let args = Args(["--verbose", "status"])
        XCTAssertTrue(args.bool("verbose"))
        XCTAssertEqual(args.positional, ["status"])
    }

    func testConsecutiveBooleanFlags() {
        let args = Args(["--json", "--verbose"])
        XCTAssertTrue(args.bool("json"))
        XCTAssertTrue(args.bool("verbose"))
        XCTAssertTrue(args.positional.isEmpty)
    }

    // MARK: - Mixed Arguments

    func testMixedFlagsAndPositional() {
        let args = Args(["--port", "9000", "status"])
        XCTAssertEqual(args.positional, ["status"])
        XCTAssertEqual(args.flags["port"], "9000")
    }

    func testComplexMixedArguments() {
        let args = Args(["start", "--name", "demo", "--json", "--quality", "high"])
        XCTAssertEqual(args.positional, ["start"])
        XCTAssertEqual(args.flags["name"], "demo")
        XCTAssertEqual(args.flags["quality"], "high")
        XCTAssertTrue(args.bool("json"))
    }

    // MARK: - has() Helper

    func testHasReturnsTrueForKeyValueFlag() {
        let args = Args(["--name", "demo"])
        XCTAssertTrue(args.has("name"))
    }

    func testHasReturnsTrueForBoolFlag() {
        let args = Args(["--json"])
        XCTAssertTrue(args.has("json"))
    }

    func testHasReturnsFalseForMissing() {
        let args = Args(["start"])
        XCTAssertFalse(args.has("missing"))
    }

    // MARK: - Empty Input

    func testEmptyArgs() {
        let args = Args([])
        XCTAssertTrue(args.positional.isEmpty)
        XCTAssertTrue(args.flags.isEmpty)
        XCTAssertTrue(args.boolFlags.isEmpty)
    }

    // MARK: - Edge Cases

    func testFlagAtEndWithNoValue() {
        let args = Args(["start", "--help"])
        XCTAssertEqual(args.positional, ["start"])
        XCTAssertTrue(args.bool("help"))
    }

    func testFlagFollowedByAnotherFlagTreatedAsBool() {
        // --foo --bar: --foo should be a bool flag, --bar should be a bool flag
        let args = Args(["--foo", "--bar"])
        XCTAssertTrue(args.bool("foo"))
        XCTAssertTrue(args.bool("bar"))
    }
}
#endif
