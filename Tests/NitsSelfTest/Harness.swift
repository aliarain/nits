import Foundation

final class Harness {
    private(set) var failures = 0
    private(set) var checks = 0
    private var group = ""

    func suite(_ name: String, _ body: () -> Void) {
        group = name
        print("\n▸ \(name)")
        body()
    }

    func check(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        checks += 1
        if condition {
            print("  ok   \(message())")
        } else {
            failures += 1
            print("  FAIL \(message())  [\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)]")
        }
    }

    func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        check(actual == expected, "\(message()): got \(actual), expected \(expected)", file: file, line: line)
    }

    func nilValue<T>(_ value: T?, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        check(value == nil, message(), file: file, line: line)
    }

    func approx(
        _ actual: Double,
        _ expected: Double,
        _ tolerance: Double,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        check(
            abs(actual - expected) <= tolerance,
            "\(message()): got \(actual), expected \(expected) ± \(tolerance)",
            file: file,
            line: line
        )
    }

    func finish() -> Never {
        print("\n\(checks) checks, \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}

let harness = Harness()
