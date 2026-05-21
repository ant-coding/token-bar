import AppKit
import Darwin
import Foundation

// MARK: - Models

/// Calendar-aligned time window. `.day` buckets by hour-of-day; `.week` runs Monday→Sunday
/// (7 buckets); `.month` runs day-1 through the last day of the current month (28–31 buckets).
/// Future buckets within the current week/month are rendered as placeholders.
enum Period: Int, CaseIterable, Sendable {
    case day = 0, week = 1, month = 2

    /// Number of buckets in the chart for this period at `now`. Day and week are fixed;
    /// month varies (28/29/30/31) with the current calendar month.
    func bucketCount(now: Date, calendar: Calendar) -> Int {
        switch self {
        case .day:   return 24
        case .week:  return 7
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let firstOfMonth = calendar.date(from: comps) ?? now
            return calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        }
    }

    var captionFull: String {
        switch self {
        case .day:   return "Tokens today"
        case .week:  return "Tokens this week"
        case .month: return "Tokens this month"
        }
    }

    var captionEmpty: String {
        switch self {
        case .day:   return "Nothing yet today"
        case .week:  return "Nothing yet this week"
        case .month: return "Nothing yet this month"
        }
    }

    var emptyToolsMessage: String {
        switch self {
        case .day:   return "No Codex sessions recorded"
        case .week:  return "No sessions yet this week"
        case .month: return "No sessions yet this month"
        }
    }

    var segmentTitle: String {
        switch self {
        case .day:   return "DAY"
        case .week:  return "WEEK"
        case .month: return "MONTH"
        }
    }
}

struct PeriodSelection: Hashable, Sendable {
    var period: Period
    var offset: Int

    init(period: Period, offset: Int = 0) {
        self.period = period
        self.offset = period == .day ? 0 : min(offset, 0)
    }

    static func current(_ period: Period) -> PeriodSelection {
        PeriodSelection(period: period, offset: 0)
    }
}

struct PeriodNavigationState: Sendable {
    var isVisible: Bool
    var canGoPrevious: Bool
    var canGoNext: Bool

    static let hidden = PeriodNavigationState(isVisible: false, canGoPrevious: false, canGoNext: false)
}

struct TokenUsage: Equatable, Codable, Sendable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var totalTokens: Int64 = 0
    /// Estimated API cost in USD for these tokens, accumulated at parse time using
    /// per-model rate cards (`PriceCard`). Stored on the delta so the model and the
    /// cache-write/read split are applied with full per-event fidelity, not lost in
    /// per-tool aggregation.
    var costUSD: Double = 0

    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
        costUSD += other.costUSD
    }

    mutating func subtract(_ other: TokenUsage) {
        inputTokens -= other.inputTokens
        cachedInputTokens -= other.cachedInputTokens
        outputTokens -= other.outputTokens
        reasoningOutputTokens -= other.reasoningOutputTokens
        totalTokens -= other.totalTokens
        costUSD -= other.costUSD
    }

    var isEffectivelyZero: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && outputTokens == 0
            && reasoningOutputTokens == 0
            && totalTokens == 0
            && abs(costUSD) < 0.000001
    }
}

struct ContributorSummary: Sendable {
    let id: String
    let displayName: String
    let usage: TokenUsage
    let sessionCount: Int
}

private let unattributedContributorID = "Unattributed"

private func normalizedContributorID(_ id: String?) -> String {
    guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
        return unattributedContributorID
    }
    return id
}

private func redactedContributorID(from path: String?) -> String {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
        return unattributedContributorID
    }

    let folderName = URL(fileURLWithPath: path).lastPathComponent
    let displayBase = folderName.isEmpty ? "Project" : folderName
    return "\(displayBase)#\(shortStableHash(path))"
}

private func stablePrivacyHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return hash
}

private func shortStableHash(_ text: String) -> String {
    let hash = stablePrivacyHash(text)
    return String(format: "%08llx", hash & 0xffff_ffff)
}

private func stableCacheHash(_ text: String) -> String {
    String(format: "%016llx", stablePrivacyHash(text))
}

private func contributorDisplayName(for id: String) -> String {
    guard id != unattributedContributorID else { return unattributedContributorID }
    let idBase = id.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
    let lastComponent = URL(fileURLWithPath: idBase).lastPathComponent
    let rawName = lastComponent.isEmpty ? idBase : lastComponent
    let separators = CharacterSet(charactersIn: "-_.")
    let words = rawName
        .components(separatedBy: separators)
        .filter { !$0.isEmpty }

    guard words.count > 1 else { return rawName }
    return words.map { word in
        if word.count <= 3 {
            return word.uppercased()
        }
        let first = word.prefix(1).uppercased()
        let rest = word.dropFirst().lowercased()
        return first + rest
    }.joined(separator: " ")
}

// MARK: - Pricing

/// Per-million-token API rates in USD for one model. Cached-input is the cache-hit
/// rate; cache-write is the surcharge Anthropic charges when you first store a block
/// (it's higher than fresh input). OpenAI doesn't bill cache writes separately.
/// Reasoning tokens aren't a separate line — they're a subset of `output_tokens` for
/// both providers, so billing on `output` already covers them.
struct PriceCard: Sendable {
    let inputUSDPerMillion: Double
    let cachedInputUSDPerMillion: Double
    let cacheWriteUSDPerMillion: Double
    let outputUSDPerMillion: Double
}

/// API rates as of 2026-05-04. Sources:
///   - Anthropic: https://platform.claude.com/docs/en/docs/about-claude/pricing
///   - OpenAI:    https://developers.openai.com/api/docs/pricing
enum Pricing {
    /// Default Codex card. Codex `token_count` events don't carry a model id, and most
    /// users on this app are on a Pro plan (flat-rate, not API-billed) — the displayed
    /// cost is therefore an "API-equivalent reference" rather than a real invoice line.
    /// Numbers below are gpt-5.5 standard rates; if Codex CLI later defaults to a different
    /// model (e.g. gpt-5.3-codex at $1.75/$0.175/$14), the headline cost will overstate.
    static let codexDefault = PriceCard(
        inputUSDPerMillion: 5.00,
        cachedInputUSDPerMillion: 0.50,
        cacheWriteUSDPerMillion: 5.00,   // OpenAI doesn't surcharge cache writes
        outputUSDPerMillion: 30.00
    )

    /// Anthropic per-model pricing. Match by substring on the model id reported by
    /// Claude Code (`claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-...`).
    /// Order is important: check more specific names first. Cache-write rate is the
    /// 5-minute TTL ($1.25× input); the 1-hour TTL is 2× input but Claude Code uses
    /// the 5-minute default.
    static func claude(modelId: String) -> PriceCard {
        let lc = modelId.lowercased()
        if lc.contains("haiku") {
            return PriceCard(
                inputUSDPerMillion: 1.00,
                cachedInputUSDPerMillion: 0.10,
                cacheWriteUSDPerMillion: 1.25,
                outputUSDPerMillion: 5.00
            )
        }
        if lc.contains("sonnet") {
            return PriceCard(
                inputUSDPerMillion: 3.00,
                cachedInputUSDPerMillion: 0.30,
                cacheWriteUSDPerMillion: 3.75,
                outputUSDPerMillion: 15.00
            )
        }
        // Opus 4.5 / 4.6 / 4.7 share the same card. Older Opus 4 / 4.1 were 3× this,
        // but they don't appear in Claude Code's recent logs so the fallback is fine.
        return PriceCard(
            inputUSDPerMillion: 5.00,
            cachedInputUSDPerMillion: 0.50,
            cacheWriteUSDPerMillion: 6.25,
            outputUSDPerMillion: 25.00
        )
    }
}

/// Format a USD amount for the tight tool row: cents below $1k, rounded above, compact above $10k.
private func compactCost(_ usd: Double) -> String {
    if usd >= 10_000 {
        return "$" + compactString(Int64(usd))
    }
    if usd >= 100 {
        return String(format: "$%.0f", usd)
    }
    return String(format: "$%.2f", usd)
}

struct UsageSnapshot: Sendable {
    var generatedAt: Date
    var period: Period
    var periodOffset: Int
    var rangeStart: Date                  // inclusive start of the first bucket
    var rangeEnd: Date                    // exclusive end of the last bucket
    var bucketCount: Int                  // chart slot count (24, 7, or 28–31)
    var byTool: [String: TokenUsage]
    var bucketsByTool: [String: [Int64]]  // originator → bucketCount slots
    var topContributors: [ContributorSummary]
    var currentBucketIndex: Int           // which bucket "now" lives in
    var scannedFiles: Int
    var tokenEvents: Int

    var total: TokenUsage {
        byTool.values.reduce(into: TokenUsage()) { partial, usage in
            partial.add(usage)
        }
    }

    var bucketTotals: [Int64] {
        var combined = Array<Int64>(repeating: 0, count: bucketCount)
        for (_, buckets) in bucketsByTool {
            for i in 0..<bucketCount where i < buckets.count {
                combined[i] += buckets[i]
            }
        }
        return combined
    }
}

// MARK: - Period bucketing helpers (shared by both readers)

enum PeriodMath {
    /// Compute the [start, end) window for a period, calendar-aligned. `.day` covers the
    /// current calendar day; `.week` runs from Monday-of-this-week through midnight after
    /// today; `.month` runs from the 1st of this month through midnight after today.
    /// Window end stops at "midnight after today" (not end-of-week / end-of-month) because
    /// data past today doesn't exist yet — we only scan up to the present.
    static func dateRange(for period: Period, now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        switch period {
        case .day:
            return (startOfDay, endOfDay)
        case .week:
            return (mondayOfWeek(containing: startOfDay, calendar: calendar), endOfDay)
        case .month:
            return (firstOfMonth(containing: startOfDay, calendar: calendar), endOfDay)
        }
    }

    static func dateRange(for selection: PeriodSelection, now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now

        switch selection.period {
        case .day:
            return (startOfDay, endOfDay)
        case .week:
            let currentStart = mondayOfWeek(containing: startOfDay, calendar: calendar)
            let start = calendar.date(byAdding: .weekOfYear, value: selection.offset, to: currentStart) ?? currentStart
            if selection.offset == 0 {
                return (start, endOfDay)
            }
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? endOfDay
            return (start, end)
        case .month:
            let currentStart = firstOfMonth(containing: startOfDay, calendar: calendar)
            let start = calendar.date(byAdding: .month, value: selection.offset, to: currentStart) ?? currentStart
            if selection.offset == 0 {
                return (start, endOfDay)
            }
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? endOfDay
            return (start, end)
        }
    }

    static func bucketCount(for selection: PeriodSelection, now: Date, calendar: Calendar) -> Int {
        switch selection.period {
        case .day:
            return 24
        case .week:
            return 7
        case .month:
            let range = dateRange(for: selection, now: now, calendar: calendar)
            return calendar.range(of: .day, in: .month, for: range.start)?.count ?? 30
        }
    }

    /// Bucket index for `timestamp` inside `[rangeStart, rangeEnd)`, or nil if it falls outside.
    static func bucketIndex(
        for timestamp: Date,
        period: Period,
        rangeStart: Date,
        bucketCount: Int,
        calendar: Calendar
    ) -> Int? {
        switch period {
        case .day:
            let hour = calendar.component(.hour, from: timestamp)
            return (0..<24).contains(hour) ? hour : nil
        case .week, .month:
            let startDay = calendar.startOfDay(for: rangeStart)
            let tsDay = calendar.startOfDay(for: timestamp)
            let diff = calendar.dateComponents([.day], from: startDay, to: tsDay).day ?? -1
            return (0..<bucketCount).contains(diff) ? diff : nil
        }
    }

    /// Index of the "now" bucket — the slot the pulse animation highlights.
    /// For `.day` this is the current hour; for `.week`/`.month` it's days-since-rangeStart.
    static func currentBucketIndex(for period: Period, now: Date, rangeStart: Date, calendar: Calendar) -> Int {
        switch period {
        case .day:
            return calendar.component(.hour, from: now)
        case .week, .month:
            let startDay = calendar.startOfDay(for: rangeStart)
            let nowDay = calendar.startOfDay(for: now)
            return calendar.dateComponents([.day], from: startDay, to: nowDay).day ?? 0
        }
    }

    static func currentBucketIndex(
        for selection: PeriodSelection,
        now: Date,
        rangeStart: Date,
        bucketCount: Int,
        calendar: Calendar
    ) -> Int {
        guard selection.offset == 0 else {
            return max(0, bucketCount - 1)
        }
        let index = currentBucketIndex(for: selection.period, now: now, rangeStart: rangeStart, calendar: calendar)
        return max(0, min(bucketCount - 1, index))
    }

    /// Monday-of-this-week, regardless of the locale's first-day-of-week setting.
    /// (Some locales default to Sunday; we always anchor weeks on Monday.)
    private static func mondayOfWeek(containing day: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2  // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
        return cal.date(from: comps) ?? day
    }

    private static func firstOfMonth(containing day: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: day)
        return calendar.date(from: comps) ?? day
    }
}

struct UsageHistory: Sendable {
    var generatedAt: Date
    var hourlyUsageByTool: [String: [String: TokenUsage]]
    var hourlyUsageByContributor: [String: [String: TokenUsage]]
    var hourlyContributorSessions: [String: [String: [String: Int]]]
    var hourlyTokenEvents: [String: Int]
    var scannedFiles: Int

    static func empty() -> UsageHistory {
        UsageHistory(
            generatedAt: Date(timeIntervalSince1970: 0),
            hourlyUsageByTool: [:],
            hourlyUsageByContributor: [:],
            hourlyContributorSessions: [:],
            hourlyTokenEvents: [:],
            scannedFiles: 0
        )
    }

    var hasIndexedData: Bool {
        scannedFiles > 0 || !hourlyUsageByTool.isEmpty || !hourlyTokenEvents.isEmpty
    }

    func snapshot(for selection: PeriodSelection) -> UsageSnapshot {
        let normalized = PeriodSelection(period: selection.period, offset: selection.offset)
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let (rangeStart, rangeEnd) = PeriodMath.dateRange(for: normalized, now: now, calendar: calendar)
        let bucketCount = PeriodMath.bucketCount(for: normalized, now: now, calendar: calendar)

        var byTool: [String: TokenUsage] = [:]
        var bucketsByTool: [String: [Int64]] = [:]
        var byContributor: [String: TokenUsage] = [:]
        var contributorSessions: [String: Set<String>] = [:]
        var tokenEvents = 0

        func consume(hour: Date, bucketIndex: Int) {
            guard hour >= rangeStart, hour < rangeEnd else { return }
            let key = Self.hourKey(for: hour)
            tokenEvents += hourlyTokenEvents[key] ?? 0
            guard let tools = hourlyUsageByTool[key] else { return }
            for (tool, usage) in tools {
                byTool[tool, default: TokenUsage()].add(usage)
                var buckets = bucketsByTool[tool] ?? Array(repeating: 0, count: bucketCount)
                buckets[bucketIndex] += usage.totalTokens
                bucketsByTool[tool] = buckets
            }
            if let contributors = hourlyUsageByContributor[key] {
                for (contributor, usage) in contributors {
                    byContributor[contributor, default: TokenUsage()].add(usage)
                }
            }
            if let sessions = hourlyContributorSessions[key] {
                for (contributor, sessionCounts) in sessions {
                    for (sessionId, count) in sessionCounts where count > 0 {
                        contributorSessions[contributor, default: []].insert(sessionId)
                    }
                }
            }
        }

        switch normalized.period {
        case .day:
            for hour in 0..<24 {
                guard let date = calendar.date(byAdding: .hour, value: hour, to: rangeStart) else { continue }
                consume(hour: date, bucketIndex: hour)
            }
        case .week, .month:
            for day in 0..<bucketCount {
                guard let dayStart = calendar.date(byAdding: .day, value: day, to: rangeStart) else { continue }
                for hour in 0..<24 {
                    guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { continue }
                    consume(hour: hourStart, bucketIndex: day)
                }
            }
        }

        return UsageSnapshot(
            generatedAt: generatedAt.timeIntervalSince1970 > 0 ? generatedAt : now,
            period: normalized.period,
            periodOffset: normalized.offset,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            bucketCount: bucketCount,
            byTool: byTool,
            bucketsByTool: bucketsByTool,
            topContributors: Self.topContributors(
                from: byContributor,
                sessions: contributorSessions
            ),
            currentBucketIndex: PeriodMath.currentBucketIndex(
                for: normalized,
                now: now,
                rangeStart: rangeStart,
                bucketCount: bucketCount,
                calendar: calendar
            ),
            scannedFiles: scannedFiles,
            tokenEvents: tokenEvents
        )
    }

