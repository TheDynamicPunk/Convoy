import Foundation

/// Changing the order of the category list. Order is priority: when a file
/// fits two categories, the one nearer the top takes it, so moving a category
/// is how a person decides which wins.
///
/// Pure, and the only place that knows what "can move" means. The Move Up
/// and Move Down menu items ask `canMove` whether to be enabled and call
/// `moved(_:_:in:)` to act, so an item can never be live for a move that
/// would do nothing. Dragging a row onto another uses `moved(_:onto:in:)`,
/// and the line drawn while dragging comes from `dropSide`, which shares its
/// indices with that move so the two cannot disagree.
public enum CategoryOrdering {

    public enum Direction: Sendable {
        case up
        case down
    }

    /// Whether `id` has a neighbour to swap with in that direction.
    public static func canMove(
        _ id: UUID,
        _ direction: Direction,
        in categories: [DownloadCategory]
    ) -> Bool {
        target(of: id, direction, in: categories) != nil
    }

    /// The list with `id` swapped one place up or down. Returned unchanged
    /// when `id` is not in the list or is already at that end.
    public static func moved(
        _ id: UUID,
        _ direction: Direction,
        in categories: [DownloadCategory]
    ) -> [DownloadCategory] {
        guard let from = categories.firstIndex(where: { $0.id == id }),
              let to = target(of: id, direction, in: categories)
        else { return categories }
        var result = categories
        result.swapAt(from, to)
        return result
    }

    /// Which edge of the target row a dragged row will end up against.
    public enum DropSide: Sendable {
        case above
        case below
    }

    /// Dropping a row onto another puts it where that one is, and everything
    /// in between shifts one place. So dragging down lands the row just
    /// below the one it was dropped on, and dragging up lands it just above.
    /// Returned unchanged when either id is unknown or they are the same row.
    public static func moved(
        _ id: UUID,
        onto targetID: UUID,
        in categories: [DownloadCategory]
    ) -> [DownloadCategory] {
        guard id != targetID,
              let from = categories.firstIndex(where: { $0.id == id }),
              let to = categories.firstIndex(where: { $0.id == targetID })
        else { return categories }
        var result = categories
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// The edge to draw the drop indicator on. Answered from the same indices
    /// `moved(_:onto:in:)` uses, so the line shown while dragging cannot
    /// disagree with where the row actually lands. Nil when a drop would do
    /// nothing.
    public static func dropSide(
        of id: UUID,
        onto targetID: UUID,
        in categories: [DownloadCategory]
    ) -> DropSide? {
        guard id != targetID,
              let from = categories.firstIndex(where: { $0.id == id }),
              let to = categories.firstIndex(where: { $0.id == targetID })
        else { return nil }
        return from < to ? .below : .above
    }

    private static func target(
        of id: UUID,
        _ direction: Direction,
        in categories: [DownloadCategory]
    ) -> Int? {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return nil }
        let destination = direction == .up ? index - 1 : index + 1
        return categories.indices.contains(destination) ? destination : nil
    }
}
