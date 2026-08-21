import SwiftUI

/// The Voyages shelf: every experience Otto has planned, each wearing its
/// scene — gradient tile, title, the one-line summary, and the budget it
/// stays under. Tap through for the whole itinerary.
struct VoyagesView: View {
    @Bindable var model: ExperiencesModel

    var body: some View {
        List {
            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            if model.experiences.isEmpty && !model.isLoading {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(OttoTheme.sky)
                        Text("No voyages yet")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(OttoTheme.textPrimary)
                        Text("Ask Otto to plan a trip, a date, or a day out.")
                            .font(.subheadline)
                            .foregroundStyle(OttoTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(model.experiences, id: \.id) { summary in
                        NavigationLink {
                            VoyageDetailView(model: model, summary: summary)
                        } label: {
                            VoyageRow(summary: summary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Haptics.caution()
                                Task { await model.delete(summary) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Voyages")
        .scrollContentBackground(.hidden)
        .background(OttoTheme.background)
        .task {
            await model.load()
        }
        .refreshable {
            await model.load()
        }
        .overlay {
            if model.isLoading && model.experiences.isEmpty {
                ProgressView()
            }
        }
    }
}

private struct VoyageRow: View {
    let summary: ExperienceSummary

    var body: some View {
        let scene = ExperienceArt.scene(vibe: summary.vibe, kind: summary.kind)
        HStack(spacing: 14) {
            SceneTile(symbol: scene.symbol, tint: scene.tint, side: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
                    .lineLimit(1)
                Text(summary.summary)
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
                    .lineLimit(2)
                Text(
                    "under \(ExperienceArt.money(summary.budget.stated, summary.budget.currency))"
                        + (summary.kind == .trip ? " · \(summary.dayCount) days" : "")
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(scene.tint)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The scene as a small gradient block with its white glyph — the "nice
/// image" of a voyage, drawn, not fetched.
struct SceneTile: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
    }
}

/// The whole itinerary, beautifully put: hero header, the budget landing
/// under what was given, then every day with every stay, meal, activity,
/// and transfer — costs included.
struct VoyageDetailView: View {
    let model: ExperiencesModel
    let summary: ExperienceSummary

    /// Reservation keys ("day.item") the user has ticked off — kept on
    /// device, per voyage, across launches.
    @State private var bookedKeys: Set<String> = []

    private var bookedDefaultsKey: String { "otto.voyage.booked.\(summary.id)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if let experience = model.details[summary.id] {
                    budgetCard(experience.budget)
                    let reservations = reservationEntries(experience)
                    if !reservations.isEmpty {
                        reservationsCard(reservations, destination: experience.destination)
                    }
                    groupedSections(experience)
                    Text("THE SCHEDULE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OttoTheme.textTertiary)
                        .padding(.top, 4)
                    ForEach(Array(experience.days.enumerated()), id: \.offset) { _, day in
                        dayCard(day, currency: experience.budget.currency)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .background(OttoTheme.background)
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            bookedKeys = Set(UserDefaults.standard.stringArray(forKey: bookedDefaultsKey) ?? [])
            await model.loadDetail(id: summary.id)
        }
    }

    // MARK: - Reservations (the call list)

    private struct ReservationEntry {
        let key: String
        let dayLabel: String
        let item: ExperienceItem
    }

    private func reservationEntries(_ experience: Experience) -> [ReservationEntry] {
        var entries: [ReservationEntry] = []
        for (dayIndex, day) in experience.days.enumerated() {
            for (itemIndex, item) in day.items.enumerated()
            where item.needsReservation == true {
                entries.append(
                    ReservationEntry(key: "\(dayIndex).\(itemIndex)", dayLabel: day.label, item: item)
                )
            }
        }
        return entries
    }

    /// The bookings, as a working checklist: tick what's done, call and
    /// navigate straight from the row.
    private func reservationsCard(
        _ entries: [ReservationEntry], destination: String
    ) -> some View {
        let done = entries.filter { bookedKeys.contains($0.key) }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("RESERVATIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OttoTheme.rose)
                Spacer()
                Text("\(done) of \(entries.count) booked")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(done == entries.count ? OttoTheme.mint : OttoTheme.textTertiary)
            }
            ForEach(entries, id: \.key) { entry in
                reservationRow(entry, destination: destination)
            }
            Text("Call ahead — plans hold better with a booking.")
                .font(.caption2)
                .foregroundStyle(OttoTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    private func reservationRow(_ entry: ReservationEntry, destination: String) -> some View {
        let booked = bookedKeys.contains(entry.key)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                Haptics.tick()
                if booked {
                    bookedKeys.remove(entry.key)
                } else {
                    bookedKeys.insert(entry.key)
                }
                UserDefaults.standard.set(Array(bookedKeys).sorted(), forKey: bookedDefaultsKey)
            } label: {
                Image(systemName: booked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(booked ? OttoTheme.mint : OttoTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(booked ? "Booked" : "Not booked yet")
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(booked ? OttoTheme.textTertiary : OttoTheme.textPrimary)
                    .strikethrough(booked, color: OttoTheme.textTertiary)
                    .lineLimit(1)
                Text(entry.dayLabel + (entry.item.startTime.map { " · \($0)" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(OttoTheme.textTertiary)
                if !booked {
                    PlaceActionRow(item: entry.item, destination: destination)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The trip by subject before the trip by clock: where you'll stay,
    /// eat, and go, and how you'll move (gas included) — every place one
    /// tap from directions and a call.
    @ViewBuilder
    private func groupedSections(_ experience: Experience) -> some View {
        let currency = experience.budget.currency
        let destination = experience.destination
        let stays = items(of: .stay, in: experience)
        let eats = items(of: .food, in: experience)
        let does = items(of: .activity, in: experience)
        let moves = items(of: .transport, in: experience)
        if !stays.isEmpty {
            sectionCard(
                "WHERE YOU'LL STAY", tint: OttoTheme.lavender, items: stays,
                currency: currency, destination: destination)
        }
        if !eats.isEmpty {
            sectionCard(
                "WHERE YOU'LL EAT", tint: OttoTheme.peach, items: eats,
                currency: currency, destination: destination)
        }
        if !does.isEmpty {
            sectionCard(
                "WHAT YOU'LL DO", tint: OttoTheme.mint, items: does,
                currency: currency, destination: destination)
        }
        if !moves.isEmpty {
            transportCard(moves, currency: currency, destination: destination)
        }
    }

    private func items(of kind: ExperienceItemKind, in experience: Experience) -> [ExperienceItem] {
        experience.days.flatMap { day in day.items.filter { $0.kind == kind } }
    }

    private func sectionCard(
        _ label: String, tint: Color, items: [ExperienceItem],
        currency: String, destination: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ExperienceItemRow(
                    item: item, currency: currency, showTime: false,
                    actionsDestination: destination)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    private func transportCard(
        _ moves: [ExperienceItem], currency: String, destination: String
    ) -> some View {
        let total = moves.compactMap(\.estCost).reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            Text("TRANSPORT & GAS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OttoTheme.sky)
            ForEach(Array(moves.enumerated()), id: \.offset) { _, item in
                ExperienceItemRow(
                    item: item, currency: currency, showTime: false,
                    actionsDestination: destination)
            }
            if total > 0 {
                Text("≈ \(ExperienceArt.money(total, currency)) in drives, fares, and gas")
                    .font(.caption)
                    .foregroundStyle(OttoTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    private var hero: some View {
        let scene = ExperienceArt.scene(vibe: summary.vibe, kind: summary.kind)
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: OttoTheme.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [scene.tint, scene.tint.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 150)
            Image(systemName: scene.symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(summary.destination)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
        }
    }

    private func budgetCard(_ budget: ExperienceBudget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BUDGET")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OttoTheme.mint)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ExperienceArt.money(budget.planned, budget.currency))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(OttoTheme.textPrimary)
                Text("of \(ExperienceArt.money(budget.stated, budget.currency))")
                    .font(.subheadline)
                    .foregroundStyle(OttoTheme.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(OttoTheme.control)
                    Capsule()
                        .fill(OttoTheme.mint)
                        .frame(
                            width: proxy.size.width
                                * CGFloat(budget.planned) / CGFloat(max(1, budget.stated))
                        )
                }
            }
            .frame(height: 8)
            Text("\(ExperienceArt.money(budget.buffer, budget.currency)) kept back, just in case")
                .font(.caption)
                .foregroundStyle(OttoTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }

    private func dayCard(_ day: ExperienceDay, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(day.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OttoTheme.textTertiary)
            ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                ExperienceItemRow(item: item, currency: currency)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoCard()
    }
}
