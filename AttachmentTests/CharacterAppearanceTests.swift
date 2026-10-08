import XCTest
@testable import KadeAI

final class CharacterAppearanceTests: XCTestCase {
    func testDescriptionsFollowOnlyThePreparedPortraits() {
        let portraits: [(String, String)] = [
            (CharacterMotion.kianaID, CharacterMotion.kianaFile),
            (CharacterMotion.dellaID, CharacterMotion.dellaFile),
            (CharacterMotion.harleyID, CharacterMotion.harleyFile),
            (CharacterMotion.lillyID, CharacterMotion.lillyFile),
            (CharacterMotion.skyleeLillyID, CharacterMotion.skyleeLillyFile),
            (CharacterMotion.witherspoonID, CharacterMotion.witherspoonFile),
        ]
        for (id, filename) in portraits {
            XCTAssertNotNil(CharacterAppearance.description(agentID: id, avatarPath: "/images/" + filename))
            XCTAssertNil(CharacterAppearance.description(agentID: id, avatarPath: "/images/replaced.png"))
        }
        XCTAssertNil(CharacterAppearance.description(agentID: "another-agent",
            avatarPath: "/images/" + CharacterMotion.kianaFile))
    }
}
