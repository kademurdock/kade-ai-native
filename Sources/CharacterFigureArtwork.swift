import Foundation
import SwiftUI

/// A point in the common square canvas of every transparent figure layer.
/// Authored pivots stay independent of the size used in chat or a call.
struct CharacterFigureJoint {
    let x: Double
    let y: Double

    var anchor: UnitPoint { UnitPoint(x: CGFloat(x), y: CGFloat(y)) }
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

/// One reviewed art pack. Core layers are transparent squares with identical
/// dimensions and alignment: far arm, torso, head, then near arm. Optional
/// locks sit behind and in front of those core layers, following the head's
/// neck joint. The head's neutral face must align with the complete 414 px
/// portrait panel placed in faceRect; expression, mouth, and blink patches use
/// their existing coordinates within that panel.
struct CharacterFigureArtwork {
    let agentID: String
    let avatarFilename: String
    let farArm: String
    let torso: String
    let head: String
    let nearArm: String
    var backHair: String?
    var frontHair: String?
    /// Square destination of the complete neutral portrait panel in the
    /// figure canvas, normalized to 0...1. This has the same meaning as the
    /// Android figure pack's faceRect, so one art manifest can serve both.
    let faceRect: CGRect
    let farShoulder: CharacterFigureJoint
    let waist: CharacterFigureJoint
    let neck: CharacterFigureJoint
    let nearShoulder: CharacterFigureJoint

    init(agentID: String, avatarFilename: String, farArm: String, torso: String,
         head: String, nearArm: String, faceRect: CGRect,
         farShoulder: CharacterFigureJoint, waist: CharacterFigureJoint,
         neck: CharacterFigureJoint, nearShoulder: CharacterFigureJoint,
         backHair: String? = nil, frontHair: String? = nil) {
        self.agentID = agentID
        self.avatarFilename = avatarFilename
        self.farArm = farArm
        self.torso = torso
        self.head = head
        self.nearArm = nearArm
        self.faceRect = faceRect
        self.farShoulder = farShoulder
        self.waist = waist
        self.neck = neck
        self.nearShoulder = nearShoulder
        self.backHair = backHair
        self.frontHair = frontHair
    }

    var isValid: Bool {
        !agentID.isEmpty && !avatarFilename.isEmpty &&
            ![farArm, torso, head, nearArm].contains(where: { $0.isEmpty }) &&
            (backHair.map { !$0.isEmpty } ?? true) && (frontHair.map { !$0.isEmpty } ?? true) &&
            [faceRect.minX, faceRect.minY, faceRect.width, faceRect.height].allSatisfy({ $0.isFinite }) &&
            faceRect.minX >= 0 && faceRect.minY >= 0 && faceRect.width > 0 && faceRect.height > 0 &&
            abs(faceRect.width - faceRect.height) <= 0.0001 &&
            faceRect.maxX <= 1 && faceRect.maxY <= 1 &&
            [farShoulder, waist, neck, nearShoulder].allSatisfy({ $0.isValid })
    }

    func matches(agentID id: String?, avatarPath path: String?) -> Bool {
        guard isValid, id == agentID, let path, let url = URL(string: path) else { return false }
        return url.lastPathComponent == avatarFilename && CharacterMotion.prepared(id: id, path: path)
    }

    /// Register a pack only after its likeness, alpha edges, joint placement,
    /// and atlas alignment have been reviewed. No figure art is approved yet.
    private static let approvedPacks: [CharacterFigureArtwork] = []

    static func approved(agentID: String?, avatarPath: String?) -> CharacterFigureArtwork? {
        approvedPacks.first { $0.matches(agentID: agentID, avatarPath: avatarPath) }
    }
}
