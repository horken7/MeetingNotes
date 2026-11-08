import Foundation
import Testing
@testable import MeetingCore

@Suite struct ModelsTests {
    @Test func bestAvailableSpeechModel() {
        let none: (ModelFile) -> Bool = { Catalog.builtIn.contains($0) }
        #expect(Catalog.speechModel(for: .swedish, isReady: none) == Catalog.whisperSmall)
        #expect(Catalog.speechModel(for: .english, isReady: none) == Catalog.whisperSmall)
        let kb: (ModelFile) -> Bool = { none($0) || $0 == Catalog.kbWhisperMedium }
        #expect(Catalog.speechModel(for: .swedish, isReady: kb) == Catalog.kbWhisperMedium)
        #expect(Catalog.speechModel(for: .danish, isReady: kb) == Catalog.whisperSmall)
        #expect(Catalog.speechModel(for: .swedish, isReady: { _ in true }) == Catalog.kbWhisperLarge)
        #expect(Catalog.recommendedDownload(for: .swedish) == Catalog.kbWhisperMedium)
        #expect(Catalog.recommendedDownload(for: .automatic) == nil)
    }

    @Test func notesModelByMemoryAndDownloads() {
        let sixGB: UInt64 = 6 * 1024 * 1024 * 1024, eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        #expect(Catalog.notesModel(physicalMemory: eightGB, isReady: { _ in false }) == Catalog.gemma1b)
        #expect(Catalog.notesModel(physicalMemory: sixGB, isReady: { _ in true }) == Catalog.gemma1b)
        #expect(Catalog.notesModel(physicalMemory: eightGB, isReady: { _ in true }) == Catalog.gemma4b)
        #expect(!Catalog.fits(Catalog.gemma4b, physicalMemory: sixGB))
        #expect(Catalog.fits(Catalog.kbWhisperLarge, physicalMemory: sixGB))
    }

    @Test func builtInSetStaysSmall() {
        let total = Catalog.builtIn.reduce(0) { $0 + $1.bytes }
        #expect(total < 1_100_000_000)
        #expect(Set(Catalog.builtIn).isDisjoint(with: Catalog.optional))
    }

    @Test func catalogIsConsistent() {
        #expect(Set(Catalog.all.map(\.id)).count == Catalog.all.count)
        #expect(Set(Catalog.all.map(\.fileName)).count == Catalog.all.count)
        #expect(Catalog.all.allSatisfy { $0.url.scheme == "https" && $0.bytes > 0 })
        #expect(Catalog.byID("gemma3-4b") == Catalog.gemma4b)
        #expect(Catalog.size(190_085_487) == "190 MB")
        #expect(Catalog.size(2_489_757_856) == "2.5 GB")
    }

    @Test func blocksCutAtTheQuietestPoint() {
        // 25 "minutes" at 1 sample per second, quiet at 590 and 1185.
        let quiet: Set<Int> = [590, 1185]
        let blocks = AudioBlocks.plan(total: 1500, target: 600, window: 30, step: 5) { start, length in
            (start..<start + length).contains { quiet.contains($0) } ? 0 : 1
        }
        #expect(blocks.count == 3)
        #expect(blocks.first?.lowerBound == 0)
        #expect(blocks.last?.upperBound == 1500)
        #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(abs(blocks[0].upperBound - 590) <= 5)
    }

    @Test func shortAudioIsOneBlock() {
        #expect(AudioBlocks.plan(total: 610, target: 600, window: 30, step: 5) { _, _ in 1 } == [0..<610])
        #expect(AudioBlocks.plan(total: 0, target: 600, window: 30, step: 5) { _, _ in 1 }.isEmpty)
    }
}
