import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private var failures = 0
private var passes = 0

/// Repo root, passed as the first argument, for checks that load files from Tween/.
var repoRoot = "."

func check(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passes += 1
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

func expect(_ condition: Bool, _ message: String = "", line: UInt = #line) throws {
    if !condition { throw CheckFailure(description: "line \(line) \(message)") }
}

/// Each check file adds one entry here.
private let checkGroups: [() -> Void] = [
    amf0Checks,
    flvChecks,
    rtmpChunkChecks,
    rtmpConnectionChecks,
    videoEncoderChecks,
    streamAudioChecks,
    compositorChecks,
    broadcasterChecks,
]

@main
struct Checks {
    static func main() {
        if CommandLine.arguments.count > 1 { repoRoot = CommandLine.arguments[1] }
        for group in checkGroups { group() }
        if failures == 0 {
            print("all checks passed")
        } else {
            print("\(failures) of \(passes + failures) checks failed")
            exit(1)
        }
    }
}
