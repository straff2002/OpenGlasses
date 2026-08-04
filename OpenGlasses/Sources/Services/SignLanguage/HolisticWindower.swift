import Foundation

/// Canonical MediaPipe Holistic landmark layout the fingerspelling CTC model was trained on
/// (Plan CK P2): 543 landmarks per frame in the fixed order face 0–467, left hand 468–488,
/// pose 489–521, right hand 522–542. A part that isn't detected in a frame is NaN — the
/// windower's cleaning steps depend on that convention.
enum HolisticLayout {
    static let faceRange = 0..<468
    static let leftHandRange = 468..<489
    static let poseRange = 489..<522
    static let rightHandRange = 522..<543
    static let landmarkCount = 543
    /// 543 landmarks × xyz.
    static let featuresPerFrame = landmarkCount * 3

    /// Horizontal-mirror source table: when a clip is mirrored (left-handed signer),
    /// output landmark `i` takes the x-flipped value of input landmark `mirrorSource[i]` —
    /// left/right symmetric pairs (face halves, hands, pose sides) swap, centreline
    /// landmarks keep their own value. Generated from the training pipeline's LEFT/RIGHT
    /// correspondence tables; `HolisticWindowerTests` asserts it is a self-inverse
    /// permutation with the hand blocks fully swapped.
    static let mirrorSource: [Int] = [
        0, 1, 2, 248, 4, 5, 6, 249, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 250, 251, 252,
        253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270,
        271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288,
        289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306,
        307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 321, 322, 323, 94,
        324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341,
        342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359,
        360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377,
        378, 379, 151, 152, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 164, 391, 392,
        393, 168, 394, 395, 396, 397, 398, 399, 175, 400, 401, 402, 403, 404, 405, 406, 407, 408,
        409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 195, 419, 197, 420, 199, 200, 421, 422,
        423, 424, 425, 426, 427, 428, 429, 430, 431, 432, 433, 434, 435, 436, 437, 438, 439, 440,
        441, 442, 443, 444, 445, 446, 447, 448, 449, 450, 451, 452, 453, 454, 455, 456, 457, 458,
        459, 460, 461, 462, 463, 464, 465, 466, 467, 3, 7, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
        51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72,
        73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 95,
        96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113,
        114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131,
        132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
        150, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 165, 166, 167, 169, 170, 171,
        172, 173, 174, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190,
        191, 192, 193, 194, 196, 198, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212,
        213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230,
        231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 522,
        523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 534, 535, 536, 537, 538, 539, 540,
        541, 542, 489, 493, 494, 495, 490, 491, 492, 497, 496, 499, 498, 501, 500, 503, 502, 505,
        504, 507, 506, 509, 508, 511, 510, 513, 512, 515, 514, 517, 516, 519, 518, 521, 520, 468,
        469, 470, 471, 472, 473, 474, 475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486,
        487, 488
    ]
}

/// One timestamped set of holistic landmarks in `HolisticLayout` order (normalised image
/// coordinates; NaN where a part wasn't detected).
struct HolisticFrame: Equatable {
    var timestamp: TimeInterval
    /// Exactly `HolisticLayout.landmarkCount` points.
    var points: [SIMD3<Float>]

    /// True when every coordinate of every landmark is NaN — i.e. nothing was detected.
    /// These frames are dropped from the model window (the live decoder counts them as
    /// blank time instead).
    var isAllNaN: Bool {
        !points.contains { $0.x.isFinite || $0.y.isFinite || $0.z.isFinite }
    }

    /// Canonical assembly from per-part landmark arrays (plain values, so the landmark
    /// backend stays behind its seam): NaN wherever a part is missing or undersized (a
    /// malformed part must not partially fill its block). `face` may carry more than 468
    /// points (the tasks-API face landmarker appends iris landmarks) — only the training
    /// contract's first 468 are used.
    static func assembled(face: [SIMD3<Float>],
                          leftHand: [SIMD3<Float>],
                          pose: [SIMD3<Float>],
                          rightHand: [SIMD3<Float>],
                          timestamp: TimeInterval) -> HolisticFrame {
        var points = [SIMD3<Float>](repeating: SIMD3(x: .nan, y: .nan, z: .nan),
                                    count: HolisticLayout.landmarkCount)
        func fill(_ range: Range<Int>, from landmarks: [SIMD3<Float>]) {
            guard landmarks.count >= range.count else { return }
            for (slot, landmark) in zip(range, landmarks.prefix(range.count)) {
                points[slot] = landmark
            }
        }
        fill(HolisticLayout.faceRange, from: face)
        fill(HolisticLayout.leftHandRange, from: leftHand)
        fill(HolisticLayout.poseRange, from: pose)
        fill(HolisticLayout.rightHandRange, from: rightHand)
        return HolisticFrame(timestamp: timestamp, points: points)
    }
}

/// Pure feature pipeline for the fingerspelling CTC model (Plan CK P2), reproducing the
/// training preprocessing exactly — the golden-fixture tests hold it to the Python
/// reference. Per window (≤ 768 frames, all-NaN frames already dropped):
///
/// 1. handedness vote over the whole window (fewer NaN scalars in the left-hand block than
///    the right → left-handed) → horizontal mirror (x → 1−x plus the left/right landmark
///    swap in `HolisticLayout.mirrorSource`);
/// 2. per-window standardisation: one mean and std per coordinate channel over every
///    finite value (mean falls back to (0.5, 0.5, 0) when a channel is all-NaN; no epsilon
///    on std — a zero/NaN std yields non-finite values that the NaN→0 step cleans, exactly
///    like the reference);
/// 3. flatten landmark-major to 1629 features per frame, NaN → 0;
/// 4. zero-pad to 768 frames + float validity mask (the converted model's fixed window).
///
/// No MediaPipe, no Core ML, no clock: fixture-testable end to end.
enum HolisticWindower {