    private static func topContributors(
        from usageByContributor: [String: TokenUsage],
        sessions: [String: Set<String>]
    ) -> [ContributorSummary] {
        usageByContributor
            .filter { $0.value.totalTokens > 0 }
            .map { id, usage in
                ContributorSummary(
                    id: id,
                    displayName: contributorDisplayName(for: id),
                    usage: usage,
                    sessionCount: sessions[id]?.count ?? 0
                )
            }
            .sorted { left, right in
                if abs(left.usage.costUSD - right.usage.costUSD) > 0.000001 {
                    return left.usage.costUSD > right.usage.costUSD
                }
                if left.usage.totalTokens == right.usage.totalTokens {
                    return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
                }
                return left.usage.totalTokens > right.usage.totalTokens
            }
            .prefix(3)
            .map { $0 }
    }

    func navigationState(for selection: PeriodSelection) -> PeriodNavigationState {
        guard selection.period != .day else { return .hidden }
        let offset = PeriodSelection(period: selection.period, offset: selection.offset).offset
        let earliest = earliestOffset(for: selection.period)
        return PeriodNavigationState(
            isVisible: true,
            canGoPrevious: offset > earliest,
            canGoNext: offset < 0
        )
    }

    func clampedSelection(_ selection: PeriodSelection) -> PeriodSelection {
        guard selection.period != .day else { return .current(.day) }
        let earliest = earliestOffset(for: selection.period)
        let offset = max(earliest, min(0, selection.offset))
        return PeriodSelection(period: selection.period, offset: offset)
    }

    private func earliestOffset(for period: Period) -> Int {
        guard period != .day, let earliest = earliestHourDate() else { return 0 }

        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        switch period {
        case .day:
            return 0
        case .week:
            let currentStart = PeriodMath.dateRange(for: .current(.week), now: now, calendar: calendar).start
            let earliestStart = PeriodMath.dateRange(for: .current(.week), now: earliest, calendar: calendar).start
            let dayDelta = calendar.dateComponents([.day], from: currentStart, to: earliestStart).day ?? 0
            return min(0, dayDelta / 7)
        case .month:
            let current = calendar.dateComponents([.year, .month], from: now)
            let first = calendar.dateComponents([.year, .month], from: earliest)
            let currentIndex = (current.year ?? 0) * 12 + (current.month ?? 1)
            let firstIndex = (first.year ?? 0) * 12 + (first.month ?? 1)
            return min(0, firstIndex - currentIndex)
        }
    }

    private func earliestHourDate() -> Date? {
        let keys = Set(hourlyUsageByTool.keys).union(hourlyTokenEvents.keys)
        return keys.compactMap(Self.date(fromHourKey:)).min()
    }

    static func hourKey(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0,
            comps.hour ?? 0
        )
    }

    private static func date(fromHourKey key: String) -> Date? {
        let pieces = key.split(separator: "-")
        guard pieces.count == 4,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]),
              let hour = Int(pieces[3])
        else { return nil }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        return Calendar.autoupdatingCurrent.date(from: comps)
    }
}

// MARK: - Shared parsing helpers (used by both readers)

/// Codex emits two ISO-8601 shapes (with and without fractional seconds); Claude Code uses the
/// fractional shape. Try the fractional formatter first, then fall back.
///
/// Marked `nonisolated(unsafe)` so the readers (which run on detached background tasks) can call
/// `parseISOTimestamp` without crossing actor boundaries. `ISO8601DateFormatter.date(from:)` is
/// documented thread-safe.
private enum TimestampParser {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let withoutFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private func parseISOTimestamp(_ text: String) -> Date? {
    TimestampParser.withFractions.date(from: text) ?? TimestampParser.withoutFractions.date(from: text)
}

/// Tolerant Int64 coercion for values pulled out of `[String: Any]` JSON dictionaries —
/// JSONSerialization may surface integers as `Int`, `Int64`, `Double`, or `NSNumber`.
private func jsonInt64(_ value: Any?) -> Int64 {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? Double { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return 0
}

// MARK: - Provider path configuration

private func applicationSupportRoot() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let root = support.appendingPathComponent("local.tokenbar", isDirectory: true)
    let legacyRoot = support.appendingPathComponent("local." + "codex.tokenbar", isDirectory: true)
    migrateApplicationSupportRoot(from: legacyRoot, to: root)
    return root
}

private func migrateApplicationSupportRoot(from legacyRoot: URL, to root: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: legacyRoot.path) else {
        return
    }

    if !fileManager.fileExists(atPath: root.path) {
        do {
            try fileManager.moveItem(at: legacyRoot, to: root)
            return
        } catch {
            // Fall through to a copy-based merge so a partial target can still recover.
        }
    }

    do {
        try copyMissingApplicationSupportContents(from: legacyRoot, to: root)
        try? fileManager.removeItem(at: legacyRoot)
    } catch {
        fputs("TokenBar support migration failed: \(error)\n", stderr)
    }
}

private func copyMissingApplicationSupportContents(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let contents = try fileManager.contentsOfDirectory(
        at: source,
        includingPropertiesForKeys: [.isDirectoryKey]
    )

    for sourceURL in contents {
        let targetURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
        let sourceIsDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var targetIsDirectory = ObjCBool(false)
        let targetExists = fileManager.fileExists(atPath: targetURL.path, isDirectory: &targetIsDirectory)

        if targetExists {
            if sourceIsDirectory && targetIsDirectory.boolValue {
                try copyMissingApplicationSupportContents(from: sourceURL, to: targetURL)
            } else {
                try fileManager.copyItem(at: sourceURL, to: legacyBackupURL(for: targetURL))
            }
            continue
        }

        try fileManager.copyItem(at: sourceURL, to: targetURL)
    }
}

private func legacyBackupURL(for targetURL: URL) -> URL {
    let directory = targetURL.deletingLastPathComponent()
    let backupName = targetURL.lastPathComponent + ".legacy"
    var candidate = directory.appendingPathComponent(backupName)
    var index = 2

    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = directory.appendingPathComponent("\(backupName).\(index)")
        index += 1
    }

    return candidate
}

private func expandedProviderPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if trimmed == "~" {
        return home
    }
    if trimmed.hasPrefix("~/") {
        return URL(fileURLWithPath: home)
            .appendingPathComponent(String(trimmed.dropFirst(2)))
            .path
    }
    return (trimmed as NSString).expandingTildeInPath
}

private func standardizedProviderPath(_ path: String) -> String {
    let expanded = expandedProviderPath(path)
    guard !expanded.isEmpty else { return "" }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

private func displayProviderPath(_ path: String) -> String {
    let standardized = standardizedProviderPath(path)
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    if standardized == home {
        return "~"
    }
    if standardized.hasPrefix(home + "/") {
        return "~/" + String(standardized.dropFirst(home.count + 1))
    }
    return standardized
}

struct ProviderPathConfig: Codable, Equatable, Sendable {
    var codexEnabled: Bool
    var codexRoots: [String]
    var claudeCodeEnabled: Bool
    var claudeCodeRoots: [String]

    static func defaultCodexRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        return [
            home.appendingPathComponent("sessions", isDirectory: true).path,
            home.appendingPathComponent("archived_sessions", isDirectory: true).path
        ]
    }

    static func defaultClaudeCodeRoots() -> [String] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
                .path
        ]
    }

    static var defaults: ProviderPathConfig {
        ProviderPathConfig(
            codexEnabled: true,
            codexRoots: defaultCodexRoots(),
            claudeCodeEnabled: true,
            claudeCodeRoots: defaultClaudeCodeRoots()
        )
    }

    func normalized() -> ProviderPathConfig {
        var next = self
        next.codexRoots = Self.uniquePaths(codexRoots)
        next.claudeCodeRoots = Self.uniquePaths(claudeCodeRoots)
        if next.codexRoots.isEmpty {
            next.codexRoots = Self.defaultCodexRoots()
        }
        if next.claudeCodeRoots.isEmpty {
            next.claudeCodeRoots = Self.defaultClaudeCodeRoots()
        }
        return next
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            let standardized = standardizedProviderPath(path)
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { continue }
            out.append(standardized)
        }
        return out
    }
}

enum ThemePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppConfig: Equatable, Sendable {
    var providerPaths: ProviderPathConfig
    var themePreference: ThemePreference

    static var defaults: AppConfig {
        AppConfig(providerPaths: .defaults, themePreference: .system)
    }

    func normalized() -> AppConfig {
        AppConfig(
            providerPaths: providerPaths.normalized(),
            themePreference: themePreference
        )
    }
}

enum AppConfigManager {
    private static let currentVersion = 1

    private struct StoredConfig: Codable, Sendable {
        var version: Int
        var providerPaths: ProviderPathConfig
        var themePreference: ThemePreference?
    }

    static var configURL: URL {
        applicationSupportRoot().appendingPathComponent("config-v1.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let stored = try? JSONDecoder().decode(StoredConfig.self, from: data),
              stored.version == currentVersion
        else {
            return .defaults
        }
        return AppConfig(
            providerPaths: stored.providerPaths,
            themePreference: stored.themePreference ?? .system
        ).normalized()
    }

    static func save(_ config: AppConfig) throws {
        let normalized = config.normalized()
        let stored = StoredConfig(
            version: currentVersion,
            providerPaths: normalized.providerPaths,
            themePreference: normalized.themePreference
        )
        let url = configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: url, options: [.atomic])
    }
}

final class CodexUsageReader {
    private let codexHome: URL
    private let fileManager = FileManager.default
    private let calendar: Calendar

    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
        self.calendar = Calendar.autoupdatingCurrent
    }

    func load(period: Period) -> UsageSnapshot {
        let now = Date()
        let (rangeStart, rangeEnd) = PeriodMath.dateRange(for: period, now: now, calendar: calendar)
        let bucketCount = period.bucketCount(now: now, calendar: calendar)
        let candidateFiles = recentSessionFiles(since: rangeStart.addingTimeInterval(-48 * 60 * 60))

        var byTool: [String: TokenUsage] = [:]
        var bucketsByTool: [String: [Int64]] = [:]
        var tokenEvents = 0

        for file in candidateFiles {
            let result = readSessionFile(file, period: period, rangeStart: rangeStart, rangeEnd: rangeEnd, bucketCount: bucketCount)
            guard result.tokenEvents > 0 else { continue }
            tokenEvents += result.tokenEvents
            byTool[result.originator, default: TokenUsage()].add(result.usage)
            var buckets = bucketsByTool[result.originator] ?? Array(repeating: 0, count: bucketCount)
            for i in 0..<bucketCount { buckets[i] += result.buckets[i] }
            bucketsByTool[result.originator] = buckets
        }

        return UsageSnapshot(
            generatedAt: now,
            period: period,
            periodOffset: 0,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            bucketCount: bucketCount,
            byTool: byTool,
            bucketsByTool: bucketsByTool,
            topContributors: [],
            currentBucketIndex: PeriodMath.currentBucketIndex(for: period, now: now, rangeStart: rangeStart, calendar: calendar),
            scannedFiles: candidateFiles.count,
            tokenEvents: tokenEvents
        )
    }

    private func recentSessionFiles(since cutoff: Date) -> [URL] {
        let roots = [
            codexHome.appendingPathComponent("sessions"),
            codexHome.appendingPathComponent("archived_sessions")
        ]

        var newestByName: [String: (url: URL, modified: Date)] = [:]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }

                let key = url.lastPathComponent
                if let existing = newestByName[key], existing.modified >= modified {
                    continue
                }
                newestByName[key] = (url, modified)
            }
        }

        return newestByName.values
            .sorted { $0.modified < $1.modified }
            .map(\.url)
    }

    private func readSessionFile(
        _ url: URL,
        period: Period,
        rangeStart: Date,
        rangeEnd: Date,
        bucketCount: Int
    ) -> (originator: String, usage: TokenUsage, buckets: [Int64], tokenEvents: Int) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ("unknown", TokenUsage(), Array(repeating: 0, count: bucketCount), 0)
        }

        var originator = "unknown"
        var usage = TokenUsage()
        var buckets = Array<Int64>(repeating: 0, count: bucketCount)
        var tokenEvents = 0

        // Codex's per-turn deltas are unreliable: ~10% of recent files emit each token_count
        // event twice (byte-identical `last_token_usage`), and another ~30% have a
        // `last_token_usage` that's already partly cumulative. Rather than sum `last_token_usage`,
        // walk `total_token_usage` (which is empirically monotonic per file) and emit our own
        // delta. The running total is advanced for every parseable event — including ones
        // outside the period window — so an in-range event after an out-of-range one doesn't
        // get credited with the out-of-range work.
        var prevInput: Int64 = 0
        var prevCached: Int64 = 0
        var prevOutput: Int64 = 0
        var prevReasoning: Int64 = 0
        var prevTotal: Int64 = 0

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            if type == "session_meta" {
                originator = payload["originator"] as? String ?? originator
                continue
            }

            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any]
            else { continue }

            let curInput = jsonInt64(total["input_tokens"])
            let curCached = jsonInt64(total["cached_input_tokens"])
            let curOutput = jsonInt64(total["output_tokens"])
            let curReasoning = jsonInt64(total["reasoning_output_tokens"])
            let curTotal = jsonInt64(total["total_tokens"])

            let dInput = max(0, curInput - prevInput)
            let dCached = max(0, curCached - prevCached)
            let dOutput = max(0, curOutput - prevOutput)
            let dReasoning = max(0, curReasoning - prevReasoning)
            let dTotal = max(0, curTotal - prevTotal)

            prevInput = curInput
            prevCached = curCached
            prevOutput = curOutput
            prevReasoning = curReasoning
            prevTotal = curTotal

            // Re-emitted event: running totals didn't move, so there's nothing to bill.
            if dTotal == 0 { continue }

            guard let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISOTimestamp(timestampText),
                  timestamp >= rangeStart,
                  timestamp < rangeEnd
            else { continue }

            // Codex's `input_tokens` already includes cached, so subtract to get the
            // fresh-input portion that bills at the higher rate. Reasoning is a subset of
            // output (verified: total = input + output), so we don't bill it separately.
            let card = Pricing.codexDefault
            let freshInput = max(0, dInput - dCached)
            let cost =
                Double(freshInput) * card.inputUSDPerMillion / 1_000_000
                + Double(dCached) * card.cachedInputUSDPerMillion / 1_000_000
                + Double(dOutput) * card.outputUSDPerMillion / 1_000_000

            let delta = TokenUsage(
                inputTokens: dInput,
                cachedInputTokens: dCached,
                outputTokens: dOutput,
                reasoningOutputTokens: dReasoning,
                totalTokens: dTotal,
                costUSD: cost
            )
            usage.add(delta)
            if let idx = PeriodMath.bucketIndex(for: timestamp, period: period, rangeStart: rangeStart, bucketCount: bucketCount, calendar: calendar) {
                buckets[idx] += delta.totalTokens
            }
            tokenEvents += 1
        }

        return (originator, usage, buckets, tokenEvents)
    }
}

// MARK: - Claude Code reader

/// Reads Claude Code session logs (~/.claude/projects/<encoded-cwd>/<sid>.jsonl).
///
/// Unlike Codex, each assistant message carries its own delta `usage` object directly from the
/// Anthropic API. Cached input is reported separately (`cache_read_input_tokens`,
/// `cache_creation_input_tokens`) and is NOT double-counted in `input_tokens`, so we normalize
/// into the same TokenUsage shape used by the Codex path (`inputTokens` includes cached for display).
final class ClaudeCodeUsageReader {
    private let projectsRoot: URL
    private let fileManager = FileManager.default
    private let calendar: Calendar

    init(claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.projectsRoot = claudeHome.appendingPathComponent("projects")
        self.calendar = Calendar.autoupdatingCurrent
    }

    func read(period: Period) -> (usage: TokenUsage, buckets: [Int64], tokenEvents: Int, scannedFiles: Int) {
        let now = Date()
        let (rangeStart, rangeEnd) = PeriodMath.dateRange(for: period, now: now, calendar: calendar)
        let bucketCount = period.bucketCount(now: now, calendar: calendar)
        let files = recentSessionFiles(since: rangeStart.addingTimeInterval(-48 * 60 * 60))

        var usage = TokenUsage()
        var buckets = Array<Int64>(repeating: 0, count: bucketCount)
        var tokenEvents = 0

        for file in files {
            let result = readSessionFile(file, period: period, rangeStart: rangeStart, rangeEnd: rangeEnd, bucketCount: bucketCount)
            guard result.tokenEvents > 0 else { continue }
            tokenEvents += result.tokenEvents
            usage.add(result.usage)
            for i in 0..<bucketCount { buckets[i] += result.buckets[i] }
        }
        return (usage, buckets, tokenEvents, files.count)
    }

    private func recentSessionFiles(since cutoff: Date) -> [URL] {
        guard fileManager.fileExists(atPath: projectsRoot.path),
              let enumerator = fileManager.enumerator(
                at: projectsRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
            out.append(url)
        }
        return out
    }

