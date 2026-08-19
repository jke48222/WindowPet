import XCTest
@testable import WindowPetCore

final class TerrainTests: XCTestCase {

    private func win(_ id: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat)
        -> (id: UInt32, frame: CGRect) {
        (id: id, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testSingleWindowAndFloor() {
        let p = Terrain.exposedPlatforms(windowsFrontToBack: [win(1, 100, 100, 600, 400)],
                                         floors: [CGRect(x: 0, y: 0, width: 1512, height: 982)])
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0], Platform(kind: .window(1), topY: 500, minX: 100, maxX: 700))
        XCTAssertEqual(p[1].kind, .floor)
        XCTAssertEqual(p[1].topY, 0)
    }

    func testFrontWindowSplitsBackWindowsTopEdge() {
        // Front window (id 1) straddles the middle of the back window's top edge.
        let front = win(1, 300, 350, 200, 300)   // covers y 350–650, x 300–500
        let back = win(2, 100, 100, 600, 400)    // top edge y=500, x 100–700
        let p = Terrain.exposedPlatforms(windowsFrontToBack: [front, back], floors: [])
        let backSegs = p.filter { $0.kind == .window(2) }
        XCTAssertEqual(backSegs.count, 2)
        XCTAssertEqual(backSegs[0].minX, 100); XCTAssertEqual(backSegs[0].maxX, 300)
        XCTAssertEqual(backSegs[1].minX, 500); XCTAssertEqual(backSegs[1].maxX, 700)
    }

    func testOccluderEntirelyBelowEdgeDoesNotOcclude() {
        // Front window's top is below the back window's top edge line.
        let front = win(1, 200, 100, 300, 350)   // maxY 450 < backTop-4
        let back = win(2, 100, 100, 600, 400)    // top 500
        let p = Terrain.exposedPlatforms(windowsFrontToBack: [front, back], floors: [])
        let backSegs = p.filter { $0.kind == .window(2) }
        XCTAssertEqual(backSegs.count, 1)
        XCTAssertEqual(backSegs[0].width, 600)
    }

    func testFullyCoveredWindowYieldsNoPlatform() {
        let front = win(1, 50, 50, 700, 500)
        let back = win(2, 100, 100, 600, 400)
        let p = Terrain.exposedPlatforms(windowsFrontToBack: [front, back], floors: [])
        XCTAssertTrue(p.filter { $0.kind == .window(2) }.isEmpty)
    }

    func testTinySlicesAreDiscarded() {
        // Occluder leaves a 10pt sliver — too narrow to stand on.
        let front = win(1, 110, 300, 600, 300)
        let back = win(2, 100, 100, 600, 400)
        let p = Terrain.exposedPlatforms(windowsFrontToBack: [front, back], floors: [])
        XCTAssertTrue(p.filter { $0.kind == .window(2) }.isEmpty)
    }

    func testLandingPicksHighestCrossedPlatformAtX() {
        let platforms = [
            Platform(kind: .window(1), topY: 400, minX: 100, maxX: 500),
            Platform(kind: .window(2), topY: 250, minX: 0, maxX: 800),
            Platform(kind: .floor, topY: 0, minX: 0, maxX: 1512),
        ]
        // Falling from 600 to 200 at x=300: crosses 400 and 250 — land on 400.
        let hit = Terrain.landingPlatform(in: platforms, x: 300, fromY: 600, toY: 200)
        XCTAssertEqual(hit?.topY, 400)
        // At x=700 window 1 is out of span: land on 250.
        XCTAssertEqual(Terrain.landingPlatform(in: platforms, x: 700, fromY: 600, toY: 200)?.topY, 250)
        // Nothing crossed yet: nil.
        XCTAssertNil(Terrain.landingPlatform(in: platforms, x: 300, fromY: 600, toY: 450))
    }
}
