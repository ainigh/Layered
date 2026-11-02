import XCTest
@testable import Harness

/// How much Fill the view zooms in on a set of maps, for tuning `Spread`. Skipped unless
/// `SPREAD_BENCH=1`; run it in release:
///
///     SPREAD_BENCH=1 swift test -c release --filter SpreadBenchTests
final class SpreadBenchTests: XCTestCase {
    func maps() throws -> [(String, MapLayout)] {
        var out: [(String, MapLayout)] = []
        out.append(("hub14", MapLayout.compute(try Compiler.compile((1...14).map { "| hub - has | child \($0)" }.joined(separator: "\n")))))
        for which in [Demo.Map.typical, .large] { out.append(("\(which)", MapLayout.compute(MapLayout.unpinned(Demo.state(which).graph)))) }
        var lines: [String] = []
        for t in 1...4 {
            lines.append("| root \(t) - has | a\(t)")
            lines.append("| root \(t) - has | b\(t)")
            for k in 1...4 { lines.append("| a\(t) - has | a\(t) leaf \(k)") }
            for k in 1...3 { lines.append("| b\(t) - has | b\(t) leaf \(k)") }
        }
        lines.append("| a1 leaf 2 - see also | b3 leaf 1")
        lines.append("| b2 - see also | a4")
        out.append(("forest", MapLayout.compute(try Compiler.compile(lines.joined(separator: "\n")))))
        // Trees grown at random (the same every run): each node hangs from an earlier one.
        var seed: UInt64 = 7
        func pick(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for count in [40, 90] {
            _ = (1..<count).map { _ in pick(12) }
            out.append(("rand\(count)", MapLayout.compute(try Compiler.compile((1..<count).map { "| n\(pick($0)) - has | n\($0)" }.joined(separator: "\n")))))
        }
        return out
    }

    func testGains() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPREAD_BENCH"] != nil, "set SPREAD_BENCH=1 to run")
        var total = 0.0, runs = 0.0
        for (name, map) in try maps() {
            for view in [(1200.0, 700.0), (700.0, 1100.0)] {
                var spread = Spread(layout: map, viewWidth: view.0, viewHeight: view.1, gap: 24)
                let before = spread.zoom, start = Date()
                spread.run()
                total += log(spread.zoom / before)
                runs += 1
                print(String(format: "%-8@ %4.0f×%-4.0f zoom ×%.2f  %4d steps  %.2f s", name as NSString, view.0, view.1,
                             spread.zoom / before, spread.steps, Date().timeIntervalSince(start)))
            }
        }
        print(String(format: "geometric mean zoom ×%.3f", exp(total / runs)))
    }
}
