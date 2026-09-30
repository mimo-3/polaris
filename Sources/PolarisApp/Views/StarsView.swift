import PolarisCore
import SwiftUI

/// 北極星の控えと振り返り。今日 → 控え → これまで の順に、上ほど近い時間を置く。
/// 付箋は今日の1つだけを見せる場所なので、並べ替えや過去を見る操作はこの窓に寄せる。
struct StarsView: View {
    @Environment(NoteModel.self) private var model
    @Environment(\.polaris) private var theme
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private typealias S = PolarisTheme.Space

    var body: some View {
        VStack(alignment: .leading, spacing: S.xxl) {
            section(Copy.starsToday) { today }
            section(Copy.starsQueue) { queue }
            section(Copy.starsLog) { log }
        }
        .padding(S.xxl)
        .frame(width: 440, alignment: .leading)
        .background(PolarisTheme.Palette.surface)
    }

    // MARK: 今日

    @ViewBuilder private var today: some View {
        if let star = model.today.star {
            VStack(alignment: .leading, spacing: S.s) {
                Text(WordWrap.japanese(star.text))
                    .font(PolarisTheme.Typography.northStar)
                    .lineSpacing(PolarisTheme.Typography.northStarLineSpacing)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: S.s) {
                    if let since = star.activatedAt { MetaText(text: StarDates.since(since)) }
                    Spacer(minLength: 0)
                    Button(Copy.starDrop) { model.endNorthStar(achieved: false) }
                        .buttonStyle(SmallButtonStyle())
                    Button(Copy.starAchieved) { model.endNorthStar() }
                        .buttonStyle(SmallButtonStyle(outlined: true))
                }
            }
        } else {
            MetaText(text: Copy.northStarEmpty)
        }
    }

    // MARK: 控え

    private var queue: some View {
        let stars = model.state.queuedStars
        return VStack(alignment: .leading, spacing: S.s) {
            MetaText(text: Copy.starsQueueHelp)
            ForEach(Array(stars.enumerated()), id: \.element.id) { index, star in
                HStack(spacing: S.s) {
                    Text(star.text)
                        .font(PolarisTheme.Typography.task)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    if index > 0 {
                        Button(Copy.starsMoveUp) { model.moveQueuedNorthStar(star.id, to: index - 1) }
                            .buttonStyle(SmallButtonStyle())
                    }
                    if index < stars.count - 1 {
                        Button(Copy.starsMoveDown) { model.moveQueuedNorthStar(star.id, to: index + 1) }
                            .buttonStyle(SmallButtonStyle())
                    }
                    Button(Copy.delete) { model.removeQueuedNorthStar(star.id) }
                        .buttonStyle(SmallButtonStyle())
                    Button(Copy.starUseNext) { model.activateNorthStar(star.id) }
                        .buttonStyle(SmallButtonStyle(outlined: true))
                }
                .frame(minHeight: 28)
            }
            HStack(spacing: S.s) {
                PolarisTextField(text: $draft, prompt: Copy.starsQueuePlaceholder, font: PolarisTheme.Typography.task,
                                 onSubmit: submit)
                    .frame(height: 20)
                    .focused($fieldFocused)
                    .fieldBox(focused: fieldFocused)
                    .accessibilityLabel(Copy.starsQueueAdd)
                Button(Copy.starsQueueAdd, action: submit)
                    .buttonStyle(SmallButtonStyle(outlined: true))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || stars.count >= TextRules.starQueueMax)
            }
        }
    }

    private func submit() {
        // 満杯のときは ⏎ でも入れない。書いた文は消さずに残す。
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.state.queuedStars.count < TextRules.starQueueMax else { return }
        model.queueNorthStar(draft)
        draft = ""
    }

    // MARK: これまで

    @ViewBuilder private var log: some View {
        let past = model.state.pastStars.sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        if past.isEmpty {
            MetaText(text: Copy.starsLogEmpty)
        } else {
            // 短いうちは素の並びにして窓を伸ばさない。ImageRenderer は ScrollView の中身を描かないので、スナップショットも素の並び。
            if past.count > 6 && !theme.snapshot {
                ScrollView { logRows(past) }.frame(height: 320)
            } else {
                logRows(past)
            }
        }
    }

    private func logRows(_ past: [NorthStar]) -> some View {
        VStack(alignment: .leading, spacing: S.m) {
            ForEach(past) { star in
                HStack(alignment: .firstTextBaseline, spacing: S.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(star.text)
                            .font(PolarisTheme.Typography.task)
                            .foregroundStyle(star.outcome == .achieved ? theme.ink : theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        MetaText(text: StarDates.summary(star))
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button(Copy.starsReopen) { model.reopenNorthStar(star.id) }
                        .buttonStyle(SmallButtonStyle())
                        .disabled(model.state.queuedStars.count >= TextRules.starQueueMax)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: S.m) {
            Text(title).font(PolarisTheme.Typography.button).foregroundStyle(theme.ink)
            content()
        }
    }
}

/// 振り返りの日付表記。「9/28 → 9/30（3日）」のように暦日で数える。
enum StarDates {
    private static let format: Date.FormatStyle = .dateTime.month(.defaultDigits).day()

    static func since(_ date: Date) -> String { "\(date.formatted(format))から" }

    static func summary(_ star: NorthStar, calendar: Calendar = .current) -> String {
        let outcome = star.outcome == .achieved ? Copy.starOutcomeAchieved : Copy.starOutcomeDropped
        guard let end = star.endedAt else { return outcome }
        let start = star.activatedAt ?? star.createdAt
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                            to: calendar.startOfDay(for: end)).day ?? 0) + 1
        let range = days <= 1 ? end.formatted(format) : "\(start.formatted(format)) → \(end.formatted(format))"
        return "\(outcome) · \(range)（\(max(days, 1))日）"
    }
}