    private func readSessionFile(
        _ url: URL,
        period: Period,
        rangeStart: Date,
        rangeEnd: Date,
        bucketCount: Int
    ) -> (usage: TokenUsage, buckets: [Int64], tokenEvents: Int) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return (TokenUsage(), Array(repeating: 0, count: bucketCount), 0)
        }

        var usage = TokenUsage()
        var buckets = Array<Int64>(repeating: 0, count: bucketCount)
        var tokenEvents = 0
        // Claude Code emits one assistant entry per content block (thinking / text / tool_use)
        // for a single API response — they share the same `message.id` and identical `usage`.
        // Naive summing inflates totals 2–3×, so dedupe within the file by id.
        var seenMessageIds: Set<String> = []

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISOTimestamp(timestampText),
                  timestamp >= rangeStart,
                  timestamp < rangeEnd,
                  let message = object["message"] as? [String: Any],
                  let apiUsage = message["usage"] as? [String: Any]
            else { continue }

            if let messageId = message["id"] as? String {
                if !seenMessageIds.insert(messageId).inserted { continue }
            }

            let rawInput = jsonInt64(apiUsage["input_tokens"])
            let cacheRead = jsonInt64(apiUsage["cache_read_input_tokens"])
            let cacheCreate = jsonInt64(apiUsage["cache_creation_input_tokens"])
            let output = jsonInt64(apiUsage["output_tokens"])

            // Per-event model id drives the price card — Claude Code mixes Opus/Sonnet/Haiku
            // and they bill at very different rates.
            let modelId = (message["model"] as? String) ?? "claude-opus"
            let card = Pricing.claude(modelId: modelId)
            let cost =
                Double(rawInput) * card.inputUSDPerMillion / 1_000_000
                + Double(cacheRead) * card.cachedInputUSDPerMillion / 1_000_000
                + Double(cacheCreate) * card.cacheWriteUSDPerMillion / 1_000_000
                + Double(output) * card.outputUSDPerMillion / 1_000_000

            // Normalize to Codex's convention: inputTokens is everything the model saw
            // (fresh + cache reads + cache creates), cachedInputTokens is the cache-related
            // subset of that. Both cache reads and cache creates count as "cached" for the
            // CACHED breakdown column — they're the input the user got back from / committed
            // to a cache mechanism. Cost still uses the three pieces separately so the
            // 1.25× cache-write premium and 0.1× cache-read discount land correctly.
            let totalInput = rawInput + cacheRead + cacheCreate
            let delta = TokenUsage(
                inputTokens: totalInput,
                cachedInputTokens: cacheRead + cacheCreate,
                outputTokens: output,
                reasoningOutputTokens: 0,  // Anthropic doesn't expose thinking tokens separately
                totalTokens: totalInput + output,
                costUSD: cost
            )
            usage.add(delta)

            if let idx = PeriodMath.bucketIndex(for: timestamp, period: period, rangeStart: rangeStart, bucketCount: bucketCount, calendar: calendar) {
                buckets[idx] += delta.totalTokens
            }
            tokenEvents += 1
        }
        return (usage, buckets, tokenEvents)
    }
}

// MARK: - Persistent usage cache

/// Cache-first usage aggregation. The app stores exact hourly rollups plus per-file cursors,
/// so unchanged history is never reparsed when the popover opens.
enum UsageCacheManager {
    static let currentVersion = 4
    private static let maxJSONLLineBytes = 16 * 1024 * 1024
    private static let codexSessionMetaNeedle = Array(#""session_meta""#.utf8)
    private static let codexTurnContextNeedle = Array(#""turn_context""#.utf8)
    private static let codexTokenCountNeedle = Array(#""token_count""#.utf8)
    private static let claudeAssistantNeedle = Array(#""assistant""#.utf8)
    private static let usageNeedle = Array(#""usage""#.utf8)

    struct RefreshResult: Sendable {
        let snapshots: [Period: UsageSnapshot]
        let history: UsageHistory
        let cacheURL: URL
        let changedFiles: Int
        let scannedFiles: Int
    }

    private enum UsageFileKind: String, Codable, Sendable {
        case codex
        case claude
    }

    private struct UsageFile: Sendable {
        let url: URL
        let kind: UsageFileKind
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    private struct CodexTotals: Codable, Sendable {
        var inputTokens: Int64 = 0
        var cachedInputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var reasoningOutputTokens: Int64 = 0
        var totalTokens: Int64 = 0
    }

    private struct CachedContribution: Codable, Sendable {
        var hourKey: String
        var tool: String
        var contributorID: String?
        var sessionIds: [String]
        var usage: TokenUsage
        var tokenEvents: Int
    }

    private struct CachedFile: Codable, Sendable {
        var fileID: String
        var kind: UsageFileKind
        var size: UInt64
        var modifiedAt: TimeInterval
        var processedOffset: UInt64
        var prefixFingerprint: String?
        var originator: String?
        var sessionId: String?
        var sessionContributorID: String?
        var currentContributorID: String?
        var lastCodexTotal: CodexTotals?
        var claudeSeenMessageIds: [String]
        var contributions: [CachedContribution]
    }

    private struct UsageCache: Codable, Sendable {
        var version: Int
        var generatedAt: Date
        var hourlyUsageByTool: [String: [String: TokenUsage]]
        var hourlyUsageByContributor: [String: [String: TokenUsage]]
        var hourlyContributorSessions: [String: [String: [String: Int]]]
        var hourlyTokenEvents: [String: Int]
        var files: [String: CachedFile]

        static func empty() -> UsageCache {
            UsageCache(
                version: currentVersion,
                generatedAt: Date(timeIntervalSince1970: 0),
                hourlyUsageByTool: [:],
                hourlyUsageByContributor: [:],
                hourlyContributorSessions: [:],
                hourlyTokenEvents: [:],
                files: [:]
            )
        }

        mutating func add(_ contribution: CachedContribution) {
            var tools = hourlyUsageByTool[contribution.hourKey] ?? [:]
            var usage = tools[contribution.tool] ?? TokenUsage()
            usage.add(contribution.usage)
            tools[contribution.tool] = usage
            hourlyUsageByTool[contribution.hourKey] = tools

            let contributor = normalizedContributorID(contribution.contributorID)
            var contributors = hourlyUsageByContributor[contribution.hourKey] ?? [:]
            var contributorUsage = contributors[contributor] ?? TokenUsage()
            contributorUsage.add(contribution.usage)
            contributors[contributor] = contributorUsage
            hourlyUsageByContributor[contribution.hourKey] = contributors

            var sessionsByContributor = hourlyContributorSessions[contribution.hourKey] ?? [:]
            var sessionCounts = sessionsByContributor[contributor] ?? [:]
            for sessionId in contribution.sessionIds where !sessionId.isEmpty {
                sessionCounts[sessionId, default: 0] += 1
            }
            sessionsByContributor[contributor] = sessionCounts
            hourlyContributorSessions[contribution.hourKey] = sessionsByContributor

            hourlyTokenEvents[contribution.hourKey, default: 0] += contribution.tokenEvents
        }

        mutating func remove(_ contribution: CachedContribution) {
            guard var tools = hourlyUsageByTool[contribution.hourKey],
                  var usage = tools[contribution.tool]
            else { return }

            usage.subtract(contribution.usage)
            if usage.isEffectivelyZero {
                tools.removeValue(forKey: contribution.tool)
            } else {
                tools[contribution.tool] = usage
            }

            if tools.isEmpty {
                hourlyUsageByTool.removeValue(forKey: contribution.hourKey)
            } else {
                hourlyUsageByTool[contribution.hourKey] = tools
            }

            let contributor = normalizedContributorID(contribution.contributorID)
            if var contributors = hourlyUsageByContributor[contribution.hourKey],
               var contributorUsage = contributors[contributor] {
                contributorUsage.subtract(contribution.usage)
                if contributorUsage.isEffectivelyZero {
                    contributors.removeValue(forKey: contributor)
                } else {
                    contributors[contributor] = contributorUsage
                }
                if contributors.isEmpty {
                    hourlyUsageByContributor.removeValue(forKey: contribution.hourKey)
                } else {
                    hourlyUsageByContributor[contribution.hourKey] = contributors
                }
            }

            if var sessionsByContributor = hourlyContributorSessions[contribution.hourKey],
               var sessionCounts = sessionsByContributor[contributor] {
                for sessionId in contribution.sessionIds where !sessionId.isEmpty {
                    let remaining = (sessionCounts[sessionId] ?? 0) - 1
                    if remaining <= 0 {
                        sessionCounts.removeValue(forKey: sessionId)
                    } else {
                        sessionCounts[sessionId] = remaining
                    }
                }
                if sessionCounts.isEmpty {
                    sessionsByContributor.removeValue(forKey: contributor)
                } else {
                    sessionsByContributor[contributor] = sessionCounts
                }
                if sessionsByContributor.isEmpty {
                    hourlyContributorSessions.removeValue(forKey: contribution.hourKey)
                } else {
                    hourlyContributorSessions[contribution.hourKey] = sessionsByContributor
                }
            }

            let remainingEvents = (hourlyTokenEvents[contribution.hourKey] ?? 0) - contribution.tokenEvents
            if remainingEvents <= 0 {
                hourlyTokenEvents.removeValue(forKey: contribution.hourKey)
            } else {
                hourlyTokenEvents[contribution.hourKey] = remainingEvents
            }
        }

        mutating func removeContributions(for file: CachedFile) {
            for contribution in file.contributions {
                remove(contribution)
            }
        }

        mutating func addContributions(_ contributions: [CachedContribution]) {
            for contribution in contributions {
                add(contribution)
            }
        }
    }

    private struct ParseResult: Sendable {
        var originator: String?
        var lastCodexTotal: CodexTotals?
        var claudeSeenMessageIds: [String]
        var contributions: [CachedContribution]
        var processedOffset: UInt64
        var prefixFingerprint: String?
        var sessionId: String?
        var sessionContributorID: String?
        var currentContributorID: String?
    }

    static var cacheURL: URL {
        applicationSupportRoot()
            .appendingPathComponent("usage-cache-v1.json")
    }

    private static func cacheKey(for file: UsageFile) -> String {
        "\(file.kind.rawValue)#\(stableCacheHash(file.url.path))"
    }

    static func cachedSnapshots() -> [Period: UsageSnapshot] {
        snapshots(from: cachedHistory())
    }

    static func cachedHistory() -> UsageHistory {
        guard let cache = loadCache(), cache.version == currentVersion else { return .empty() }
        return history(from: cache)
    }

    static func refresh(rebuild: Bool) -> RefreshResult {
        let config = AppConfigManager.load().providerPaths
        var cache = rebuild ? .empty() : (loadCache() ?? .empty())
        if cache.version != currentVersion {
            cache = .empty()
        }
        var didMutateCache = rebuild

        let files = discoverUsageFiles(config: config)
        let selectedCacheKeys = Set(files.map { cacheKey(for: $0) })

        let staleCacheKeys = cache.files.keys.filter { !selectedCacheKeys.contains($0) }
        for cacheKey in staleCacheKeys {
            guard let file = cache.files.removeValue(forKey: cacheKey) else { continue }
            cache.removeContributions(for: file)
            didMutateCache = true
        }

        var changedFiles = 0
        for file in files {
            let fileID = cacheKey(for: file)
            let existing = cache.files[fileID]
            let shouldSkip = existing?.kind == file.kind
                && existing?.size == file.size
                && existing?.modifiedAt == file.modifiedAt
                && existing?.processedOffset == file.size

            if shouldSkip { continue }
            changedFiles += 1

            let verifiedPrefix = existing.flatMap { cached in
                fingerprint(for: file.url, upto: cached.processedOffset) == cached.prefixFingerprint
            } ?? false

            let appendOnly = verifiedPrefix
                && existing?.kind == file.kind
                && (existing?.processedOffset ?? 0) <= file.size

            if appendOnly, let existing {
                let parse = parse(file: file, existing: existing, fullRebuild: false)
                guard !parse.contributions.isEmpty || parse.processedOffset == file.size else { continue }

                var updated = existing
                updated.size = file.size
                updated.modifiedAt = file.modifiedAt
                updated.processedOffset = parse.processedOffset
                updated.prefixFingerprint = parse.prefixFingerprint
                updated.originator = parse.originator ?? existing.originator
                updated.sessionId = parse.sessionId ?? existing.sessionId
                updated.sessionContributorID = parse.sessionContributorID ?? existing.sessionContributorID
                updated.currentContributorID = parse.currentContributorID ?? existing.currentContributorID
                updated.lastCodexTotal = parse.lastCodexTotal ?? existing.lastCodexTotal
                updated.claudeSeenMessageIds = parse.claudeSeenMessageIds
                updated.contributions.append(contentsOf: parse.contributions)
                cache.addContributions(parse.contributions)
                cache.files[fileID] = updated
                didMutateCache = true
            } else {
                if let existing {
                    cache.removeContributions(for: existing)
                }
                let parse = parse(file: file, existing: nil, fullRebuild: true)
                let updated = CachedFile(
                    fileID: fileID,
                    kind: file.kind,
                    size: file.size,
                    modifiedAt: file.modifiedAt,
                    processedOffset: parse.processedOffset,
                    prefixFingerprint: parse.prefixFingerprint,
                    originator: parse.originator,
                    sessionId: parse.sessionId,
                    sessionContributorID: parse.sessionContributorID,
                    currentContributorID: parse.currentContributorID,
                    lastCodexTotal: parse.lastCodexTotal,
                    claudeSeenMessageIds: parse.claudeSeenMessageIds,
                    contributions: parse.contributions
                )
                cache.addContributions(parse.contributions)
                cache.files[fileID] = updated
                didMutateCache = true
            }
        }

        if didMutateCache {
            cache.generatedAt = Date()
            save(cache)
        }
        let history = history(from: cache)
        return RefreshResult(
            snapshots: snapshots(from: history),
            history: history,
            cacheURL: cacheURL,
            changedFiles: changedFiles,
            scannedFiles: files.count
        )
    }

    private static func loadCache() -> UsageCache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data),
              cache.version == currentVersion
        else { return nil }
        return cache
    }

    private static func save(_ cache: UsageCache) {
        let url = cacheURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
        } catch {
            fputs("TokenBar cache write failed: \(error)\n", stderr)
        }
    }

    private static func discoverUsageFiles(config: ProviderPathConfig) -> [UsageFile] {
        var files: [UsageFile] = []
        files.append(contentsOf: discoverCodexFiles(config: config))
        files.append(contentsOf: discoverClaudeFiles(config: config))
        return files.sorted { $0.url.path < $1.url.path }
    }

    private static func discoverCodexFiles(config: ProviderPathConfig) -> [UsageFile] {
        guard config.codexEnabled else { return [] }
        let roots = config.codexRoots.map { URL(fileURLWithPath: standardizedProviderPath($0), isDirectory: true) }

        var newestByName: [String: UsageFile] = [:]
        for root in roots {
            for file in enumerateJSONLFiles(root: root, kind: .codex) {
                let name = file.url.lastPathComponent
                if let existing = newestByName[name], existing.modifiedAt >= file.modifiedAt {
                    continue
                }
                newestByName[name] = file
            }
        }
        return Array(newestByName.values)
    }

    private static func discoverClaudeFiles(config: ProviderPathConfig) -> [UsageFile] {
        guard config.claudeCodeEnabled else { return [] }
        var files: [UsageFile] = []
        for root in config.claudeCodeRoots {
            files.append(contentsOf: enumerateJSONLFiles(
                root: URL(fileURLWithPath: standardizedProviderPath(root), isDirectory: true),
                kind: .claude
            ))
        }
        return files
    }

    private static func enumerateJSONLFiles(root: URL, kind: UsageFileKind) -> [UsageFile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var files: [UsageFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  let size = values?.fileSize
            else { continue }

            files.append(UsageFile(
                url: url,
                kind: kind,
                size: UInt64(max(size, 0)),
                modifiedAt: modified.timeIntervalSince1970
            ))
        }
        return files
    }

    private static func parse(file: UsageFile, existing: CachedFile?, fullRebuild: Bool) -> ParseResult {
        switch file.kind {
        case .codex:
            return parseCodexFile(file, existing: existing, fullRebuild: fullRebuild)
        case .claude:
            return parseClaudeFile(file, existing: existing, fullRebuild: fullRebuild)
        }
    }

    private static func mergeContribution(
        _ contribution: CachedContribution,
        into contributions: inout [String: CachedContribution]
    ) {
        let contributor = normalizedContributorID(contribution.contributorID)
        let key = contribution.hourKey + "\u{1f}" + contribution.tool + "\u{1f}" + contributor
        if var existing = contributions[key] {
            existing.usage.add(contribution.usage)
            existing.tokenEvents += contribution.tokenEvents
            existing.sessionIds = Array(Set(existing.sessionIds).union(contribution.sessionIds)).sorted()
            contributions[key] = existing
        } else {
            contributions[key] = contribution
        }
    }

    private static func sortedContributions(_ contributions: [String: CachedContribution]) -> [CachedContribution] {
        contributions.values.sorted {
            if $0.hourKey == $1.hourKey {
                if $0.tool == $1.tool {
                    return normalizedContributorID($0.contributorID) < normalizedContributorID($1.contributorID)
                }
                return $0.tool < $1.tool
            }
            return $0.hourKey < $1.hourKey
        }
    }

    private static func inferredClaudeProjectPath(from url: URL) -> String? {
        let projectFolder = url.deletingLastPathComponent().lastPathComponent
        guard projectFolder.hasPrefix("-Users-ant-") else { return nil }
        let components = projectFolder
            .dropFirst()
            .split(separator: "-")
            .map(String.init)
        guard !components.isEmpty else { return nil }
        return "/" + components.joined(separator: "/")
    }

    private static func lineContains(_ line: Data.SubSequence, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, line.count >= needle.count else { return false }

        var idx = line.startIndex
        while idx < line.endIndex {
            guard line[idx] == needle[0] else {
                idx = line.index(after: idx)
                continue
            }

            var haystackIdx = idx
            var needleIdx = 0
            var matched = true
            while needleIdx < needle.count {
                if haystackIdx == line.endIndex || line[haystackIdx] != needle[needleIdx] {
                    matched = false
                    break
                }
                needleIdx += 1
                if needleIdx < needle.count {
                    haystackIdx = line.index(after: haystackIdx)
                }
            }
            if matched { return true }
            idx = line.index(after: idx)
        }
        return false
    }

    private static func readJSONLLines(_ url: URL, from offset: UInt64, handleLine: (Data.SubSequence) -> Void) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            var currentOffset = offset
            var committedOffset = offset
            var pending = Data()
            pending.reserveCapacity(64 * 1024)
            var droppingOversizedLine = false

            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                let chunkBaseOffset = currentOffset
                currentOffset += UInt64(chunk.count)

                var lineStart = chunk.startIndex
                var index = chunk.startIndex
                while index < chunk.endIndex {
                    if chunk[index] == 0x0A {
                        if droppingOversizedLine {
                            pending.removeAll(keepingCapacity: true)
                            droppingOversizedLine = false
                        } else if pending.isEmpty {
                            let line = chunk[lineStart..<index]
                            if !line.isEmpty && line.count <= maxJSONLLineBytes {
                                handleLine(line)
                            }
                        } else {
                            let segment = chunk[lineStart..<index]
                            if pending.count + segment.count <= maxJSONLLineBytes {
                                pending.append(contentsOf: segment)
                                handleLine(pending[pending.startIndex..<pending.endIndex])
                            }
                            pending.removeAll(keepingCapacity: true)
                        }
                        let nextIndex = chunk.index(after: index)
                        committedOffset = chunkBaseOffset + UInt64(chunk.distance(from: chunk.startIndex, to: nextIndex))
                        lineStart = nextIndex
                    }
                    index = chunk.index(after: index)
                }

                if lineStart < chunk.endIndex {
                    let tail = chunk[lineStart..<chunk.endIndex]
                    if !droppingOversizedLine {
                        if pending.count + tail.count > maxJSONLLineBytes {
                            pending.removeAll(keepingCapacity: true)
                            droppingOversizedLine = true
                        } else {
                            pending.append(contentsOf: tail)
                        }
                    }
                }
            }

            return droppingOversizedLine ? currentOffset : committedOffset
        } catch {
            return nil
        }
    }

