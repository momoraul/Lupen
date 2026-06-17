import Foundation

/// Class wrapper around the value-typed Turn / Step / SkillGroup so
/// they can be used as NSOutlineView items (which require AnyObject).
///
/// `identityKey` is `kind:sessionId:...localKey`; the kind prefix
/// disambiguates the rare case of a UUID colliding between a Turn
/// and a Step.
final class TurnOutlineNode: NSObject {

    enum Kind {
        case turn(Turn)
        case skillGroup(SkillGroupBuilder.SkillGroup, sessionId: String, parentTurnId: String)
        case step(Step, parentTurnId: String)
        /// Sub-agent invocation grafted under the parent's Agent Step.
        /// `link` carries display metadata (agentType + description) and
        /// `turn` is the sub-agent's full conversation. Children are the
        /// sub-agent's Steps so the user can expand to read what the
        /// sub-agent actually did. The grafting parent context
        /// (`parentTurnId` + `parentStepUuid`) keeps the identity key
        /// disambiguated when the same sub-agent is referenced from
        /// multiple potential paths (defensive — current data flow can't
        /// produce that, but future Agent tool_use id reuse would).
        case subAgent(
            link: SubAgentLinker.Link,
            turn: Turn,
            parentTurnId: String,
            parentStepUuid: String
        )
    }

    let kind: Kind

    init(turn: Turn) {
        self.kind = .turn(turn)
        super.init()
    }

    init(skillGroup: SkillGroupBuilder.SkillGroup, sessionId: String, parentTurnId: String) {
        self.kind = .skillGroup(skillGroup, sessionId: sessionId, parentTurnId: parentTurnId)
        super.init()
    }

    init(step: Step, parentTurnId: String) {
        self.kind = .step(step, parentTurnId: parentTurnId)
        super.init()
    }

    init(
        subAgentLink link: SubAgentLinker.Link,
        turn: Turn,
        parentTurnId: String,
        parentStepUuid: String
    ) {
        self.kind = .subAgent(
            link: link,
            turn: turn,
            parentTurnId: parentTurnId,
            parentStepUuid: parentStepUuid
        )
        super.init()
    }

    var identityKey: String {
        switch kind {
        case .turn(let t):
            return "turn:\(t.sessionId):\(t.id)"
        case .skillGroup(let g, let sid, let tid):
            return "skillGroup:\(sid):\(tid):\(g.id)"
        case .step(let s, let tid):
            return "step:\(s.sessionId):\(tid):\(s.uuid)"
        case .subAgent(let link, let turn, let parentTurnId, let parentStepUuid):
            return "subAgent:\(turn.sessionId):\(parentTurnId):\(parentStepUuid):\(link.agentId)"
        }
    }

    var isTurn: Bool {
        if case .turn = kind { return true }
        return false
    }

    var turn: Turn? {
        if case .turn(let t) = kind { return t }
        return nil
    }

    var skillGroup: SkillGroupBuilder.SkillGroup? {
        if case .skillGroup(let g, _, _) = kind { return g }
        return nil
    }

    var step: Step? {
        if case .step(let s, _) = kind { return s }
        return nil
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TurnOutlineNode else { return false }
        return identityKey == other.identityKey
    }

    override var hash: Int { identityKey.hashValue }
}
