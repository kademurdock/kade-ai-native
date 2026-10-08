import CoreGraphics
import XCTest
@testable import KadeAI

final class CharacterFigureArtworkTests: XCTestCase {
    private let kiana = CharacterMotion.kianaID

    private var samplePack: CharacterFigureArtwork {
        CharacterFigureArtwork(agentID: kiana, avatarFilename: CharacterMotion.kianaFile,
            farArm: "far", torso: "torso", head: "head", nearArm: "near",
            faceRect: CGRect(x: 0.34, y: 0.17, width: 0.5, height: 0.56),
            farShoulder: CharacterFigureJoint(x: 0.28, y: 0.48),
            waist: CharacterFigureJoint(x: 0.5, y: 0.78),
            neck: CharacterFigureJoint(x: 0.5, y: 0.35),
            nearShoulder: CharacterFigureJoint(x: 0.72, y: 0.48))
    }

    func testFigureRequiresTheExactPreparedAvatar() {
        let path = "/uploads/" + CharacterMotion.kianaFile
        XCTAssertTrue(samplePack.matches(agentID: kiana, avatarPath: path))
        XCTAssertFalse(samplePack.matches(agentID: CharacterMotion.dellaID, avatarPath: path))
        XCTAssertFalse(samplePack.matches(agentID: kiana, avatarPath: "/uploads/replaced.png"))
        XCTAssertNil(CharacterFigureArtwork.approved(agentID: kiana, avatarPath: path),
            "No unreviewed figure art may appear in the release stage")

        var invalid = samplePack
        invalid.backHair = ""
        XCTAssertFalse(invalid.isValid)
    }

    func testJointCoordinatesStayInTheCanvas() {
        XCTAssertFalse(CharacterFigureJoint(x: -0.01, y: 0.5).isValid)
        XCTAssertFalse(CharacterFigureJoint(x: 0.5, y: .infinity).isValid)
    }
}
