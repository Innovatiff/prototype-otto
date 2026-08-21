import SwiftUI

/// The app's shell: four tabs under a floating pill bar. Home is the voice
/// stage and nothing else; Plans, Automations, and Account each get a full
/// page. Tabs switch by opacity inside a ZStack — every tab stays alive,
/// so the voice loop keeps running and the guided-session cover (owned by
/// Home) can present from any tab.
struct RootView: View {
    enum Tab: String, CaseIterable {
        case home, plans, automations, account

        var icon: String {
            switch self {
            case .home: return "waveform"
            case .plans: return "calendar"
            case .automations: return "bolt.fill"
            case .account: return "person.fill"
            }
        }

        var label: String {
            switch self {
            case .home: return "Otto"
            case .plans: return "Plans"
            case .automations: return "Automations"
            case .account: return "Account"
            }
        }
    }

    @Bindable var model: ConversationModel
    @Bindable var settings: DebugModel
    @Bindable var memory: MemoryModel
    @Bindable var tasks: TasksModel
    @Bindable var plans: PlansModel
    var calendarSync: CalendarSyncService
    var automations: AutomationsModel
    var experiences: ExperiencesModel

    @State private var tab: Tab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                ConversationView(model: model) {
                    tab = .account
                }
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)

                plansTab
                    .opacity(tab == .plans ? 1 : 0)
                    .allowsHitTesting(tab == .plans)

                automationsTab
                    .opacity(tab == .automations ? 1 : 0)
                    .allowsHitTesting(tab == .automations)

                AccountView(
                    settings: settings,
                    tasks: tasks,
                    memory: memory,
                    experiences: experiences,
                    onBriefScheduleChange: { enabled, hour, minute in
                        model.setBriefSchedule(enabled: enabled, hour: hour, minute: minute)
                    },
                    onCalendarSyncChange: { enabled in
                        if enabled {
                            Task { await calendarSync.syncIfNeeded(force: true) }
                        }
                    }
                )
                .opacity(tab == .account ? 1 : 0)
                .allowsHitTesting(tab == .account)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OttoTabBar(selection: $tab)
        }
        .background(OttoTheme.background.ignoresSafeArea())
        .task {
            // Wake time edited on the automations screen keeps the LOCAL
            // weekday brief notifications (the no-push fallback) in step.
            automations.onWakeTimeChanged = { hour, minute in
                let defaults = UserDefaults.standard
                defaults.set(hour, forKey: "otto.brief.hour")
                defaults.set(minute, forKey: "otto.brief.minute")
                if defaults.bool(forKey: "otto.brief.enabled") {
                    model.setBriefSchedule(enabled: true, hour: hour, minute: minute)
                }
            }
        }
        .onChange(of: tab) { _, _ in
            Haptics.tick()
        }
    }

    private var plansTab: some View {
        NavigationStack {
            PlansView(
                model: plans,
                onAdaptPlan: {
                    // Adaptation is spoken: back to the stage, mic open.
                    tab = .home
                    model.beginPlanAdaptation()
                },
                onStartSession: { plan in
                    tab = .home
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        await model.startSession(with: plan)
                    }
                }
            )
            .navigationTitle("Plans")
            .background(OttoTheme.background)
            .safeAreaPadding(.bottom, 64)
        }
    }

    private var automationsTab: some View {
        NavigationStack {
            AutomationsView(model: automations)
                .scrollContentBackground(.hidden)
                .background(OttoTheme.background)
                .safeAreaPadding(.bottom, 64)
        }
    }
}

/// The floating pill bar: white, soft-shadowed, the selected tab an ink
/// circle. Labels appear only on the selected item, reference-style.
struct OttoTabBar: View {
    @Binding var selection: RootView.Tab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RootView.Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        if selection == tab {
                            Text(tab.label)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selection == tab ? Color.white : OttoTheme.textSecondary)
                    .padding(.horizontal, selection == tab ? 16 : 13)
                    .frame(height: 44)
                    .background(
                        selection == tab ? OttoTheme.ink : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(PressableButtonStyle(scale: 0.92))
                .accessibilityLabel(tab.label)
            }
        }
        .padding(6)
        .background(OttoTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(OttoTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }
}