    /// The converted model's fixed window length.
    static let windowLength = 768

    /// One model invocation's input: flat row-major buffers sized for the fixed window.
    struct ModelInput: Equatable {
        /// `windowLength × featuresPerFrame`, zero-padded past `frameCount`.
        var features: [Float]
        /// `windowLength` — 1 for real frames, 0 for padding.
        var mask: [Float]
        /// Real (unpadded) frame count T; the decoder reads ⌈T/2⌉ logit rows.
        var frameCount: Int
    }

    /// Whole-window handedness vote: NaN scalar count over the left-hand block vs the
    /// right-hand block (fewer NaNs on the left = the left hand is the signing hand).
    static func isLeftHanded(_ frames: [HolisticFrame]) -> Bool {
        var leftNaNs = 0, rightNaNs = 0
        for frame in frames {
            guard frame.points.count == HolisticLayout.landmarkCount else { continue }
            for index in HolisticLayout.leftHandRange {
                let p = frame.points[index]
                leftNaNs += (p.x.isNaN ? 1 : 0) + (p.y.isNaN ? 1 : 0) + (p.z.isNaN ? 1 : 0)
            }
            for index in HolisticLayout.rightHandRange {
                let p = frame.points[index]
                rightNaNs += (p.x.isNaN ? 1 : 0) + (p.y.isNaN ? 1 : 0) + (p.z.isNaN ? 1 : 0)
            }
        }
        return leftNaNs < rightNaNs
    }

    /// Horizontal mirror of one frame: x → 1−x on every landmark, then the left/right
    /// symmetric-pair swap.
    static func mirrored(_ frame: HolisticFrame) -> HolisticFrame {
        guard frame.points.count == HolisticLayout.landmarkCount else { return frame }
        var mirrored = frame
        mirrored.points = HolisticLayout.mirrorSource.map { source in
            let p = frame.points[source]
            return SIMD3(x: 1 - p.x, y: p.y, z: p.z)
        }
        return mirrored
    }

    /// Normalise a window (≤ `windowLength` non-all-NaN frames, malformed frames dropped)
    /// to its per-frame 1629-feature rows. Extraction of steps 1–3 above; `modelInput(for:)`
    /// adds the padding + mask.
    static func features(for frames: [HolisticFrame]) -> [[Float]] {
        let window = Array(
            frames.lazy
                .filter { $0.points.count == HolisticLayout.landmarkCount && !$0.isAllNaN }
                .prefix(windowLength)
        )
        guard !window.isEmpty else { return [] }

        let oriented = isLeftHanded(window) ? window.map(mirrored) : window

        // Per-channel mean/std over every finite value in the window (accumulated in
        // Double — the reference reduces in float32, so fixture comparison carries a small
        // tolerance).
        var sum = SIMD3<Double>(), count = SIMD3<Double>()
        for frame in oriented {
            for p in frame.points {
                if !p.x.isNaN { sum.x += Double(p.x); count.x += 1 }
                if !p.y.isNaN { sum.y += Double(p.y); count.y += 1 }
                if !p.z.isNaN { sum.z += Double(p.z); count.z += 1 }
            }
        }
        let fallback = SIMD3<Double>(0.5, 0.5, 0)
        var mean = sum / count // 0/0 = NaN when a channel has no data
        mean = SIMD3(x: mean.x.isNaN ? fallback.x : mean.x,
                     y: mean.y.isNaN ? fallback.y : mean.y,
                     z: mean.z.isNaN ? fallback.z : mean.z)

        var squaredSum = SIMD3<Double>()
        for frame in oriented {
            for p in frame.points {
                if !p.x.isNaN { let d = Double(p.x) - mean.x; squaredSum.x += d * d }
                if !p.y.isNaN { let d = Double(p.y) - mean.y; squaredSum.y += d * d }
                if !p.z.isNaN { let d = Double(p.z) - mean.z; squaredSum.z += d * d }
            }
        }
        let std = SIMD3(x: (squaredSum.x / count.x).squareRoot(),
                        y: (squaredSum.y / count.y).squareRoot(),
                        z: (squaredSum.z / count.z).squareRoot())

        return oriented.map { frame in
            var row = [Float]()
            row.reserveCapacity(HolisticLayout.featuresPerFrame)
            for p in frame.points {
                let x = (Double(p.x) - mean.x) / std.x
                let y = (Double(p.y) - mean.y) / std.y
                let z = (Double(p.z) - mean.z) / std.z
                row.append(x.isFinite ? Float(x) : 0)
                row.append(y.isFinite ? Float(y) : 0)
                row.append(z.isFinite ? Float(z) : 0)
            }
            return row
        }
    }

    /// Full pipeline: window frames → fixed-length model input (nil when no usable frames).
    static func modelInput(for frames: [HolisticFrame]) -> ModelInput? {
        let rows = features(for: frames)
        guard !rows.isEmpty else { return nil }

        var features = [Float](repeating: 0,
                               count: windowLength * HolisticLayout.featuresPerFrame)
        var mask = [Float](repeating: 0, count: windowLength)
        for (frameIndex, row) in rows.enumerated() {
            let offset = frameIndex * HolisticLayout.featuresPerFrame
            features.replaceSubrange(offset..<(offset + row.count), with: row)
            mask[frameIndex] = 1
        }
        return ModelInput(features: features, mask: mask, frameCount: rows.count)
    }
}
