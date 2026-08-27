import XCTest
@testable import WindowPetCore

final class ShimejiTests: XCTestCase {

    private let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Mascot xmlns="http://www.group-finity.com/Mascot">
      <ActionList>
        <Action Name="Stand" Type="Stay" BorderType="Floor">
          <Animation>
            <Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" />
          </Animation>
        </Action>
        <Action Name="Walk" Type="Move" BorderType="Floor">
          <Animation>
            <Pose Image="/shime1.png" Velocity="-2,0" Duration="6" />
            <Pose Image="/shime2.png" Velocity="-2,0" Duration="6" />
            <Pose Image="/shime3.png" Velocity="-2,0" Duration="6" />
          </Animation>
        </Action>
        <Action Name="Falling" Type="Embedded"
                Class="com.group_finity.mascot.action.Fall">
          <Animation>
            <Pose Image="/shime4.png" Duration="4" />
          </Animation>
        </Action>
        <Action Name="Bouncing" Type="Embedded"
                Class="com.group_finity.mascot.action.Bouncing">
          <Animation>
            <Pose Image="/shime18.png" Duration="2" />
            <Pose Image="/shime19.png" Duration="2" />
          </Animation>
        </Action>
        <Action Name="Pinched" Type="Embedded"
                Class="com.group_finity.mascot.action.Dragged">
          <Animation>
            <Pose Image="/shime5.png" Duration="2" />
          </Animation>
        </Action>
        <Action Name="ChaseMouse" Type="Sequence">
          <ActionReference Name="Walk" />
        </Action>
      </ActionList>
    </Mascot>
    """

    func testParserExtractsActionsAndPoses() {
        let actions = ShimejiActionsParser.parse(xml: Data(fixture.utf8))
        XCTAssertEqual(actions["stand"]?.count, 1)
        XCTAssertEqual(actions["stand"]?.first, ShimejiPose(image: "/shime1.png", durationTicks: 250))
        XCTAssertEqual(actions["walk"]?.count, 3)
        XCTAssertEqual(actions["walk"]?[1].image, "/shime2.png")
        XCTAssertEqual(actions["falling"]?.first?.image, "/shime4.png")
        XCTAssertEqual(actions["bouncing"]?.count, 2)
        XCTAssertNil(actions["chasemouse"], "reference-only actions have no poses")
    }

    func testMappingSelectsAndFallsBack() {
        let actions = ShimejiActionsParser.parse(xml: Data(fixture.utf8))
        let m = ShimejiMapping.select(from: actions)
        XCTAssertEqual(m["idle"]?.first?.image, "/shime1.png")
        XCTAssertEqual(m["walk"]?.count, 3)
        XCTAssertEqual(m["fall"]?.first?.image, "/shime4.png")
        XCTAssertEqual(m["land"]?.count, 2)
        XCTAssertEqual(m["jump"]?.first?.image, "/shime5.png", "jump prefers Pinched (dangle)")
        XCTAssertEqual(m["sleep"]?.first?.image, "/shime1.png", "no Sit/Lie → idle fallback")
        XCTAssertEqual(m["blink"]?.first?.image, "/shime1.png")
    }

    func testMappingSurvivesMinimalPack() {
        let minimal = ShimejiActionsParser.parse(xml: Data("""
        <Mascot><ActionList>
          <Action Name="Stand"><Animation><Pose Image="/a.png" Duration="10"/></Animation></Action>
        </ActionList></Mascot>
        """.utf8))
        let m = ShimejiMapping.select(from: minimal)
        for kind in ["idle", "walk", "fall", "land", "jump", "sleep", "blink"] {
            XCTAssertEqual(m[kind]?.first?.image, "/a.png", kind)
        }
    }
}
