import SwiftUI

/// The experience presentation: while Otto narrates each chapter of a
/// planned date, trip, or day out, the matching illustration is on stage —
/// scene heroes, item rows cascading in, and a budget slide whose numbers
/// count up and land visibly UNDER what the user gave. No walls of words.
enum ExperienceArt {

    /// The scene an experience wears, from its vibe and kind.
    static func scene(vibe: String?, kind: ExperienceKind) -> (symbol: String, tint: Color) {
        switch vibe?.lowercased() {
        case "beach": return ("beach.umbrella.fill", OttoTheme.sky)
        case "city": return ("building.2.fill", OttoTheme.lavender)
        case "romantic": return ("heart.fill", OttoTheme.rose)
        case "nature": return ("leaf.fill", OttoTheme.mint)
        case "food": return ("fork.knife", OttoTheme.peach)
        default:
            switch kind {
            case .trip: return ("airplane.departure", OttoTheme.sky)
            case .date: return ("heart.fill", OttoTheme.rose)
            case .outing: return ("sun.max.fill", OttoTheme.lemon)
            }
        }
    }

    static func itemArt(_ kind: ExperienceItemKind) -> (symbol: String, tint: Color) {
        switch kind {
        case .stay: return ("bed.double.fill", OttoTheme.lavender)
        case .food: return ("fork.knife", OttoTheme.peach)
        case .activity: return ("ticket.fill", OttoTheme.mint)
        case .transport: return ("car.fill", OttoTheme.sky)
        case .tip: return ("lightbulb.fill", OttoTheme.lemon)
        }
    }

    /// "$1,370" for USD; "EUR 1,370" for everything else.
    static func money(_ amount: Int, _ currency: String) -> String {
        currency == "USD" ? "$\(amount.formatted())" : "\(currency) \(amount.formatted())"
    }
}

/// One chapter on stage. Overview is a chrome-less hero; the middle
/// chapters are item cards; budget is the money moment.
struct ExperienceChapterCardView: View {
    let chapter: ExperienceChapter
    let experience: Experience

    private var items: [ExperienceItem] {
        let wanted: ExperienceItemKind
        switch chapter.kind {
        case .stay: wanted = .stay
        case .food: wanted = .food
        case .activities: wanted = .activity
        case .transport: wanted = .transport
        case .overview, .budget: return []
        }
        return experience.days.flatMap { day in day.items.filter { $0.kind == wanted } }
    }

    var body: some View {
        switch chapter.kind {
        case .overview:
            ExperienceOverviewHero(experience: experience)
        case .budget:
            ExperienceBudgetSlide(budget: experience.budget)
        case .stay:
            ExperienceItemsCard(label: "STAY", tint: OttoTheme.lavender, items: items)
        case .food:
            ExperienceItemsCard(label: "EAT", tint: OttoTheme.peach, items: items)
        case .activities:
            ExperienceItemsCard(label: "DO", tint: OttoTheme.mint, items: items)
        case .transport:
            ExperienceItemsCard(label: "GETTING AROUND", tint: OttoTheme.sky, items: items)
        }
    }
}

// MARK: - Overview hero

private struct ExperienceOverviewHero: View {
    let experience: Experience