    private static func fingerprint(for url: URL, upto offset: UInt64) -> String? {
        if offset == 0 {
            return "0:0:0"
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let length = min(offset, 4096)
            try handle.seek(toOffset: offset - length)
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return "\(offset):\(data.count):\(String(hash, radix: 16))"
        } catch {
            return nil
        }
    }

    private static func parseCodexFile(_ file: UsageFile, existing: CachedFile?, fullRebuild: Bool) -> ParseResult {
        let startOffset = fullRebuild ? 0 : (existing?.processedOffset ?? 0)
        var originator = existing?.originator ?? "unknown"
        var sessionId = fullRebuild ? nil : existing?.sessionId
        var sessionContributorID = fullRebuild ? nil : existing?.sessionContributorID
        var currentContributorID = fullRebuild ? nil : existing?.currentContributorID
        var totals = fullRebuild ? CodexTotals() : (existing?.lastCodexTotal ?? CodexTotals())
        var contributions: [String: CachedContribution] = [:]
        contributions.reserveCapacity(128)

        guard let endOffset = readJSONLLines(file.url, from: startOffset, handleLine: { lineData in
            guard lineContains(lineData, codexSessionMetaNeedle)
                    || lineContains(lineData, codexTurnContextNeedle)
                    || lineContains(lineData, codexTokenCountNeedle)
            else { return }

            autoreleasepool {
            let jsonData = Data(lineData)
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { return }

            if type == "session_meta" {
                originator = payload["originator"] as? String ?? originator
                sessionId = payload["id"] as? String ?? sessionId
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    let contributorID = redactedContributorID(from: cwd)
                    sessionContributorID = contributorID
                    currentContributorID = currentContributorID ?? contributorID
                }
                return
            }

            if type == "turn_context" {
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    currentContributorID = redactedContributorID(from: cwd)
                }
                return
            }

            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any]
            else { return }

            let curInput = jsonInt64(total["input_tokens"])
            let curCached = jsonInt64(total["cached_input_tokens"])
            let curOutput = jsonInt64(total["output_tokens"])
            let curReasoning = jsonInt64(total["reasoning_output_tokens"])
            let curTotal = jsonInt64(total["total_tokens"])

            let dInput = max(0, curInput - totals.inputTokens)
            let dCached = max(0, curCached - totals.cachedInputTokens)
            let dOutput = max(0, curOutput - totals.outputTokens)
            let dReasoning = max(0, curReasoning - totals.reasoningOutputTokens)
            let dTotal = max(0, curTotal - totals.totalTokens)

            totals = CodexTotals(
                inputTokens: curInput,
                cachedInputTokens: curCached,
                outputTokens: curOutput,
                reasoningOutputTokens: curReasoning,
                totalTokens: curTotal
            )

            guard dTotal > 0,
                  let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISOTimestamp(timestampText)
            else { return }

            let card = Pricing.codexDefault
            let freshInput = max(0, dInput - dCached)
            let cost =
                Double(freshInput) * card.inputUSDPerMillion / 1_000_000
                + Double(dCached) * card.cachedInputUSDPerMillion / 1_000_000
                + Double(dOutput) * card.outputUSDPerMillion / 1_000_000

            mergeContribution(CachedContribution(
                hourKey: hourKey(for: timestamp),
                tool: originator,
                contributorID: currentContributorID ?? sessionContributorID,
                sessionIds: [sessionId ?? file.url.deletingPathExtension().lastPathComponent],
                usage: TokenUsage(
                    inputTokens: dInput,
                    cachedInputTokens: dCached,
                    outputTokens: dOutput,
                    reasoningOutputTokens: dReasoning,
                    totalTokens: dTotal,
                    costUSD: cost
                ),
                tokenEvents: 1
            ), into: &contributions)
            }
        }) else {
            return ParseResult(
                originator: existing?.originator,
                lastCodexTotal: existing?.lastCodexTotal,
                claudeSeenMessageIds: existing?.claudeSeenMessageIds ?? [],
                contributions: [],
                processedOffset: startOffset,
                prefixFingerprint: existing?.prefixFingerprint,
                sessionId: existing?.sessionId,
                sessionContributorID: existing?.sessionContributorID,
                currentContributorID: existing?.currentContributorID
            )
        }

        return ParseResult(
            originator: originator,
            lastCodexTotal: totals,
            claudeSeenMessageIds: existing?.claudeSeenMessageIds ?? [],
            contributions: sortedContributions(contributions),
            processedOffset: endOffset,
            prefixFingerprint: fingerprint(for: file.url, upto: endOffset),
            sessionId: sessionId,
            sessionContributorID: sessionContributorID,
            currentContributorID: currentContributorID
        )
    }

    private static func parseClaudeFile(_ file: UsageFile, existing: CachedFile?, fullRebuild: Bool) -> ParseResult {
        let startOffset = fullRebuild ? 0 : (existing?.processedOffset ?? 0)
        var sessionId = fullRebuild ? nil : existing?.sessionId
        var currentContributorID = fullRebuild ? nil : existing?.currentContributorID
        var seen = Set(fullRebuild ? [] : (existing?.claudeSeenMessageIds ?? []))
        var contributions: [String: CachedContribution] = [:]
        contributions.reserveCapacity(128)

        guard let endOffset = readJSONLLines(file.url, from: startOffset, handleLine: { lineData in
            guard lineContains(lineData, claudeAssistantNeedle),
                  lineContains(lineData, usageNeedle)
            else { return }

            autoreleasepool {
            let jsonData = Data(lineData)
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISOTimestamp(timestampText),
                  let message = object["message"] as? [String: Any],
                  let apiUsage = message["usage"] as? [String: Any]
            else { return }

            sessionId = object["sessionId"] as? String ?? sessionId
            if let cwd = object["cwd"] as? String, !cwd.isEmpty {
                currentContributorID = redactedContributorID(from: cwd)
            }

            if let messageId = message["id"] as? String {
                if !seen.insert(messageId).inserted { return }
            }

            let rawInput = jsonInt64(apiUsage["input_tokens"])
            let cacheRead = jsonInt64(apiUsage["cache_read_input_tokens"])
            let cacheCreate = jsonInt64(apiUsage["cache_creation_input_tokens"])
            let output = jsonInt64(apiUsage["output_tokens"])

            let modelId = (message["model"] as? String) ?? "claude-opus"
            let card = Pricing.claude(modelId: modelId)
            let cost =
                Double(rawInput) * card.inputUSDPerMillion / 1_000_000
                + Double(cacheRead) * card.cachedInputUSDPerMillion / 1_000_000
                + Double(cacheCreate) * card.cacheWriteUSDPerMillion / 1_000_000
                + Double(output) * card.outputUSDPerMillion / 1_000_000

            let totalInput = rawInput + cacheRead + cacheCreate
            mergeContribution(CachedContribution(
                hourKey: hourKey(for: timestamp),
                tool: "claude-code",
                contributorID: currentContributorID ?? redactedContributorID(from: inferredClaudeProjectPath(from: file.url)),
                sessionIds: [sessionId ?? file.url.deletingPathExtension().lastPathComponent],
                usage: TokenUsage(
                    inputTokens: totalInput,
                    cachedInputTokens: cacheRead + cacheCreate,
                    outputTokens: output,
                    reasoningOutputTokens: 0,
                    totalTokens: totalInput + output,
                    costUSD: cost
                ),
                tokenEvents: 1
            ), into: &contributions)
            }
        }) else {
            return ParseResult(
                originator: "claude-code",
                lastCodexTotal: nil,
                claudeSeenMessageIds: existing?.claudeSeenMessageIds ?? [],
                contributions: [],
                processedOffset: startOffset,
                prefixFingerprint: existing?.prefixFingerprint,
                sessionId: existing?.sessionId,
                sessionContributorID: nil,
                currentContributorID: existing?.currentContributorID
            )
        }

        return ParseResult(
            originator: "claude-code",
            lastCodexTotal: nil,
            claudeSeenMessageIds: Array(seen),
            contributions: sortedContributions(contributions),
            processedOffset: endOffset,
            prefixFingerprint: fingerprint(for: file.url, upto: endOffset),
            sessionId: sessionId,
            sessionContributorID: nil,
            currentContributorID: currentContributorID
        )
    }

    private static func history(from cache: UsageCache) -> UsageHistory {
        UsageHistory(
            generatedAt: cache.generatedAt,
            hourlyUsageByTool: cache.hourlyUsageByTool,
            hourlyUsageByContributor: cache.hourlyUsageByContributor,
            hourlyContributorSessions: cache.hourlyContributorSessions,
            hourlyTokenEvents: cache.hourlyTokenEvents,
            scannedFiles: cache.files.count
        )
    }

    private static func snapshots(from history: UsageHistory) -> [Period: UsageSnapshot] {
        var out: [Period: UsageSnapshot] = [:]
        for period in Period.allCases {
            out[period] = history.snapshot(for: .current(period))
        }
        return out
    }

    private static func snapshot(period: Period, cache: UsageCache) -> UsageSnapshot {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let (rangeStart, rangeEnd) = PeriodMath.dateRange(for: period, now: now, calendar: calendar)
        let bucketCount = period.bucketCount(now: now, calendar: calendar)

        var byTool: [String: TokenUsage] = [:]
        var bucketsByTool: [String: [Int64]] = [:]
        var tokenEvents = 0

        func consume(hour: Date, bucketIndex: Int) {
            guard hour >= rangeStart, hour < rangeEnd else { return }
            let key = hourKey(for: hour)
            tokenEvents += cache.hourlyTokenEvents[key] ?? 0
            guard let tools = cache.hourlyUsageByTool[key] else { return }
            for (tool, usage) in tools {
                byTool[tool, default: TokenUsage()].add(usage)
                var buckets = bucketsByTool[tool] ?? Array(repeating: 0, count: bucketCount)
                buckets[bucketIndex] += usage.totalTokens
                bucketsByTool[tool] = buckets
            }
        }

        switch period {
        case .day:
            for hour in 0..<24 {
                guard let date = calendar.date(byAdding: .hour, value: hour, to: rangeStart) else { continue }
                consume(hour: date, bucketIndex: hour)
            }
        case .week, .month:
            for day in 0..<bucketCount {
                guard let dayStart = calendar.date(byAdding: .day, value: day, to: rangeStart) else { continue }
                for hour in 0..<24 {
                    guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { continue }
                    consume(hour: hourStart, bucketIndex: day)
                }
            }
        }

        return UsageSnapshot(
            generatedAt: cache.generatedAt.timeIntervalSince1970 > 0 ? cache.generatedAt : now,
            period: period,
            periodOffset: 0,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            bucketCount: bucketCount,
            byTool: byTool,
            bucketsByTool: bucketsByTool,
            topContributors: [],
            currentBucketIndex: PeriodMath.currentBucketIndex(for: period, now: now, rangeStart: rangeStart, calendar: calendar),
            scannedFiles: cache.files.count,
            tokenEvents: tokenEvents
        )
    }

    private static func hourKey(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0,
            comps.hour ?? 0
        )
    }
}

// MARK: - Compact formatting

private struct CompactNumber {
    let primary: String
    let unit: String
}

private func compactTokens(_ value: Int64) -> CompactNumber {
    let v = Double(value)
    if v >= 1_000_000_000 {
        return CompactNumber(primary: String(format: "%.1f", v / 1_000_000_000), unit: "B")
    }
    if v >= 1_000_000 {
        return CompactNumber(primary: String(format: "%.1f", v / 1_000_000), unit: "M")
    }
    if v >= 10_000 {
        return CompactNumber(primary: String(format: "%.0f", v / 1_000), unit: "K")
    }
    if v >= 1_000 {
        return CompactNumber(primary: String(format: "%.1f", v / 1_000), unit: "K")
    }
    if v >= 1 {
        return CompactNumber(primary: String(Int64(v)), unit: "")
    }
    return CompactNumber(primary: "0", unit: "")
}

private func compactString(_ value: Int64) -> String {
    let n = compactTokens(value)
    return n.primary + n.unit
}

private func breakdownTooltip(for usage: TokenUsage) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    func n(_ v: Int64) -> String { formatter.string(from: NSNumber(value: v)) ?? String(v) }
    let costLine = String(format: "Estimated API cost: $%.2f", usage.costUSD)
    return """
    Input \(n(usage.inputTokens))  ·  Output \(n(usage.outputTokens))
    Cached \(n(usage.cachedInputTokens))  ·  Reasoning \(n(usage.reasoningOutputTokens))
    Total \(n(usage.totalTokens))
    \(costLine)
    """
}

// MARK: - Warm ember palette

