import Foundation

struct SearchHistoryStore: Sendable {
    static let maxItems = 100
    static let collapsedDisplayCount = 10

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = support.appendingPathComponent("gaoxipeng.bilibili", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        fileURL = appDirectory.appendingPathComponent("search-history.json")
    }

    func read(limit: Int = maxItems) -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return array.compactMap { query -> String? in
            let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }.prefix(limit).map { $0 }
    }

    @discardableResult
    func touch(_ query: String) -> [String] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return read() }
        let updated = ([cleaned] + read()).uniqued().prefix(Self.maxItems).map { $0 }
        persist(updated)
        return updated
    }

    @discardableResult
    func remove(_ query: String) -> [String] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return read() }
        let updated = read().filter { $0 != cleaned }
        persist(updated)
        return updated
    }

    @discardableResult
    func clear() -> [String] {
        persist([])
        return []
    }

    private func persist(_ items: [String]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
