import Foundation

/// Plan GM P0 — Douglas–Peucker simplification of a route line down to a point cap, so the whole
/// route fits a glance surface (`RouteSnapshot.maxPoints`). The two endpoints and every index in
/// `keeping` (the maneuver points) always survive: the line is split at them and each piece is
/// simplified on its own, so a turn is never smoothed away.
///
/// The tolerance is searched, not fixed: the smallest tolerance whose result fits the cap. When
/// the kept points alone exceed the cap they are all returned — a turn matters more than the cap.
enum PolylineSimplifier {

    static func simplify(_ points: [GlancePoint], cap: Int = RouteSnapshot.maxPoints,
                         keeping: Set<Int> = []) -> [GlancePoint] {
        guard points.count > max(2, cap) else { return points }
        let forced = forcedIndices(count: points.count, keeping: keeping)
        if forced.count >= cap { return forced.sorted().map { points[$0] } }

        let projected = project(points)
        // Upper bound: the largest single deviation keeps only the forced points.
        var low = 0.0
        var high = maxDeviation(projected, forced: forced) + 1
        var best = selected(projected, forced: forced, tolerance: high)
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let attempt = selected(projected, forced: forced, tolerance: mid)
            if attempt.count <= cap {
                best = attempt
                high = mid
            } else {
                low = mid
            }
            if high - low < 0.01 { break }
        }
        return best.sorted().map { points[$0] }
    }

    // MARK: -

    private struct XY { let x: Double; let y: Double }

    private static func forcedIndices(count: Int, keeping: Set<Int>) -> Set<Int> {
        var forced: Set<Int> = [0, count - 1]
        for index in keeping where index >= 0 && index < count { forced.insert(index) }
        return forced
    }

    /// Metres in a local equirectangular plane — exact enough at route scale.
    private static func project(_ points: [GlancePoint]) -> [XY] {
        let origin = points[0]
        let cosLat = cos(origin.latitude * .pi / 180)
        let k = GlanceGeometry.earthRadius * .pi / 180
        return points.map {
            var dLon = $0.longitude - origin.longitude
            if dLon > 180 { dLon -= 360 }
            if dLon < -180 { dLon += 360 }
            return XY(x: dLon * k * cosLat, y: ($0.latitude - origin.latitude) * k)
        }
    }

    private static func perpendicular(_ p: XY, _ a: XY, _ b: XY) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot() }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let cx = a.x + t * dx, cy = a.y + t * dy
        return ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    }

    private static func maxDeviation(_ points: [XY], forced: Set<Int>) -> Double {
        let anchors = forced.sorted()
        var worst = 0.0
        for (a, b) in zip(anchors, anchors.dropFirst()) where b - a > 1 {
            for i in (a + 1)..<b { worst = max(worst, perpendicular(points[i], points[a], points[b])) }
        }
        return worst
    }

    /// The indices Douglas–Peucker keeps at `tolerance`, run separately between each pair of
    /// forced anchors. Iterative, so a long route cannot overflow the stack.
    private static func selected(_ points: [XY], forced: Set<Int>, tolerance: Double) -> Set<Int> {
        var keep = forced
        let anchors = forced.sorted()
        var stack: [(Int, Int)] = Array(zip(anchors, anchors.dropFirst()))
        while let span = stack.popLast() {
            let (a, b) = span
            guard b - a > 1 else { continue }
            var worstIndex = -1
            var worst = 0.0
            for i in (a + 1)..<b {
                let d = perpendicular(points[i], points[a], points[b])
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > tolerance, worstIndex >= 0 {
                keep.insert(worstIndex)
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return keep
    }
}