private extension NSColor {
    static let codexEmber = NSColor(name: "codexEmber") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.97, green: 0.69, blue: 0.40, alpha: 1.0)
            : NSColor(srgbRed: 0.76, green: 0.42, blue: 0.15, alpha: 1.0)
    }

    static let codexEmberDim = NSColor(name: "codexEmberDim") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.58, green: 0.44, blue: 0.30, alpha: 1.0)
            : NSColor(srgbRed: 0.85, green: 0.70, blue: 0.52, alpha: 1.0)
    }

    static let codexEmberGhost = NSColor(name: "codexEmberGhost") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.97, green: 0.69, blue: 0.40, alpha: 0.14)
            : NSColor(srgbRed: 0.76, green: 0.42, blue: 0.15, alpha: 0.10)
    }

    // Codex Desktop — pure golden yellow, well clear of the Codex CLI ember orange.
    static let codexAmber = NSColor(name: "codexAmber") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.97, green: 0.86, blue: 0.27, alpha: 1.0)
            : NSColor(srgbRed: 0.62, green: 0.50, blue: 0.05, alpha: 1.0)
    }

    // Claude Code — pink-magenta, deliberately cool relative to the Codex warm pair so
    // the three tools are easy to tell apart in the small stacked-bucket chart.
    static let codexCoral = NSColor(name: "codexCoral") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.95, green: 0.42, blue: 0.66, alpha: 1.0)
            : NSColor(srgbRed: 0.78, green: 0.20, blue: 0.46, alpha: 1.0)
    }

    static let codexPopoverBackground = NSColor(name: "codexPopoverBackground") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1.0)
            : NSColor(srgbRed: 0.985, green: 0.975, blue: 0.965, alpha: 1.0)
    }
}

// Stable accent per originator — colors don't shuffle based on today's ranking.
private func accentColor(for originator: String) -> NSColor {
    switch originator {
    case "codex-tui", "codex_cli_rs":
        return .codexEmber
    case "Codex Desktop":
        return .codexAmber
    case "claude-code":
        return .codexCoral
    default:
        return .codexEmberDim
    }
}

// MARK: - Popover background (solid, appearance-aware)

final class PopoverBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.codexPopoverBackground.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Motion primitives

private enum Easing {
    nonisolated(unsafe) static let outCubic = CAMediaTimingFunction(controlPoints: 0.33, 1.0, 0.68, 1.0)
    nonisolated(unsafe) static let outQuart = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
    nonisolated(unsafe) static let outExpo  = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
}

// MARK: - Bucket chart (N capsules, stacked by originator)
//
// Reused across periods: 24 buckets (hours) for `.day`, 7 for `.week`, 30 for `.month`.
// Container layer count matches the active bucket count and is rebuilt when the period
// changes.

final class BucketChartView: NSView {
    private struct BarColumn {
        let totalTokens: Int64
        // Ordered bottom → top; each element is (originator, tokens for that bucket).
        let segments: [(originator: String, tokens: Int64)]
    }

    /// Gap between bars. Wider when there are fewer bars so week view doesn't look cramped.
    /// Exposed so the axis strip can mirror the spacing for per-bar labels.
    static func gap(forBucketCount count: Int) -> CGFloat {
        count <= 7 ? 4 : 2
    }

    private var bucketCount: Int = 24
    private var barContainers: [CALayer] = []
    private var segmentLayers: [[CALayer]] = []
    private var columns: [BarColumn] = []
    private var currentBucket: Int = 0
    private var accentResolver: (String) -> NSColor = { _ in .codexEmber }

    private let hoverLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hoveredBucket: Int? {
        didSet {
            if oldValue != hoveredBucket { updateHoverLabel() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        hoverLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        hoverLabel.textColor = .labelColor
        hoverLabel.backgroundColor = .clear
        hoverLabel.drawsBackground = false
        hoverLabel.isBordered = false
        hoverLabel.isEditable = false
        hoverLabel.isSelectable = false
        hoverLabel.alignment = .center
        hoverLabel.isHidden = true
        addSubview(hoverLabel)

        rebuildContainers(count: bucketCount)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    override func layout() {
        super.layout()
        relayoutBars()
        refreshColors()
        updateHoverLabel()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHoveredBucket(from: event) }
    override func mouseMoved(with event: NSEvent) { updateHoveredBucket(from: event) }
    override func mouseExited(with event: NSEvent) { hoveredBucket = nil }

    private func updateHoveredBucket(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), bucketCount > 0 else {
            hoveredBucket = nil
            return
        }
        let gap = Self.gap(forBucketCount: bucketCount)
        let count = CGFloat(bucketCount)
        let totalGap = gap * (count - 1)
        let barWidth = max((bounds.width - totalGap) / count, 1)
        let step = barWidth + gap
        let raw = Int(floor(p.x / step))
        let idx = max(0, min(bucketCount - 1, raw))
        if columns.indices.contains(idx), columns[idx].totalTokens > 0 {
            hoveredBucket = idx
        } else {
            hoveredBucket = nil
        }
    }

    private func updateHoverLabel() {
        guard let idx = hoveredBucket,
              columns.indices.contains(idx),
              bounds.width > 0 else {
            hoverLabel.isHidden = true
            return
        }
        hoverLabel.stringValue = compactString(columns[idx].totalTokens)
        hoverLabel.sizeToFit()

        let gap = Self.gap(forBucketCount: bucketCount)
        let count = CGFloat(bucketCount)
        let totalGap = gap * (count - 1)
        let barWidth = max((bounds.width - totalGap) / count, 1)
        let barCenterX = CGFloat(idx) * (barWidth + gap) + barWidth / 2

        let labelWidth = hoverLabel.frame.width
        let labelHeight = hoverLabel.frame.height
        var x = barCenterX - labelWidth / 2
        x = max(0, min(bounds.width - labelWidth, x))
        let y = bounds.height + 4
        hoverLabel.frame = NSRect(x: x, y: y, width: labelWidth, height: labelHeight)
        hoverLabel.isHidden = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// Tear down and recreate one container layer per bucket. Only called when the period
    /// (hence bucket count) changes.
    private func rebuildContainers(count: Int) {
        hoveredBucket = nil
        for c in barContainers { c.removeFromSuperlayer() }
        barContainers.removeAll()
        segmentLayers = Array(repeating: [], count: count)
        columns = Array(repeating: BarColumn(totalTokens: 0, segments: []), count: count)

        let noImplicit: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
            "backgroundColor": NSNull(),
            "borderWidth": NSNull(),
            "borderColor": NSNull(),
            "cornerRadius": NSNull(),
            "masksToBounds": NSNull()
        ]
        for _ in 0..<count {
            let container = CALayer()
            container.anchorPoint = CGPoint(x: 0.5, y: 0)
            container.actions = noImplicit
            layer?.addSublayer(container)
            barContainers.append(container)
        }
        bucketCount = count
    }

    /// `orderedOriginators`: stable originator ordering (biggest first). Bottom of the stack is
    /// the first in this list; segments stack upward in that order.
    func update(
        bucketsByTool: [String: [Int64]],
        bucketCount: Int,
        orderedOriginators: [String],
        currentBucket: Int,
        accentResolver: @escaping (String) -> NSColor
    ) {
        if bucketCount != self.bucketCount {
            rebuildContainers(count: bucketCount)
        }
        self.currentBucket = max(0, min(bucketCount - 1, currentBucket))
        self.accentResolver = accentResolver

        var newColumns: [BarColumn] = []
        newColumns.reserveCapacity(bucketCount)
        for i in 0..<bucketCount {
            var segs: [(String, Int64)] = []
            var total: Int64 = 0
            for origin in orderedOriginators {
                let v = bucketsByTool[origin]?[i] ?? 0
                if v > 0 {
                    segs.append((origin, v))
                    total += v
                }
            }
            newColumns.append(BarColumn(totalTokens: total, segments: segs))
        }
        self.columns = newColumns
        rebuildSegmentLayers()
        relayoutBars()
        refreshColors()
    }

    private func rebuildSegmentLayers() {
        for segs in segmentLayers {
            for l in segs { l.removeFromSuperlayer() }
        }
        segmentLayers = Array(repeating: [], count: bucketCount)

        let noImplicit: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull()
        ]
        for i in 0..<bucketCount {
            let container = barContainers[i]
            var created: [CALayer] = []
            for _ in columns[i].segments {
                let l = CALayer()
                l.anchorPoint = CGPoint(x: 0.5, y: 0)  // grow upward from segment base
                l.actions = noImplicit
                container.addSublayer(l)
                created.append(l)
            }
            segmentLayers[i] = created
        }
    }

    private func relayoutBars() {
        guard bounds.width > 0, bounds.height > 0, bucketCount > 0 else { return }
        let gap = Self.gap(forBucketCount: bucketCount)
        let count = CGFloat(bucketCount)
        let totalGap = gap * (count - 1)
        let barWidth = max((bounds.width - totalGap) / count, 1)
        let radius = min(barWidth / 2, 2)
        // Filled-pill baseline (past zero days). Future-day outlined pills get bumped slightly
        // taller so the 1px stroke reads as a pill, not a hairline.
        let zeroBaseline: CGFloat = 2
        let futureBaseline: CGFloat = 4

        let maxVal = CGFloat(max(columns.map(\.totalTokens).max() ?? 0, 1))

        for i in 0..<bucketCount {
            let column = columns[i]
            let total = CGFloat(column.totalTokens)
            let h: CGFloat
            if total > 0 {
                let normalized = max(0.18, total / maxVal)
                h = max((bounds.height - 2) * normalized, zeroBaseline)
            } else {
                h = i > currentBucket ? futureBaseline : zeroBaseline
            }

            let x = CGFloat(i) * (barWidth + gap)
            let container = barContainers[i]
            container.bounds = CGRect(x: 0, y: 0, width: barWidth, height: h)
            container.position = CGPoint(x: x + barWidth / 2, y: 0)
            container.cornerRadius = radius
            container.masksToBounds = true

            let layers = segmentLayers[i]
            guard total > 0, !layers.isEmpty else { continue }

            var yOffset: CGFloat = 0
            for (idx, segment) in column.segments.enumerated() where idx < layers.count {
                let frac = CGFloat(segment.tokens) / total
                let segH = max(h * frac, 0.5)
                let l = layers[idx]
                l.bounds = CGRect(x: 0, y: 0, width: barWidth, height: segH)
                l.position = CGPoint(x: barWidth / 2, y: yOffset)
                yOffset += segH
            }
        }
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            for i in 0..<bucketCount {
                let column = columns[i]
                let container = barContainers[i]
                let layers = segmentLayers[i]

                if column.totalTokens == 0 || layers.isEmpty {
                    if i > currentBucket {
                        // Future day: outlined pill — same shape so the chart's rhythm holds,
                        // but unfilled to show "hasn't happened yet" vs. a past zero-usage day.
                        container.backgroundColor = nil
                        container.borderWidth = 1
                        container.borderColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor
                    } else {
                        // Past or current day with no usage: filled baseline pill.
                        container.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.45).cgColor
                        container.borderWidth = 0
                    }
                    continue
                }
                container.backgroundColor = nil
                container.borderWidth = 0

                // Slight dim for past/future buckets; full brightness for the current one.
                let alpha: CGFloat
                if i == currentBucket { alpha = 1.0 }
                else if i < currentBucket { alpha = 0.85 }
                else { alpha = 0.5 }

                for (idx, segment) in column.segments.enumerated() where idx < layers.count {
                    let color = accentResolver(segment.originator).withAlphaComponent(alpha)
                    layers[idx].backgroundColor = color.cgColor
                }
            }
        }
    }

    func prepareForEntry() {
        hoveredBucket = nil
        for c in barContainers {
            c.removeAllAnimations()
            c.transform = CATransform3DScale(CATransform3DIdentity, 1, 0.001, 1)
        }
    }

    func playEntryAnimation() {
        let base = CACurrentMediaTime() + 0.12
        // Faster stagger when there are more bars so the whole chart still settles together.
        let perBarStagger = bucketCount <= 7 ? 0.04 : 0.014
        var lastEnd: CFTimeInterval = base
        for i in 0..<bucketCount {
            let c = barContainers[i]
            c.transform = CATransform3DIdentity

            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = 0.001
            anim.toValue = 1.0
            anim.duration = 0.52
            anim.beginTime = base + Double(i) * perBarStagger
            anim.timingFunction = Easing.outExpo
            anim.fillMode = .backwards
            c.add(anim, forKey: "entry-scale")
            lastEnd = max(lastEnd, anim.beginTime + anim.duration)
        }

        // Breathing pulse on the current-bucket bar, once entry settles.
        if (0..<bucketCount).contains(currentBucket), columns[currentBucket].totalTokens > 0 {
            let c = barContainers[currentBucket]
            c.removeAnimation(forKey: "pulse")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.55
            pulse.duration = 1.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = Easing.outCubic
            pulse.beginTime = lastEnd
            pulse.fillMode = .backwards
            c.add(pulse, forKey: "pulse")
        }
    }
}

// MARK: - Axis strip (labels under the bucket chart)
//
// Two render modes:
//   - 3-label "edge" mode (day, month):  e.g. "00 · 12 · 24"  or  "1 · 15 · 31"
//   - per-bar mode (week):  one short label centered under each bar, with today emphasized

final class AxisContainerView: NSView {
    private var labels: [NSTextField] = []
    /// Mode is implicit in the layout strategy; nil = edge (3 labels), non-nil = per-bar.
    private var perBarHighlightIndex: Int? = nil
    /// Gap used by the chart (kept in sync via setBarLabels) so per-bar labels align under bars.
    private var perBarGap: CGFloat = 4

    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .kern: 0.6
    ]
    private static let labelAttrsHighlighted: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.labelColor,
        .kern: 0.6
    ]

    init() {
        super.init(frame: .zero)
        setLabels(start: "00", mid: "12", end: "24")
    }

    required init?(coder: NSCoder) { nil }

    /// Edge mode — 3 labels at left / center / right.
    func setLabels(start: String, mid: String, end: String) {
        perBarHighlightIndex = nil
        rebuildLabels([start, mid, end])
        needsLayout = true
    }

    /// Per-bar mode — one label per slot, optionally highlighting one (today).
    func setBarLabels(_ texts: [String], highlightedIndex: Int?, gap: CGFloat) {
        perBarHighlightIndex = highlightedIndex
        perBarGap = gap
        rebuildLabels(texts, highlightAt: highlightedIndex)
        needsLayout = true
    }

    private func rebuildLabels(_ texts: [String], highlightAt: Int? = nil) {
        // Reuse existing fields where possible; add/remove to match count.
        while labels.count < texts.count {
            let f = NSTextField(labelWithString: "")
            addSubview(f)
            labels.append(f)
        }
        while labels.count > texts.count {
            labels.removeLast().removeFromSuperview()
        }
        for (i, text) in texts.enumerated() {
            let attrs = (highlightAt == i) ? Self.labelAttrsHighlighted : Self.labelAttrs
            labels[i].attributedStringValue = NSAttributedString(string: text, attributes: attrs)
            labels[i].sizeToFit()
        }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, !labels.isEmpty else { return }
        for l in labels { l.sizeToFit() }
        let y: CGFloat = 0

        if perBarHighlightIndex != nil {
            // Center each label under its bar, mirroring BucketChartView.relayoutBars math.
            let count = CGFloat(labels.count)
            let totalGap = perBarGap * (count - 1)
            let barWidth = max((bounds.width - totalGap) / count, 1)
            for (i, l) in labels.enumerated() {
                let center = CGFloat(i) * (barWidth + perBarGap) + barWidth / 2
                let x = max(0, min(bounds.width - l.frame.width, center - l.frame.width / 2))
                l.frame.origin = CGPoint(x: x, y: y)
            }
        } else if labels.count == 3 {
            labels[0].frame.origin = CGPoint(x: 0, y: y)
            labels[1].frame.origin = CGPoint(x: (bounds.width - labels[1].frame.width) / 2, y: y)
            labels[2].frame.origin = CGPoint(x: bounds.width - labels[2].frame.width, y: y)
        }
    }
}

// MARK: - Breakdown row (INPUT / CACHED / OUTPUT columns under the hero)

final class BreakdownRowView: NSView {
    private struct Column {
        let label: NSTextField
        let value: NSTextField
    }

    private let columns: [Column]
    private let labelValueGap: CGFloat = 4

    init(titles: [String]) {
        var built: [Column] = []
        for title in titles {
            let label = NSTextField(labelWithString: "")
            let value = NSTextField(labelWithString: "")
            label.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.5
            ])
            built.append(Column(label: label, value: value))
        }
        self.columns = built
        super.init(frame: .zero)
        for col in columns {
            addSubview(col.label)
            addSubview(col.value)
        }
    }

    required init?(coder: NSCoder) { nil }

    func setValues(_ values: [Int64]) {
        for (i, v) in values.enumerated() where i < columns.count {
            columns[i].value.attributedStringValue = NSAttributedString(
                string: compactString(v),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .kern: 0.2
                ]
            )
        }
        for col in columns {
            col.label.sizeToFit()
            col.value.sizeToFit()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, !columns.isEmpty else { return }
        let colWidth = bounds.width / CGFloat(columns.count)
        for (i, col) in columns.enumerated() {
            col.label.sizeToFit()
            col.value.sizeToFit()
            let x = CGFloat(i) * colWidth
            // Value at bottom of container, label above with small gap.
            col.value.frame.origin = CGPoint(x: x, y: 0)
            col.label.frame.origin = CGPoint(x: x, y: col.value.frame.height + labelValueGap)
        }
    }
}

