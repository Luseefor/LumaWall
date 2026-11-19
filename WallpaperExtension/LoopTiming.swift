import CoreMedia

/// Maps the renderer's looping timeline back to asset time. Each loop's
/// samples are enqueued shifted by the timeline time the loop starts at, so
/// the timeline keeps growing across loops while a reader seeks in asset
/// time (#27).
enum LoopTiming {
    struct ResumePoint: Equatable {
        /// Where the new reader starts in the asset.
        var assetTime: CMTime
        /// The timeline time of asset time 0 for that reader's samples.
        var loopStart: CMTime
    }

    /// Where to resume the frame at `timeline`. The feed reads ahead of the
    /// clock, so it may already have moved to the loop starting at
    /// `loopStart` while the previous loop's tail is still on screen.
    static func resumePoint(timeline: CMTime, loopStart: CMTime, previousLoopStart: CMTime) -> ResumePoint {
        let start = timeline >= loopStart ? loopStart : previousLoopStart
        return ResumePoint(assetTime: max(timeline - start, .zero), loopStart: start)
    }
}
