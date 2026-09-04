import Foundation

/// A single line-range comment attached to a diff review panel. See
/// docs/plans/diff-review-panel.md §4 for the line-numbering convention: comments always
/// address the new-file (right-hand/`+`) line numbers, including for context lines. For a pure
/// deletion (no corresponding new-file line), the UI anchors the comment to the nearest
/// preceding new-file line.
///
/// Comments are never dropped on a refresh, even when the file/line range they reference no
/// longer exists (file deleted, or the diff shrank) -- they are flagged `isStale` instead. See
/// `ReviewPanel.refresh()`.
struct ReviewComment: Identifiable, Codable, Equatable, Sendable {
    enum AdmissionError: Error, LocalizedError {
        case invalidComment
        case tooManyComments

        var errorDescription: String? {
            switch self {
            case .invalidComment:
                return String(localized: "review.comment.invalid", defaultValue: "Comment could not be added. Use a valid line range, a file path up to 16 KB, and nonempty text up to 64 KB.")
            case .tooManyComments:
                return String(localized: "review.comment.limit", defaultValue: "This review already has 2,048 comments. Send or remove comments before adding more.")
            }
        }
    }

    var isValidForPersistence: Bool {
        !filePath.isEmpty && filePath.utf8.count <= SessionPersistencePolicy.maxPathStringBytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= SessionPersistencePolicy.maxMetadataStringBytes
            && startLine >= 0 && endLine >= startLine
    }

    let id: UUID
    var filePath: String
    var startLine: Int
    var endLine: Int
    var text: String
    let createdAt: Date
    var isStale: Bool

    init(
        id: UUID = UUID(),
        filePath: String,
        startLine: Int,
        endLine: Int? = nil,
        text: String,
        createdAt: Date = Date(),
        isStale: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine ?? startLine
        self.text = text
        self.createdAt = createdAt
        self.isStale = isStale
    }
}
