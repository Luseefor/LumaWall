import CryptoKit
import Foundation
import XCTest
@testable import LumaWall

private typealias Deployment = NativeWallpaperDeployment
private typealias Queue = NativeWallpaperDeployment.VariantEncodeQueue

/// What the stand-in encoder was given.
private final class SourceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var bytes: [Data] = []
    var sources: [URL] { lock.withLock { urls } }
    var contents: [Data] { lock.withLock { bytes } }

    func record(_ url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        lock.withLock {
            urls.append(url)
            bytes.append(data)
        }
    }
}

/// Copy encodes read the deployed video from a private copy, never in place
/// in the extension's container, where it could be a symlink to a user file.
final class TranscodeSourceTests: XCTestCase {
    private var root: URL!
    private var entry: URL { root.appendingPathComponent("videos/E") }
    private var deployed: URL { entry.appendingPathComponent("Wallpaper.mov") }
    private var sources: Deployment.TranscodeSources!
    private let bytes = Data("published bytes".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        sources = Deployment.TranscodeSources(folderURL: root.appendingPathComponent("private"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func job(_ filename: String = "Wallpaper.minimal.mov", hash: String? = nil) -> Queue.Job {
        let spec = Deployment.variantSpecs(sourceSize: CGSize(width: 3840, height: 2160), sourceFPS: 30)
            .first { $0.filename == filename }!
        return Queue.Job(entryID: "E", sourceURL: deployed, contentHash: hash ?? self.hash(bytes), spec: spec)
    }

    private func privateFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: sources.folderURL.path)) ?? []
    }

    private func export(_ job: Queue.Job, log: SourceLog) async -> Deployment.TranscodeResult {
        await Deployment.exportCopy(job, sources: sources) { url in
            log.record(url)
            return .finished
        }
    }

    func testEncodesFromOnePrivateCopyOfThePublishedBytes() async throws {
        try bytes.write(to: deployed)
        let log = SourceLog()
        let first = await export(job("Wallpaper.minimal.mov"), log: log)
        let second = await export(job("Wallpaper.reduced.mov"), log: log)
        XCTAssertEqual([first, second], [.finished, .finished])
        XCTAssertEqual(log.contents, [bytes, bytes])
        XCTAssertEqual(Set(log.sources).count, 1, "one copy per source, not per job")
        let source = try XCTUnwrap(log.sources.first)
        XCTAssertEqual(source.deletingLastPathComponent().standardizedFileURL, sources.folderURL.standardizedFileURL)
        XCTAssertEqual(source.pathExtension, "mov")

        sources.release(job())
        XCTAssertEqual(privateFiles(), [])
    }

    func testASymlinkedDeployedVideoIsNeverRead() async throws {
        // The target has the published bytes, so a copy that followed the
        // link would pass the hash check; only refusing the link stops it.
        let userFile = root.appendingPathComponent("user-file.mov")
        try bytes.write(to: userFile)
        try FileManager.default.createSymbolicLink(at: deployed, withDestinationURL: userFile)
        let log = SourceLog()
        let result = await export(job(), log: log)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(log.sources, [])
        XCTAssertEqual(privateFiles(), [])
    }

    func testASourceThatNoLongerMatchesItsHashEncodesNothing() async throws {
        try Data("swapped bytes".utf8).write(to: deployed)
        let log = SourceLog()
        let result = await export(job(), log: log)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(log.sources, [])
        XCTAssertEqual(privateFiles(), [])
    }

    func testAnotherSourceReplacesTheKeptCopy() async throws {
        try bytes.write(to: deployed)
        let log = SourceLog()
        _ = await export(job(), log: log)
        let other = Data("other source".utf8)
        try other.write(to: deployed)
        _ = await export(job(hash: hash(other)), log: log)
        XCTAssertEqual(log.contents, [bytes, other])
        XCTAssertEqual(privateFiles().count, 1)
    }

    func testStartupCleanupRemovesLeftoverCopies() throws {
        try FileManager.default.createDirectory(at: sources.folderURL, withIntermediateDirectories: true)
        try Data("left".utf8).write(to: sources.folderURL.appendingPathComponent("old.mov"))
        sources.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.folderURL.path))
    }

    /// The queue wired as the app wires it: encodes go through
    /// `exportCopy`, and the queue releases each source when done with it.
    private func queue(outcome: Queue.Outcome, waitForCancel: Bool = false, log: SourceLog) -> Queue {
        let sources = self.sources!
        return Queue(
            readiness: { _ in .ready(rank: 0) },
            encode: { job in
                let result = await Deployment.exportCopy(job, sources: sources) { url in
                    log.record(url)
                    while waitForCancel, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                    return waitForCancel ? .skipped : .finished
                }
                return result == .finished ? outcome : .notNow
            },
            finishedSource: { sources.release($0) })
    }

    func testThePrivateCopyIsRemovedAfterSuccessAndFailure() async throws {
        try bytes.write(to: deployed)
        for outcome in [Queue.Outcome.done, .failed] {
            let log = SourceLog()
            let queue = queue(outcome: outcome, log: log)
            await queue.enqueue([job("Wallpaper.minimal.mov"), job("Wallpaper.reduced.mov")])
            await queue.drained()
            XCTAssertEqual(log.contents, [bytes, bytes], "\(outcome)")
            XCTAssertEqual(Set(log.sources).count, 1, "\(outcome)")
            XCTAssertEqual(privateFiles(), [], "\(outcome)")
        }
    }

    func testThePrivateCopyIsRemovedWhenTheWallpaperIsRemoved() async throws {
        try bytes.write(to: deployed)
        let log = SourceLog()
        let queue = queue(outcome: .done, waitForCancel: true, log: log)
        await queue.enqueue([job()])
        for _ in 0..<5_000 where log.sources.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(privateFiles().count, 1)
        await queue.cancel(entryID: "E")
        await queue.drained()
        XCTAssertEqual(privateFiles(), [])
    }
}
