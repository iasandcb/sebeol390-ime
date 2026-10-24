import Foundation
import Testing
@testable import Sebeol390Core

@Test func typoLogStoresJsonlAndKeepsTheTail() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sebeol390-typos-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("typos.jsonl")
    let log = TypoLog(fileURL: file)
    #expect(TypoLog.defaultFileURL.path.hasSuffix("Application Support/Sebeol390/typos.jsonl"))
    log.record(wrong: "가", wrongKeys: "kf", final: "나", finalKeys: "hf")
    #expect(log.uniqueFinal(for: "가") == nil)

    let stem = String(repeating: "가", count: 30)
    var newest = ""
    for index in 0..<1400 {
        let wrong = stem + "\(index)"
        let final = stem + "끝\(index)"
        newest = wrong
        log.record(wrong: wrong, wrongKeys: "mfskbw", final: final, finalKeys: "mfskgw")
    }
    let data = try! Data(contentsOf: file)
    #expect(data.count <= TypoLog.maxBytes)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(newest))
    #expect(!text.contains(stem + "0\""))
    let reloaded = TypoLog(fileURL: file)
    #expect(reloaded.uniqueFinal(for: newest)?.hasPrefix(stem) == true)
    try? FileManager.default.removeItem(at: directory)
}