    var body: some View {
        let scene = ExperienceArt.scene(vibe: experience.vibe, kind: experience.kind)
        VStack(spacing: 16) {
            IconTile(symbol: scene.symbol, tint: scene.tint, side: 84, glyph: 38)
                .floaty()
            Text(experience.title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ChapterChip(symbol: "mappin", text: experience.destination, tint: scene.tint)
                    .staggerIn(0)
                if experience.kind == .trip {
                    ChapterChip(
                        symbol: "calendar",
                        text: "\(experience.days.count) days",
                        tint: OttoTheme.mint
                    )
                    .staggerIn(1)
                }
                ChapterChip(
                    symbol: "banknote",
                    text: "under \(ExperienceArt.money(experience.budget.stated, experience.budget.currency))",
                    tint: OttoTheme.lemon
                )
                .staggerIn(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

// MARK: - Item chapters

private struct ExperienceItemsCard: View {
    let label: String
    let tint: Color
    let items: [ExperienceItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChapterLabel(text: label, tint: tint)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { index, item in
                    ExperienceItemRow(item: item, currency: nil)
                        .staggerIn(index)
                }
                if items.count > 4 {
                    Text("+ \(items.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(OttoTheme.textTertiary)
                        .staggerIn(5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }
}

/// One itinerary item: the clock, the icon, the NAME, what to do there,
/// where it is, how long, how much. Shared between the tour and the
/// Voyage detail screen — this row is the instruction.
struct ExperienceItemRow: View {
    let item: ExperienceItem
    /// Pass a currency to show costs; nil hides them (the tour keeps rows
    /// visual — the budget chapter owns the numbers).
    var currency: String?
    /// The schedule shows the clock; grouped sections hide it.
    var showTime = true

    var body: some View {
        let art = ExperienceArt.itemArt(item.kind)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if showTime {
                Text(item.startTime ?? "—")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(item.startTime != nil ? art.tint : OttoTheme.textTertiary)
                    .frame(width: 42, alignment: .leading)
            }
            IconTile(symbol: art.symbol, tint: art.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .lineLimit(1)
                if let note = item.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(OttoTheme.textTertiary)
                        .lineLimit(2)
                }
                if let address = item.address ?? item.area {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 8, weight: .semibold))
                        Text(address)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(OttoTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let currency, let cost = item.estCost {
                    Text(ExperienceArt.money(cost, currency))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(OttoTheme.textSecondary)
                }
                if let duration = item.durationMin {
                    Text("\(duration) min")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OttoTheme.textTertiary)
                }
            }
        }
    }
}

// MARK: - The budget slide

/// The money moment: the planned number counts up, the bar fills to where
/// it stops — visibly short of the stated budget — and the buffer wears
/// mint, because the margin is the feature.
private struct ExperienceBudgetSlide: View {
    let budget: ExperienceBudget
    @State private var filled = false

    var body: some View {
        VStack(spacing: 14) {
            ChapterLabel(text: "THE BUDGET", tint: OttoTheme.mint)
            CountUpMoney(value: budget.planned, currency: budget.currency)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(OttoTheme.textPrimary)
            Text("of your \(ExperienceArt.money(budget.stated, budget.currency))")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(OttoTheme.textSecondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(OttoTheme.control)
                    Capsule()
                        .fill(OttoTheme.mint)
                        .frame(
                            width: filled
                                ? proxy.size.width
                                    * CGFloat(budget.planned) / CGFloat(max(1, budget.stated))
                                : 0
                        )
                }
            }
            .frame(height: 10)
            .padding(.horizontal, 24)
            ChapterChip(
                symbol: "shield.fill",
                text: "\(ExperienceArt.money(budget.buffer, budget.currency)) kept back",
                tint: OttoTheme.mint
            )
            .staggerIn(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .ottoCard()
        .onAppear {
            withAnimation(.spring(duration: 1.0, bounce: 0.1).delay(0.3)) { filled = true }
        }
    }
}

/// The planned total rolling up from zero.
private struct CountUpMoney: View {
    let value: Int
    let currency: String
    @State private var shown = 0

    var body: some View {
        Text(ExperienceArt.money(shown, currency))
            .contentTransition(.numericText(value: Double(shown)))
            .monospacedDigit()
            .task {
                try? await Task.sleep(for: .seconds(0.25))
                if Task.isCancelled { return }
                withAnimation(.spring(duration: 1.0)) { shown = value }
            }
    }
}

// MARK: - The resting card

/// What stays on stage after the tour: saved, named, dismissible.
struct ExperienceRestCard: View {
    let experience: Experience
    let onDismiss: () -> Void

    var body: some View {
        let scene = ExperienceArt.scene(vibe: experience.vibe, kind: experience.kind)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: scene.symbol, tint: scene.tint, side: 44, glyph: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(experience.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(OttoTheme.textPrimary)
                        .lineLimit(1)
                    Text(experience.summary)
                        .font(.caption)
                        .foregroundStyle(OttoTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OttoTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(OttoTheme.control, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.system(size: 11, weight: .semibold))
                Text("Saved to Voyages — Account tab")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(OttoTheme.peach)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard(padding: 14)
    }
}

// MARK: - Shared pieces (file-local)

private struct ChapterLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 34
    var glyph: CGFloat = 15

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(
                tint.opacity(0.15),
                in: RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
            )
    }
}

private struct ChapterChip: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

private struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(
                    .spring(duration: 0.5, bounce: 0.25).delay(0.12 + Double(index) * 0.07)
                ) {
                    shown = true
                }
            }
    }
}

private struct Floaty: ViewModifier {
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .offset(y: up ? -4 : 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}

extension View {
    fileprivate func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }
    fileprivate func floaty() -> some View { modifier(Floaty()) }
}