// MARK: - Tool row (name + value, thin share hairline beneath)

final class ToolRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let shareLabel = NSTextField(labelWithString: "")
    /// Estimated API cost for this tool's tokens — small/tertiary, sits between
    /// the tool name and the share %. Always shown, even when the user is on a
    /// flat-rate plan, so the number serves as an API-equivalent reference.
    private let costLabel = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private var shareFraction: CGFloat = 0
    private var accent: NSColor = .codexEmber
    private let rowHeight: CGFloat = 24
    private let hairlineHeight: CGFloat = 2

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false

        // All four labels use manual frames — autolayout was squeezing the right-aligned ones to 4pt.
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.alignment = .right
        shareLabel.alignment = .right
        costLabel.alignment = .right
        addSubview(nameLabel)
        addSubview(costLabel)
        addSubview(shareLabel)
        addSubview(valueLabel)

        track.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        fill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        // Fill scales from its LEFT edge during entry animation, so anchor the layer there.
        // Critical: set anchorPoint before positioning — changing it after shifts the layer.
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)

        heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func configure(name: String, usage: TokenUsage, accent: NSColor, total: Int64) {
        self.accent = accent
        shareFraction = total > 0 ? CGFloat(usage.totalTokens) / CGFloat(total) : 0

        nameLabel.attributedStringValue = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .kern: 0.1
        ])
        valueLabel.attributedStringValue = NSAttributedString(string: compactString(usage.totalTokens), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .kern: 0.2
        ])
        let sharePct = Int((shareFraction * 100).rounded())
        shareLabel.attributedStringValue = NSAttributedString(string: "\(sharePct)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.3
        ])
        costLabel.attributedStringValue = NSAttributedString(string: compactCost(usage.costUSD), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.3
        ])

        nameLabel.sizeToFit()
        costLabel.sizeToFit()
        shareLabel.sizeToFit()
        valueLabel.sizeToFit()

        toolTip = breakdownTooltip(for: usage)
        needsLayout = true
        refreshColors()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }

        let textY = rowHeight - 8 - max(nameLabel.frame.height, valueLabel.frame.height)
        // Right-anchor value, then share, then cost — and give name whatever's left.
        let valueW = valueLabel.frame.width
        let valueX = bounds.width - valueW
        valueLabel.frame = CGRect(x: valueX, y: textY, width: valueW, height: valueLabel.frame.height)

        let shareW = shareLabel.frame.width
        let shareX = valueX - 10 - shareW
        shareLabel.frame = CGRect(x: shareX, y: textY, width: shareW, height: shareLabel.frame.height)

        let costW = costLabel.frame.width
        let costX = shareX - 10 - costW
        costLabel.frame = CGRect(x: costX, y: textY, width: costW, height: costLabel.frame.height)

        let nameMaxW = max(costX - 10, 0)
        nameLabel.frame = CGRect(x: 0, y: textY, width: nameMaxW, height: nameLabel.frame.height)

        // Track uses default anchor (0.5, 0.5): position at center of its frame.
        track.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: hairlineHeight)
        track.position = CGPoint(x: bounds.width / 2, y: hairlineHeight / 2)
        track.cornerRadius = hairlineHeight / 2
        track.masksToBounds = true

        // Fill uses anchor (0, 0.5): position is the layer's left-center, so scaling x grows rightward.
        let fillWidth = max(bounds.width * shareFraction, hairlineHeight)
        fill.bounds = CGRect(x: 0, y: 0, width: fillWidth, height: hairlineHeight)
        fill.position = CGPoint(x: 0, y: hairlineHeight / 2)
        fill.cornerRadius = hairlineHeight / 2
        fill.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [track, fill, accent] in
            track.backgroundColor = NSColor.codexEmberGhost.cgColor
            fill.backgroundColor = accent.cgColor
        }
    }

    func animateFillIn(delay: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = 0.001
        anim.toValue = 1.0
        anim.duration = 0.6
        anim.beginTime = CACurrentMediaTime() + delay
        anim.timingFunction = Easing.outExpo
        anim.fillMode = .backwards
        fill.add(anim, forKey: "fill")
    }
}

// MARK: - Drivers dropdown

final class ContributorRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let rowHeight: CGFloat = 18

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.alignment = .right
        addSubview(nameLabel)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { nil }

    func configure(with contributor: ContributorSummary) {
        nameLabel.attributedStringValue = NSAttributedString(string: contributor.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .kern: 0.1
        ])
        valueLabel.attributedStringValue = NSAttributedString(
            string: "\(compactString(contributor.usage.totalTokens)) · \(compactCost(contributor.usage.costUSD))",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.2
            ]
        )
        toolTip = nil
        nameLabel.sizeToFit()
        valueLabel.sizeToFit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        nameLabel.sizeToFit()
        valueLabel.sizeToFit()

        let y = max(0, (rowHeight - max(nameLabel.frame.height, valueLabel.frame.height)) / 2)
        let valueW = valueLabel.frame.width
        valueLabel.frame = CGRect(x: bounds.width - valueW, y: y, width: valueW, height: valueLabel.frame.height)

        let nameMaxW = max(valueLabel.frame.minX - 12, 0)
        nameLabel.frame = CGRect(x: 0, y: y, width: nameMaxW, height: nameLabel.frame.height)
    }
}

final class DriversDropdownView: NSView {
    private let stack = NSStackView()
    private let headerButton = NSButton()
    private let rowsStack = NSStackView()
    private var expanded = false
    private var contributors: [ContributorSummary] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        headerButton.bezelStyle = .inline
        headerButton.isBordered = false
        headerButton.alignment = .left
        headerButton.imagePosition = .imageLeading
        headerButton.contentTintColor = .tertiaryLabelColor
        headerButton.target = self
        headerButton.action = #selector(toggle)
        headerButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(headerButton)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 3
        rowsStack.isHidden = true
        stack.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        updateHeader()
    }

    required init?(coder: NSCoder) { nil }

    func configure(contributors: [ContributorSummary]) {
        self.contributors = contributors
        isHidden = contributors.isEmpty

        rowsStack.arrangedSubviews.forEach { sub in
            rowsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        for contributor in contributors {
            let row = ContributorRowView()
            row.configure(with: contributor)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        if contributors.isEmpty {
            resetCollapsed()
        } else {
            updateExpandedState()
        }
    }

    func resetCollapsed() {
        expanded = false
        updateExpandedState()
    }

    @objc private func toggle() {
        guard !contributors.isEmpty else { return }
        expanded.toggle()
        updateExpandedState()
    }

    private func updateExpandedState() {
        rowsStack.isHidden = !expanded
        updateHeader()
        needsLayout = true
    }

    private func updateHeader() {
        headerButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Hide drivers" : "Show drivers"
        )
        headerButton.attributedTitle = NSAttributedString(string: "DRIVERS", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.8
        ])
    }
}

// MARK: - Provider settings panel

private enum ConfigurableProvider {
    case codex
    case claudeCode

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }

    var defaultPaths: [String] {
        switch self {
        case .codex:
            return ProviderPathConfig.defaultCodexRoots()
        case .claudeCode:
            return ProviderPathConfig.defaultClaudeCodeRoots()
        }
    }

    func paths(from selectedURL: URL) -> [String] {
        let selected = selectedURL.standardizedFileURL
        let fileManager = FileManager.default

        switch self {
        case .codex:
            let sessions = selected.appendingPathComponent("sessions", isDirectory: true)
            let archived = selected.appendingPathComponent("archived_sessions", isDirectory: true)
            if selected.lastPathComponent == ".codex"
                || fileManager.fileExists(atPath: sessions.path)
                || fileManager.fileExists(atPath: archived.path) {
                return [sessions.path, archived.path]
            }
            return [selected.path]

        case .claudeCode:
            let projects = selected.appendingPathComponent("projects", isDirectory: true)
            if selected.lastPathComponent == ".claude"
                || fileManager.fileExists(atPath: projects.path) {
                return [projects.path]
            }
            return [selected.path]
        }
    }
}

private struct ProviderPathStatus {
    var blockingMessage: String?
    var warningMessage: String?
}

private func existingDirectoryURL(for path: String) -> URL? {
    let standardized = standardizedProviderPath(path)
    guard !standardized.isEmpty else { return nil }
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
          isDirectory.boolValue
    else { return nil }
    return URL(fileURLWithPath: standardized, isDirectory: true)
}

private func containsJSONLFile(in root: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return false }

    var checked = 0
    for case let url as URL in enumerator {
        if url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                return true
            }
        }
        checked += 1
        if checked > 4_000 {
            return false
        }
    }
    return false
}

@MainActor
private final class ProviderPathRowView: NSView {
    var onChange: (() -> Void)?

    private let provider: ConfigurableProvider
    private var enabled: Bool
    private var paths: [String]

    private let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Choose Folder...", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)

    init(provider: ConfigurableProvider, enabled: Bool, paths: [String]) {
        self.provider = provider
        self.enabled = enabled
        self.paths = paths.isEmpty ? provider.defaultPaths : paths
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    var isProviderEnabled: Bool { enabled }
    var configuredPaths: [String] { paths.map(standardizedProviderPath).filter { !$0.isEmpty } }
    var hasBlockingError: Bool { validationStatus().blockingMessage != nil }
    var firstBlockingError: String? { validationStatus().blockingMessage }

    private func buildView() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        refreshBorderColor()

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.widthAnchor.constraint(equalToConstant: 420).isActive = true

        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.attributedStringValue = NSAttributedString(string: provider.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded

        resetButton.target = self
        resetButton.action = #selector(resetPath)
        resetButton.bezelStyle = .rounded

        header.addArrangedSubview(enabledButton)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(chooseButton)
        header.addArrangedSubview(resetButton)
        outer.addArrangedSubview(header)

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 3
        pathLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        outer.addArrangedSubview(pathLabel)

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        outer.addArrangedSubview(statusLabel)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorderColor()
    }

    private func refreshBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        }
    }

    private func validationStatus() -> ProviderPathStatus {
        guard enabled else { return ProviderPathStatus(blockingMessage: nil, warningMessage: nil) }

        let normalized = configuredPaths
        let existing = normalized.compactMap(existingDirectoryURL)
        if existing.isEmpty {
            return ProviderPathStatus(
                blockingMessage: "\(provider.displayName): folder not found",
                warningMessage: nil
            )
        }

        if existing.count < normalized.count {
            return ProviderPathStatus(
                blockingMessage: nil,
                warningMessage: "\(provider.displayName): some folders are missing"
            )
        }

        if !existing.contains(where: containsJSONLFile) {
            return ProviderPathStatus(
                blockingMessage: nil,
                warningMessage: "\(provider.displayName): no JSONL files found"
            )
        }

        return ProviderPathStatus(blockingMessage: nil, warningMessage: nil)
    }

    private func refresh() {
        enabledButton.state = enabled ? .on : .off
        chooseButton.isEnabled = enabled

        let pathText = configuredPaths
            .map(displayProviderPath)
            .joined(separator: "\n")
        pathLabel.attributedStringValue = NSAttributedString(string: pathText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        ])

        let status = validationStatus()
        if let error = status.blockingMessage {
            statusLabel.isHidden = false
            statusLabel.attributedStringValue = NSAttributedString(string: error, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemRed
            ])
        } else if let warning = status.warningMessage {
            statusLabel.isHidden = false
            statusLabel.attributedStringValue = NSAttributedString(string: warning, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemOrange
            ])
        } else {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        }
    }

    @objc private func enabledChanged() {
        enabled = enabledButton.state == .on
        refresh()
        onChange?()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Choose \(provider.displayName) Folder"
        panel.prompt = "Choose"
        panel.directoryURL = configuredPaths.compactMap(existingDirectoryURL).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        paths = provider.paths(from: url)
        refresh()
        onChange?()
    }

    @objc private func resetPath() {
        enabled = true
        paths = provider.defaultPaths
        refresh()
        onChange?()
    }
}

@MainActor
private final class SettingsBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class ProviderSettingsViewController: NSViewController {
    var onSave: ((AppConfig) -> Void)?
    var onThemeChange: ((ThemePreference) -> Void)?
    var onCancel: (() -> Void)?

    private let codexRow: ProviderPathRowView
    private let claudeRow: ProviderPathRowView
    private let themeControl = NSSegmentedControl(
        labels: ThemePreference.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var themePreference: ThemePreference

    init(config: AppConfig) {
        let normalized = config.normalized()
        self.themePreference = normalized.themePreference
        self.codexRow = ProviderPathRowView(
            provider: .codex,
            enabled: normalized.providerPaths.codexEnabled,
            paths: normalized.providerPaths.codexRoots
        )
        self.claudeRow = ProviderPathRowView(
            provider: .claudeCode,
            enabled: normalized.providerPaths.claudeCodeEnabled,
            paths: normalized.providerPaths.claudeCodeRoots
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 480, height: 370))
        container.wantsLayer = true
        view = container

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = NSAttributedString(string: "Settings", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        root.addArrangedSubview(title)

        let themeRow = NSStackView()
        themeRow.orientation = .horizontal
        themeRow.alignment = .centerY
        themeRow.spacing = 12
        themeRow.widthAnchor.constraint(equalToConstant: 436).isActive = true

        let themeLabel = NSTextField(labelWithString: "")
        themeLabel.attributedStringValue = NSAttributedString(string: "Theme", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        themeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let themeSpacer = NSView()
        themeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        themeControl.segmentStyle = .rounded
        themeControl.target = self
        themeControl.action = #selector(themeChanged)
        themeControl.selectedSegment = ThemePreference.allCases.firstIndex(of: themePreference) ?? 0
        themeControl.translatesAutoresizingMaskIntoConstraints = false
        themeControl.widthAnchor.constraint(equalToConstant: 220).isActive = true

        themeRow.addArrangedSubview(themeLabel)
        themeRow.addArrangedSubview(themeSpacer)
        themeRow.addArrangedSubview(themeControl)
        root.addArrangedSubview(themeRow)

        codexRow.onChange = { [weak self] in self?.refreshSaveState() }
        claudeRow.onChange = { [weak self] in self?.refreshSaveState() }
        root.addArrangedSubview(codexRow)
        root.addArrangedSubview(claudeRow)

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.widthAnchor.constraint(equalToConstant: 436).isActive = true
        root.addArrangedSubview(statusLabel)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: 436).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded

        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(saveButton)
        root.addArrangedSubview(footer)

        refreshSaveState()
    }

    private var currentConfig: AppConfig {
        AppConfig(
            providerPaths: ProviderPathConfig(
                codexEnabled: codexRow.isProviderEnabled,
                codexRoots: codexRow.configuredPaths,
                claudeCodeEnabled: claudeRow.isProviderEnabled,
                claudeCodeRoots: claudeRow.configuredPaths
            ),
            themePreference: themePreference
        ).normalized()
    }

    private func refreshSaveState() {
        let firstError = codexRow.firstBlockingError ?? claudeRow.firstBlockingError
        saveButton.isEnabled = firstError == nil

        if let firstError {
            statusLabel.isHidden = false
            statusLabel.attributedStringValue = NSAttributedString(string: firstError, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemRed
            ])
        } else {
            statusLabel.isHidden = false
            statusLabel.attributedStringValue = NSAttributedString(
                string: "Config: \(displayProviderPath(AppConfigManager.configURL.path))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
        }
    }

    func showError(_ message: String) {
        statusLabel.isHidden = false
        statusLabel.attributedStringValue = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemRed
        ])
    }

    @objc private func saveClicked() {
        guard !codexRow.hasBlockingError, !claudeRow.hasBlockingError else {
            refreshSaveState()
            return
        }
        onSave?(currentConfig)
    }

    @objc private func themeChanged() {
        guard (0..<ThemePreference.allCases.count).contains(themeControl.selectedSegment) else { return }
        themePreference = ThemePreference.allCases[themeControl.selectedSegment]
        onThemeChange?(themePreference)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

@MainActor
private final class ProviderSettingsWindowController: NSWindowController, NSWindowDelegate {
    let settingsViewController: ProviderSettingsViewController
    var onClose: (() -> Void)?

    init(config: AppConfig) {
        settingsViewController = ProviderSettingsViewController(config: config)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 370),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.contentViewController = settingsViewController
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Period selector
//
// Three kerned-caps labels (DAY · WEEK · MONTH) with a tiny ember underline that animates
// between segments. Custom rather than NSSegmentedControl because the popover's design
// language is built on hairlines and tracking, and the stock control is too chrome-heavy.

final class PeriodSelectorView: NSView {
    var onSelect: ((Period) -> Void)?
    private(set) var selectedPeriod: Period = .day

    private let buttons: [NSButton]
    private let indicator = CALayer()
    private let segments: CGFloat = CGFloat(Period.allCases.count)

    override init(frame frameRect: NSRect) {
        buttons = Period.allCases.map { _ in
            let b = NSButton()
            b.bezelStyle = .inline
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            return b
        }
        super.init(frame: frameRect)
        wantsLayer = true
        for (i, b) in buttons.enumerated() {
            b.tag = i
            b.target = self
            b.action = #selector(buttonClicked(_:))
            addSubview(b)
        }
        indicator.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull(),
            "cornerRadius": NSNull()
        ]
        indicator.cornerRadius = 1
        layer?.addSublayer(indicator)
        applyTitles()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    func setPeriod(_ p: Period, animated: Bool) {
        guard p != selectedPeriod else { return }
        selectedPeriod = p
        applyTitles()
        layoutIndicator(animated: animated)
    }

    private func applyTitles() {
        for (i, b) in buttons.enumerated() {
            let active = (i == selectedPeriod.rawValue)
            let color: NSColor = active ? .labelColor : .tertiaryLabelColor
            b.attributedTitle = NSAttributedString(
                string: Period(rawValue: i)!.segmentTitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: active ? .bold : .semibold),
                    .foregroundColor: color,
                    .kern: 1.8
                ]
            )
            b.sizeToFit()
        }
        needsLayout = true
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let p = Period(rawValue: sender.tag), p != selectedPeriod else { return }
        setPeriod(p, animated: true)
        onSelect?(p)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let segW = bounds.width / segments
        for (i, b) in buttons.enumerated() {
            b.sizeToFit()
            let x = CGFloat(i) * segW + (segW - b.frame.width) / 2
            let y = (bounds.height - b.frame.height) / 2 + 2  // 2pt nudge to leave room for the underline
            b.frame.origin = CGPoint(x: x, y: y)
        }
        layoutIndicator(animated: false)
    }

    private func layoutIndicator(animated: Bool) {
        guard bounds.width > 0 else { return }
        let segW = bounds.width / segments
        let i = CGFloat(selectedPeriod.rawValue)
        let indicatorWidth: CGFloat = 18
        let x = i * segW + (segW - indicatorWidth) / 2
        let frame = CGRect(x: x, y: 0, width: indicatorWidth, height: 2)
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.34)
            CATransaction.setAnimationTimingFunction(Easing.outExpo)
            indicator.frame = frame
            CATransaction.commit()
        } else {
            indicator.frame = frame
        }
        refreshIndicatorColor()
    }

    private func refreshIndicatorColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [indicator] in
            indicator.backgroundColor = NSColor.codexEmber.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshIndicatorColor()
    }
}

