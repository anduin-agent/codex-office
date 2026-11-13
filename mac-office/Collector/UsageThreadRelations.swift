import Foundation

struct UsageThreadRelation {
    enum Kind: String {
        case subagent
        case guardianReview = "guardian_review"
    }

    let kind: Kind
    let parent: String?
    let root: String?

    init(kind: Kind, parent: String? = nil, root: String? = nil) {
        self.kind = kind
        self.parent = parent
        self.root = root
    }

    init?(metadata: OfficeJSON) {
        let subtype = (metadata["source"] as? OfficeJSON)?["subagent"] as? OfficeJSON
        let spawn = subtype?["thread_spawn"] as? OfficeJSON
        let source = metadata["thread_source"] as? String
        let explicitParent = officeThreadID(metadata["parent_thread_id"]) ?? officeThreadID(spawn?["parent_thread_id"])
        let forked = officeThreadID(metadata["forked_from_id"]) != nil || officeThreadID(metadata["forked_from_session_id"]) != nil
        if source == Kind.guardianReview.rawValue || subtype?["other"] as? String == "guardian" {
            kind = .guardianReview
        } else if source == Kind.subagent.rawValue || subtype != nil || (explicitParent != nil && !forked) {
            kind = .subagent
        } else {
            return nil
        }
        parent = explicitParent
        // A rollout can explicitly give the root even when an intermediate agent's log is missing.
        root = explicitParent != nil || spawn != nil ? officeThreadID(metadata["session_id"]) : nil
    }

    func fillingMissingFields(from other: Self) -> Self {
        Self(kind: kind == .guardianReview ? kind : other.kind,
             parent: parent ?? other.parent, root: root ?? other.root)
    }
}