// MARK: - Popover view controller

final class UsageViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPeriodChange: ((Period) -> Void)?
    var onNavigatePeriod: ((Int) -> Void)?

    private let datelineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()
    private let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
    private let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    /// Single-letter weekday (M, T, W, T, F, S, S in en-US) for the per-bar week axis.
    private let weekdayLetterFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()
    /// Long month + year for the month dateline ("May 2026").
    private let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMy")
        return f
    }()
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HHmm")
        return f
    }()

    private let contentInsetX: CGFloat = 24
    private let contentWidth: CGFloat = 292  // 340 popover − 2 × 24

    private let datelineLabel = NSTextField(labelWithString: "")
    private let periodSelector = PeriodSelectorView()
    private let heroNumberLabel = NSTextField(labelWithString: "")
    private let heroCaptionLabel = NSTextField(labelWithString: "")
    private let breakdownRow = BreakdownRowView(titles: ["INPUT", "CACHED", "OUTPUT"])
    private let chart = BucketChartView()
    private let axisContainer = AxisContainerView()
    private let toolsStack = NSStackView()
    private let noDataLabel = NSTextField(labelWithString: "")
    private let driversDropdown = DriversDropdownView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let previousPeriodButton = NSButton()
    private let nextPeriodButton = NSButton()
    private let settingsButton = NSButton()
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let quitButton = NSButton()
    private let root = NSStackView()
    private let topPadding: CGFloat = 18
    private let bottomPadding: CGFloat = 16

    private var animatedSubviews: [NSView] = []
    private var heroCountTask: Task<Void, Never>?
    private var lastHeroTarget: Int64 = 0

    override func loadView() {
        let container = PopoverBackgroundView(frame: NSRect(x: 0, y: 0, width: 340, height: 320))
        container.wantsLayer = true
        self.view = container

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: contentInsetX),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -contentInsetX),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: topPadding),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: bottomPadding)
        ])

        // Header: dateline + refresh
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.distribution = .fill
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        datelineLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        datelineLabel.textColor = .tertiaryLabelColor
        datelineLabel.lineBreakMode = .byTruncatingTail
        datelineLabel.maximumNumberOfLines = 1
        datelineLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        datelineLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureNavigationButton(
            previousPeriodButton,
            symbolName: "chevron.left",
            accessibilityDescription: "Previous period",
            action: #selector(previousPeriodClicked)
        )
        previousPeriodButton.toolTip = "Previous period"

        configureNavigationButton(
            nextPeriodButton,
            symbolName: "chevron.right",
            accessibilityDescription: "Next period",
            action: #selector(nextPeriodClicked)
        )
        nextPeriodButton.toolTip = "Next period"

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.bezelStyle = .regularSquare
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .tertiaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        settingsButton.toolTip = "Settings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 16).isActive = true

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.imagePosition = .imageOnly
        refreshButton.bezelStyle = .regularSquare
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .tertiaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        refreshButton.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        refreshButton.toolTip = "Refresh"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.usesThreadedAnimation = true
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // Fixed-size overlay so swapping spinner<>refresh-button never changes the header height
        // and no layout shift propagates through the popover.
        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconSlot.heightAnchor.constraint(equalToConstant: 16).isActive = true

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(refreshButton)
        iconSlot.addSubview(spinner)
        NSLayoutConstraint.activate([
            refreshButton.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 16),
            refreshButton.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14)
        ])

        header.addArrangedSubview(datelineLabel)
        header.addArrangedSubview(headerSpacer)
        header.addArrangedSubview(previousPeriodButton)
        header.addArrangedSubview(nextPeriodButton)
        header.addArrangedSubview(settingsButton)
        header.addArrangedSubview(iconSlot)
        root.addArrangedSubview(header)

        root.setCustomSpacing(14, after: header)

        // Period selector: DAY · WEEK · MONTH
        periodSelector.translatesAutoresizingMaskIntoConstraints = false
        periodSelector.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        periodSelector.heightAnchor.constraint(equalToConstant: 22).isActive = true
        periodSelector.onSelect = { [weak self] period in
            self?.onPeriodChange?(period)
        }
        root.addArrangedSubview(periodSelector)

        // Generous gap so the hero's 54pt ultralight ascenders never crash into the underline.
        root.setCustomSpacing(34, after: periodSelector)

        // Hero number — pin width so count-up doesn't reflow the popover
        heroNumberLabel.lineBreakMode = .byClipping
        heroNumberLabel.maximumNumberOfLines = 1
        heroNumberLabel.cell?.usesSingleLineMode = true
        heroNumberLabel.alignment = .left
        heroNumberLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        // The 54pt ultralight glyphs render mostly in the upper half of their natural
        // line box; a 64pt slot left a big air gap to the caption below. 44pt clips the
        // descender slack without touching the visible glyph.
        heroNumberLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true
        root.addArrangedSubview(heroNumberLabel)

        root.setCustomSpacing(4, after: heroNumberLabel)

        heroCaptionLabel.textColor = .tertiaryLabelColor
        root.addArrangedSubview(heroCaptionLabel)

        root.setCustomSpacing(14, after: heroCaptionLabel)

        // Breakdown row: INPUT · CACHED · OUTPUT under the hero
        breakdownRow.translatesAutoresizingMaskIntoConstraints = false
        breakdownRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        breakdownRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        root.addArrangedSubview(breakdownRow)

        root.setCustomSpacing(20, after: breakdownRow)

        // Bucket chart (24 hourly bars / 7 daily / 30 daily depending on period)
        chart.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(chart)
        NSLayoutConstraint.activate([
            chart.widthAnchor.constraint(equalToConstant: contentWidth),
            chart.heightAnchor.constraint(equalToConstant: 26)
        ])

        root.setCustomSpacing(6, after: chart)

        // Axis labels: dynamic per period.
        axisContainer.translatesAutoresizingMaskIntoConstraints = false
        axisContainer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        axisContainer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        root.addArrangedSubview(axisContainer)

        root.setCustomSpacing(18, after: axisContainer)

        // Tool rows
        toolsStack.orientation = .vertical
        toolsStack.alignment = .leading
        toolsStack.spacing = 10
        toolsStack.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        root.addArrangedSubview(toolsStack)

        noDataLabel.font = .systemFont(ofSize: 11, weight: .medium)
        noDataLabel.textColor = .tertiaryLabelColor
        noDataLabel.isHidden = true
        root.addArrangedSubview(noDataLabel)

        root.setCustomSpacing(14, after: toolsStack)
        root.setCustomSpacing(14, after: noDataLabel)

        driversDropdown.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        root.addArrangedSubview(driversDropdown)

        root.setCustomSpacing(18, after: driversDropdown)

        // Footer
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        footerLabel.font = .systemFont(ofSize: 10, weight: .medium)
        footerLabel.textColor = .tertiaryLabelColor

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.target = NSApp
        quitButton.action = #selector(NSApplication.terminate(_:))
        let quitAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.6
        ]
        quitButton.attributedTitle = NSAttributedString(string: "QUIT", attributes: quitAttrs)

        footer.addArrangedSubview(footerLabel)
        footer.addArrangedSubview(footerSpacer)
        footer.addArrangedSubview(quitButton)
        root.addArrangedSubview(footer)

        animatedSubviews = [header, periodSelector, heroNumberLabel, heroCaptionLabel, breakdownRow, chart, axisContainer, toolsStack, driversDropdown, footer]
        animatedSubviews.forEach { $0.wantsLayer = true }
    }

    func setPeriod(_ period: Period, animated: Bool) {
        periodSelector.setPeriod(period, animated: animated)
    }

    func setLoading(_ loading: Bool) {
        if loading {
            refreshButton.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            refreshButton.isHidden = false
        }
    }

    func update(with snapshot: UsageSnapshot, navigation: PeriodNavigationState = .hidden) {
        applyNavigationState(navigation)

        datelineLabel.attributedStringValue = trackedCaps(
            datelineString(for: snapshot),
            size: 10, weight: .semibold, kern: 2.4, color: .tertiaryLabelColor
        )

        let total = snapshot.total.totalTokens

        // Always set the hero to its final value synchronously so layout sizes to real content.
        // Count-up animation (during entry) will overwrite the string per-frame; the width is pinned
        // so the popover doesn't reflow.
        heroNumberLabel.attributedStringValue = attributedHero(for: total)
        heroNumberLabel.toolTip = breakdownTooltip(for: snapshot.total)
        lastHeroTarget = total

        heroCaptionLabel.attributedStringValue = captionWithTotalCost(
            snapshot: snapshot,
            totalCost: snapshot.total.costUSD,
            isEmpty: total == 0
        )

        breakdownRow.setValues([
            snapshot.total.inputTokens,
            snapshot.total.cachedInputTokens,
            snapshot.total.outputTokens
        ])

        let sortedTools = snapshot.byTool
            .filter { $0.value.totalTokens > 0 }
            .sorted { left, right in
                if left.value.totalTokens == right.value.totalTokens {
                    return left.key < right.key
                }
                return left.value.totalTokens > right.value.totalTokens
            }

        chart.update(
            bucketsByTool: snapshot.bucketsByTool,
            bucketCount: snapshot.bucketCount,
            orderedOriginators: sortedTools.map { $0.key },
            currentBucket: snapshot.currentBucketIndex,
            accentResolver: { accentColor(for: $0) }
        )

        applyAxisLabels(for: snapshot)

        // Rebuild tool rows
        toolsStack.arrangedSubviews.forEach { sub in
            toolsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        if sortedTools.isEmpty {
            toolsStack.isHidden = true
            noDataLabel.isHidden = false
            noDataLabel.attributedStringValue = trackedCaps(
                snapshot.period.emptyToolsMessage,
                size: 10, weight: .medium, kern: 1.6, color: .tertiaryLabelColor
            )
        } else {
            toolsStack.isHidden = false
            noDataLabel.isHidden = true

            for (tool, usage) in sortedTools {
                let row = ToolRowView()
                row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
                row.configure(
                    name: displayName(for: tool),
                    usage: usage,
                    accent: accentColor(for: tool),
                    total: total
                )
                toolsStack.addArrangedSubview(row)
            }
        }

        driversDropdown.configure(contributors: snapshot.topContributors)

        let time = clockFormatter.string(from: snapshot.generatedAt)
        footerLabel.attributedStringValue = trackedCaps(
            "Updated \(time)",
            size: 10, weight: .medium, kern: 1.4, color: .tertiaryLabelColor
        )
        footerLabel.toolTip = "\(snapshot.tokenEvents) token events across \(snapshot.scannedFiles) recent session files"

        // Drive popover sizing from actual content height
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let contentHeight = ceil(root.fittingSize.height) + topPadding + bottomPadding
        let newSize = NSSize(width: 340, height: contentHeight)
        if preferredContentSize != newSize {
            preferredContentSize = newSize
        }
    }

    /// Dateline reflects the active window. Day = full date; week = "Week of Mon May 4";
    /// month = "May 2026".
    private func datelineString(for snapshot: UsageSnapshot) -> String {
        switch snapshot.period {
        case .day:
            return datelineFormatter.string(from: snapshot.rangeStart)
        case .week:
            return "Week of \(datelineFormatter.string(from: snapshot.rangeStart))"
        case .month:
            return monthYearFormatter.string(from: snapshot.rangeStart)
        }
    }

    /// Apply axis labels to the container in the right mode for the period.
    /// Day & month: 3 edge labels. Week: 7 weekday letters with today emphasized.
    private func applyAxisLabels(for snapshot: UsageSnapshot) {
        let calendar = Calendar.autoupdatingCurrent
        switch snapshot.period {
        case .day:
            axisContainer.setLabels(start: "00", mid: "12", end: "24")
        case .week:
            let letters: [String] = (0..<snapshot.bucketCount).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: snapshot.rangeStart) ?? snapshot.rangeStart
                return weekdayLetterFormatter.string(from: date).uppercased()
            }
            let gap = BucketChartView.gap(forBucketCount: snapshot.bucketCount)
            axisContainer.setBarLabels(letters, highlightedIndex: snapshot.currentBucketIndex, gap: gap)
        case .month:
            let lastDay = snapshot.bucketCount
            axisContainer.setLabels(start: "1", mid: "15", end: "\(lastDay)")
        }
    }

    // MARK: Entry choreography

    func prepareForEntry() {
        heroCountTask?.cancel()
        heroCountTask = nil

        for v in animatedSubviews {
            v.layer?.removeAnimation(forKey: "entry-opacity")
            v.layer?.removeAnimation(forKey: "entry-transform")
            v.layer?.opacity = 0.0
            v.layer?.transform = CATransform3DMakeTranslation(0, 8, 0)
        }

        heroNumberLabel.attributedStringValue = attributedHero(for: 0)
        driversDropdown.resetCollapsed()
        chart.prepareForEntry()
    }

    func playEntryAnimation() {
        let base = CACurrentMediaTime()

        for (i, v) in animatedSubviews.enumerated() {
            guard let layer = v.layer else { continue }
            layer.opacity = 1.0
            layer.transform = CATransform3DIdentity

            let delay = Double(i) * 0.045

            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.0
            opacity.toValue = 1.0
            opacity.duration = 0.38
            opacity.beginTime = base + delay
            opacity.timingFunction = Easing.outCubic
            opacity.fillMode = .backwards
            layer.add(opacity, forKey: "entry-opacity")

            let translate = CABasicAnimation(keyPath: "transform")
            translate.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 8, 0))
            translate.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            translate.duration = 0.52
            translate.beginTime = base + delay
            translate.timingFunction = Easing.outExpo
            translate.fillMode = .backwards
            layer.add(translate, forKey: "entry-transform")
        }

        chart.playEntryAnimation()

        // Tool row share hairlines sweep in with their parents
        let toolsDelay = Double(animatedSubviews.firstIndex(of: toolsStack) ?? 5) * 0.045 + 0.10
        for (idx, row) in toolsStack.arrangedSubviews.enumerated() {
            (row as? ToolRowView)?.animateFillIn(delay: toolsDelay + Double(idx) * 0.08)
        }

        // Count up the hero number from 0 after a tiny delay
        runCountUp(from: 0, to: lastHeroTarget, duration: 0.7, delay: 0.10)
    }

    private func runCountUp(from start: Int64, to target: Int64, duration: TimeInterval, delay: TimeInterval = 0) {
        heroCountTask?.cancel()
        heroCountTask = nil

        guard start != target else {
            heroNumberLabel.attributedStringValue = attributedHero(for: target)
            return
        }

        let frames = max(Int(duration * 60), 10)
        let stepNs = UInt64((duration / Double(frames)) * 1_000_000_000)
        let delayNs = UInt64(max(delay, 0) * 1_000_000_000)

        heroCountTask = Task { @MainActor [weak self] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard let self = self, !Task.isCancelled else { return }
            for frame in 1...frames {
                if Task.isCancelled { return }
                let progress = Double(frame) / Double(frames)
                let eased = 1 - pow(1 - progress, 4)  // ease-out-quart
                let current = Int64(Double(start) + (Double(target) - Double(start)) * eased)
                self.heroNumberLabel.attributedStringValue = self.attributedHero(for: current)
                try? await Task.sleep(nanoseconds: stepNs)
            }
            if !Task.isCancelled {
                self.heroNumberLabel.attributedStringValue = self.attributedHero(for: target)
            }
        }
    }

    // MARK: Hero typography

    private func attributedHero(for total: Int64) -> NSAttributedString {
        let compact = compactTokens(total)
        let result = NSMutableAttributedString()

        let primaryFont = NSFont.monospacedDigitSystemFont(ofSize: 54, weight: .ultraLight)
        let primaryAttrs: [NSAttributedString.Key: Any] = [
            .font: primaryFont,
            .foregroundColor: NSColor.labelColor,
            .kern: -0.8
        ]
        result.append(NSAttributedString(string: compact.primary, attributes: primaryAttrs))

        if !compact.unit.isEmpty {
            let unitFont = NSFont.systemFont(ofSize: 22, weight: .regular)
            let unitAttrs: [NSAttributedString.Key: Any] = [
                .font: unitFont,
                .foregroundColor: NSColor.codexEmber,
                .kern: 1.5,
                .baselineOffset: 3.0
            ]
            result.append(NSAttributedString(string: " " + compact.unit, attributes: unitAttrs))
        }

        return result
    }

    private func trackedCaps(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        kern: CGFloat,
        color: NSColor
    ) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: kern
        ]
        return NSAttributedString(string: text.uppercased(), attributes: attrs)
    }

    /// Caption line with an appended dollar total. Caps + heavy tracking for the label,
    /// monospaced digits with light tracking for the cost — lets `$13.78` scan as a price
    /// instead of a kerned-out string of glyphs.
    private func captionWithTotalCost(
        snapshot: UsageSnapshot,
        totalCost: Double,
        isEmpty: Bool
    ) -> NSAttributedString {
        let prefix = captionPrefix(for: snapshot, isEmpty: isEmpty)
        let line = NSMutableAttributedString(attributedString: trackedCaps(
            prefix, size: 10, weight: .medium, kern: 2.2, color: .tertiaryLabelColor
        ))
        guard !isEmpty else { return line }

        line.append(NSAttributedString(string: "  ·  ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.4
        ]))
        line.append(NSAttributedString(string: compactCost(totalCost), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.4
        ]))
        return line
    }

    private func captionPrefix(for snapshot: UsageSnapshot, isEmpty: Bool) -> String {
        guard snapshot.periodOffset != 0 else {
            return isEmpty ? snapshot.period.captionEmpty : snapshot.period.captionFull
        }

        switch snapshot.period {
        case .day:
            return isEmpty ? snapshot.period.captionEmpty : snapshot.period.captionFull
        case .week:
            let weekStart = dayMonthFormatter.string(from: snapshot.rangeStart)
            return isEmpty ? "No sessions week of \(weekStart)" : "Tokens week of \(weekStart)"
        case .month:
            let month = monthYearFormatter.string(from: snapshot.rangeStart)
            return isEmpty ? "No sessions \(month)" : "Tokens \(month)"
        }
    }

    private func displayName(for originator: String) -> String {
        switch originator {
        case "Codex Desktop":
            return "Codex Desktop"
        case "codex-tui", "codex_cli_rs":
            return "Codex CLI"
        case "claude-code":
            return "Claude Code"
        default:
            return originator
        }
    }

    private func configureNavigationButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityDescription: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.target = self
        button.action = action
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 16).isActive = true
        button.isHidden = true
    }

    private func applyNavigationState(_ state: PeriodNavigationState) {
        previousPeriodButton.isHidden = !state.isVisible
        nextPeriodButton.isHidden = !state.isVisible
        previousPeriodButton.isEnabled = state.canGoPrevious
        nextPeriodButton.isEnabled = state.canGoNext

        previousPeriodButton.contentTintColor = state.canGoPrevious ? .tertiaryLabelColor : .quaternaryLabelColor
        nextPeriodButton.contentTintColor = state.canGoNext ? .tertiaryLabelColor : .quaternaryLabelColor
    }

    @objc private func previousPeriodClicked() {
        onNavigatePeriod?(-1)
    }

    @objc private func nextPeriodClicked() {
        onNavigatePeriod?(1)
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func refreshClicked() {
        // Small spin delight on click (rotate the chevron in place)
        refreshButton.wantsLayer = true
        let bounds = refreshButton.bounds
        if bounds.width > 0, bounds.height > 0, let layer = refreshButton.layer {
            // Rotate around center by composing anchor shift + rotation + anchor restore.
            let oldAnchor = layer.anchorPoint
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(
                x: layer.position.x + (0.5 - oldAnchor.x) * bounds.width,
                y: layer.position.y + (0.5 - oldAnchor.y) * bounds.height
            )
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0
            anim.toValue = -CGFloat.pi * 2
            anim.duration = 0.7
            anim.timingFunction = Easing.outExpo
            layer.add(anim, forKey: "spin")
        }
        onRefresh?()
    }
}

// MARK: - Command-line period parsing

func selectionFromArguments(_ arguments: [String] = CommandLine.arguments) -> PeriodSelection {
    var period: Period = .day
    if let value = argumentValue(after: "--period", in: arguments)?.lowercased() {
        switch value {
        case "day", "today":
            period = .day
        case "week", "weekly":
            period = .week
        case "month", "monthly":
            period = .month
        default:
            period = .day
        }
    }

    var offset = 0
    if let value = argumentValue(after: "--offset", in: arguments), let parsed = Int(value) {
        offset = parsed
    }

    return PeriodSelection(period: period, offset: offset)
}

private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else { return nil }
    return arguments[valueIndex]
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let usageViewController = UsageViewController()
    private var settingsWindowController: ProviderSettingsWindowController?
    private var refreshTimer: Timer?
    /// In-memory history loaded from the persistent cache. Switching periods or moving through
    /// historic ranges derives a snapshot from this hourly index without reparsing raw logs.
    private var history = UsageHistory.empty()
    private var snapshotCache: [PeriodSelection: UsageSnapshot] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pendingRebuildAfterRefresh = false
    private var currentSelection = selectionFromArguments()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfigManager.load().themePreference.apply()
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Codex token usage")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.toolTip = "Codex token usage"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = usageViewController

        usageViewController.setPeriod(currentSelection.period, animated: false)
        usageViewController.onRefresh = { [weak self] in
            self?.refreshAll(showSpinner: true)
        }
        usageViewController.onOpenSettings = { [weak self] in
            self?.showProviderSettings()
        }
        usageViewController.onPeriodChange = { [weak self] period in
            guard let self = self else { return }
            self.currentSelection = .current(period)
            self.updateCurrentSnapshot()
            self.usageViewController.setLoading(self.refreshTask != nil && !self.history.hasIndexedData)
        }
        usageViewController.onNavigatePeriod = { [weak self] delta in
            self?.moveCurrentSelection(by: delta)
        }

        // Prime the UI synchronously from the persistent cache. If this is the first run or the
        // cache is corrupt, fall back to an empty snapshot while the background rebuild runs.
        history = UsageCacheManager.cachedHistory()
        updateCurrentSnapshot()

        refreshAll(showSpinner: false)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll(showSpinner: false)
            }
        }
    }

    private static func emptySnapshot(for selection: PeriodSelection) -> UsageSnapshot {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let normalized = PeriodSelection(period: selection.period, offset: selection.offset)
        let (start, end) = PeriodMath.dateRange(for: normalized, now: now, calendar: calendar)
        let bucketCount = PeriodMath.bucketCount(for: normalized, now: now, calendar: calendar)
        return UsageSnapshot(
            generatedAt: now,
            period: normalized.period,
            periodOffset: normalized.offset,
            rangeStart: start,
            rangeEnd: end,
            bucketCount: bucketCount,
            byTool: [:],
            bucketsByTool: [:],
            topContributors: [],
            currentBucketIndex: PeriodMath.currentBucketIndex(
                for: normalized,
                now: now,
                rangeStart: start,
                bucketCount: bucketCount,
                calendar: calendar
            ),
            scannedFiles: 0,
            tokenEvents: 0
        )
    }

    private func snapshot(for selection: PeriodSelection) -> UsageSnapshot {
        let clamped = history.clampedSelection(selection)
        if let cached = snapshotCache[clamped] {
            return cached
        }

        let snapshot = history.hasIndexedData
            ? history.snapshot(for: clamped)
            : Self.emptySnapshot(for: clamped)
        snapshotCache[clamped] = snapshot
        return snapshot
    }

    private func updateCurrentSnapshot() {
        let clamped = history.clampedSelection(currentSelection)
        if clamped != currentSelection {
            currentSelection = clamped
        }

        let snapshot = snapshot(for: currentSelection)
        usageViewController.update(
            with: snapshot,
            navigation: history.navigationState(for: currentSelection)
        )
    }

    private func moveCurrentSelection(by delta: Int) {
        guard currentSelection.period != .day else { return }
        let next = PeriodSelection(
            period: currentSelection.period,
            offset: currentSelection.offset + delta
        )
        currentSelection = history.clampedSelection(next)
        updateCurrentSnapshot()
        usageViewController.setLoading(false)
    }

    private func showProviderSettings() {
        if let controller = settingsWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ProviderSettingsWindowController(config: AppConfigManager.load())
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if self.settingsWindowController === controller {
                self.settingsWindowController = nil
            }
        }
        controller.settingsViewController.onCancel = { [weak controller] in
            controller?.close()
        }
        controller.settingsViewController.onThemeChange = { [weak controller] theme in
            do {
                var config = AppConfigManager.load()
                config.themePreference = theme
                try AppConfigManager.save(config)
                theme.apply()
            } catch {
                controller?.settingsViewController.showError("Theme save failed: \(error.localizedDescription)")
            }
        }
        controller.settingsViewController.onSave = { [weak self, weak controller] config in
            guard let self else { return }
            do {
                let existingProviderPaths = AppConfigManager.load().providerPaths.normalized()
                let shouldRebuild = existingProviderPaths != config.providerPaths.normalized()
                try AppConfigManager.save(config)
                config.themePreference.apply()
                controller?.close()
                if shouldRebuild {
                    self.refreshAll(showSpinner: true, rebuild: true)
                }
            } catch {
                controller?.settingsViewController.showError("Save failed: \(error.localizedDescription)")
            }
        }

        settingsWindowController = controller
        popover.performClose(nil)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        // Show whatever's cached for the current period instantly; if the cache is empty
        // (very first launch only), the user-initiated refresh will fill it under a spinner.
        // popoverDidShow fires the staggered entry animation.
        updateCurrentSnapshot()
        usageViewController.prepareForEntry()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        // Show the spinner only when there's nothing cached to look at — otherwise we'd flash
        // a spinner over perfectly good data while the silent background refresh runs.
        refreshAll(showSpinner: !history.hasIndexedData)
    }

    func popoverDidShow(_ notification: Notification) {
        usageViewController.playEntryAnimation()
    }

    /// Refresh the persistent cache once and then derive all periods from the cached daily/hourly
    /// rollups. If a refresh is already running, keep showing the current cached values and let
    /// that task finish; opening the popover never restarts historical parsing.
    private func refreshAll(showSpinner: Bool, rebuild: Bool = false) {
        if refreshTask != nil {
            if rebuild {
                pendingRebuildAfterRefresh = true
            }
            if showSpinner && (rebuild || !history.hasIndexedData) {
                usageViewController.setLoading(true)
            }
            return
        }

        if showSpinner && (rebuild || !history.hasIndexedData) {
            usageViewController.setLoading(true)
        }

        let priority: TaskPriority = showSpinner ? .userInitiated : .utility

        refreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: priority) {
                UsageCacheManager.refresh(rebuild: rebuild)
            }.value
            guard let self = self, !Task.isCancelled else { return }

            self.history = result.history
            self.snapshotCache.removeAll()
            self.updateCurrentSnapshot()
            self.usageViewController.setLoading(false)
            self.refreshTask = nil

            let shouldRebuild = self.pendingRebuildAfterRefresh
            self.pendingRebuildAfterRefresh = false
            if shouldRebuild {
                self.refreshAll(showSpinner: true, rebuild: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTimer?.invalidate()
    }

    func popoverWillClose(_ notification: Notification) {
        if history.hasIndexedData {
            usageViewController.setLoading(false)
        }
    }

}

/// Fold a Claude Code reading into a Codex snapshot. Codex's snapshot defines the period/range
/// metadata; the Claude result contributes the `claude-code` tool entry and gets summed into
/// the file/event counters. Kept for the old full-history readers and comparison diagnostics.
func mergeSnapshot(
    codex: UsageSnapshot,
    claude: (usage: TokenUsage, buckets: [Int64], tokenEvents: Int, scannedFiles: Int)
) -> UsageSnapshot {
    var byTool = codex.byTool
    var bucketsByTool = codex.bucketsByTool
    if claude.usage.totalTokens > 0 {
        byTool["claude-code"] = claude.usage
        bucketsByTool["claude-code"] = claude.buckets
    }
    return UsageSnapshot(
        generatedAt: codex.generatedAt,
        period: codex.period,
        periodOffset: codex.periodOffset,
        rangeStart: codex.rangeStart,
        rangeEnd: codex.rangeEnd,
        bucketCount: codex.bucketCount,
        byTool: byTool,
        bucketsByTool: bucketsByTool,
        topContributors: codex.topContributors,
        currentBucketIndex: codex.currentBucketIndex,
        scannedFiles: codex.scannedFiles + claude.scannedFiles,
        tokenEvents: codex.tokenEvents + claude.tokenEvents
    )
}

// MARK: - CLI

func printSnapshot(_ snapshot: UsageSnapshot) {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal

    func format(_ value: Int64) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    print("\(snapshotTitle(for: snapshot)): \(format(snapshot.total.totalTokens)) tokens")
    print("Input: \(format(snapshot.total.inputTokens))")
    print("Cached input: \(format(snapshot.total.cachedInputTokens))")
    print("Output: \(format(snapshot.total.outputTokens))")
    print("Reasoning: \(format(snapshot.total.reasoningOutputTokens))")
    print("Events: \(snapshot.tokenEvents)")
    print("Files scanned: \(snapshot.scannedFiles)")

    for (tool, usage) in snapshot.byTool.sorted(by: { $0.value.totalTokens > $1.value.totalTokens }) {
        print("\(tool): \(format(usage.totalTokens))")
    }
}

func snapshotTitle(for snapshot: UsageSnapshot) -> String {
    if snapshot.period == .day, snapshot.periodOffset == 0 {
        return "Today total"
    }

    let dayMonthFormatter = DateFormatter()
    dayMonthFormatter.setLocalizedDateFormatFromTemplate("MMMd")
    let monthYearFormatter = DateFormatter()
    monthYearFormatter.setLocalizedDateFormatFromTemplate("MMMMy")

    switch snapshot.period {
    case .day:
        return "\(dayMonthFormatter.string(from: snapshot.rangeStart)) total"
    case .week:
        return "Week of \(dayMonthFormatter.string(from: snapshot.rangeStart)) total"
    case .month:
        return "\(monthYearFormatter.string(from: snapshot.rangeStart)) total"
    }
}

let cliArguments = CommandLine.arguments
if cliArguments.contains("--render-to") {
    fputs("TokenBar: --render-to has been removed.\n", stderr)
    exit(2)
}

let shouldPrintSelectedPeriod = cliArguments.contains("--period")
if cliArguments.contains("--print-today") || cliArguments.contains("--rebuild-cache") || shouldPrintSelectedPeriod {
    let started = Date()
    let result = UsageCacheManager.refresh(rebuild: cliArguments.contains("--rebuild-cache"))

    if cliArguments.contains("--print-today"), let today = result.snapshots[.day] {
        printSnapshot(today)
    } else if shouldPrintSelectedPeriod {
        let selection = result.history.clampedSelection(selectionFromArguments(cliArguments))
        printSnapshot(result.history.snapshot(for: selection))
    }

    if cliArguments.contains("--rebuild-cache") {
        let elapsed = Date().timeIntervalSince(started)
        print("Cache: \(result.cacheURL.path)")
        print("Files indexed: \(result.scannedFiles)")
        print("Files rebuilt or advanced: \(result.changedFiles)")
        print(String(format: "Elapsed: %.2fs", elapsed))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
