// ios/MBI/MBI/Views/AccountView.swift
// MBI Phase 1.5 — Sprint 4: Profile Section Architecture
// R1 — Step Goal: stepper replaced with text input + Save button
// R2 — Weight: Save button added (no longer relies on onSubmit only)
// R3 — Wake/Sleep time wheel: .colorScheme(.dark) + .accentColor(goldLight) for legibility
// R4 — Height: Pre-Beta Sprint — now reads from currentUser.heightFt/heightIn (E-06 resolved)
// R5 — Age: Pre-Beta Sprint — now reads from currentUser.birthday and computes age (E-06 resolved)
// R6 — Phase 2 greyed rows: opacity raised from ~0.4 to ~0.6 for legibility
// R7 — Connected Devices: union HKSourceQuery across stepCount, bodyMass, bloodPressureSystolic,
//       heartRate — surfaces Apple Watch, VeSync scale, iHealth BP cuff. Deduplicated by source name.
//       Sprint 5 — Epic 1 Close-Out

import SwiftUI
import HealthKit

// ─────────────────────────────────────────
// ACCOUNT VIEW
// ─────────────────────────────────────────

struct AccountView: View {
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab: AccountTab = .profile
    @State private var showSignOutConfirm = false
    @State private var founderTapCount = 0
    @State private var showFounderSection = false

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()
            RadialGradient(colors: [ChronosTheme.gold.opacity(0.05), .clear], center: .top, startRadius: 0, endRadius: 300)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Dismiss ──
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                            .padding(10)
                            .background(Circle().fill(ChronosTheme.surface))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

                AccountProfileHeader(
                    user: supabase.currentUser,
                    score: sync.dashboard?.score,
                    onAvatarTap: {
                        founderTapCount += 1
                        if founderTapCount >= 7 { withAnimation(.easeInOut) { showFounderSection = true } }
                    }
                )

                AccountTabBar(selected: $selectedTab)
                    .padding(.horizontal, 20).padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        switch selectedTab {
                        case .profile:
                            AccountProfileTab(user: supabase.currentUser).environmentObject(supabase)
                        case .preferences:
                            AccountPreferencesTab(user: supabase.currentUser).environmentObject(supabase)
                        case .connections:
                            AccountConnectionsTab().environmentObject(supabase).environmentObject(sync)
                        case .account:
                            AccountAccountTab(user: supabase.currentUser, score: sync.dashboard?.score, showSignOutConfirm: $showSignOutConfirm)
                                .environmentObject(supabase)
                        }

                        if showFounderSection {
                            VStack(spacing: 0) {
                                HStack {
                                    Rectangle().fill(ChronosTheme.gold.opacity(0.2)).frame(height: 1)
                                    Text("FOUNDER").font(.jost(size: 8, weight: .light))
                                        .foregroundColor(ChronosTheme.gold.opacity(0.5)).tracking(3).padding(.horizontal, 12)
                                    Rectangle().fill(ChronosTheme.gold.opacity(0.2)).frame(height: 1)
                                }
                                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)
                                AdminView()
                            }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        Text("Chronos · MBI · Confidential")
                            .font(.jost(size: 9, weight: .light)).foregroundColor(ChronosTheme.faint).tracking(2)
                            .padding(.top, 32).padding(.bottom, 40)
                    }
                }
            }
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { supabase.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You'll need to sign back in.") }
    }
}

// ─────────────────────────────────────────
// ACCOUNT TAB ENUM
// ─────────────────────────────────────────

enum AccountTab: String, CaseIterable {
    case profile     = "Profile"
    case preferences = "Preferences"
    case connections = "Connections"
    case account     = "Account"
}

// ─────────────────────────────────────────
// TAB BAR
// ─────────────────────────────────────────

struct AccountTabBar: View {
    @Binding var selected: AccountTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AccountTab.allCases, id: \.self) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.18)) { selected = tab } }) {
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.jost(size: 11, weight: selected == tab ? .medium : .light))
                            .foregroundColor(selected == tab ? ChronosTheme.gold : ChronosTheme.muted).tracking(0.5)
                        Rectangle().fill(selected == tab ? ChronosTheme.gold : Color.clear).frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(ChronosTheme.border).frame(height: 1) }
    }
}

// ─────────────────────────────────────────
// PINNED PROFILE HEADER
// ─────────────────────────────────────────

struct AccountProfileHeader: View {
    let user: MBIUser?
    let score: DailyScore?
    let onAvatarTap: () -> Void

    var bandColor: Color {
        switch score?.scoreBand {
        case .thriving:   return Color(red: 0.40, green: 0.82, blue: 0.50)
        case .recovering: return ChronosTheme.goldLight
        case .yellowline: return Color(red: 1.0, green: 0.72, blue: 0.20)
        case .drifting:   return Color(red: 1.0, green: 0.78, blue: 0.28)
        case .redline:    return Color(red: 1.0, green: 0.40, blue: 0.40)
        case .none:       return ChronosTheme.muted
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onAvatarTap) {
                ZStack {
                    Circle().fill(ChronosTheme.goldDim)
                        .overlay(Circle().stroke(ChronosTheme.gold.opacity(0.3), lineWidth: 1))
                        .frame(width: 60, height: 60)
                    Text(initials(from: user?.displayName))
                        .font(.cormorant(size: 24, weight: .light)).foregroundColor(ChronosTheme.gold)
                }
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(user?.displayName ?? "—").font(.cormorant(size: 24, weight: .light)).foregroundColor(ChronosTheme.text)
                Text(user?.email ?? "").font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.muted)
                if let band = score?.scoreBand {
                    Text(band.rawValue.uppercased())
                        .font(.jost(size: 8, weight: .medium)).foregroundColor(bandColor).tracking(2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(bandColor.opacity(0.1))
                            .overlay(Capsule().stroke(bandColor.opacity(0.25), lineWidth: 1)))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
    }

    private func initials(from name: String?) -> String {
        guard let name, !name.isEmpty else { return "C" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased() }
        return String(name.prefix(2)).uppercased()
    }
}

// ─────────────────────────────────────────
// TAB 1: PROFILE
// ─────────────────────────────────────────

struct AccountProfileTab: View {
    let user: MBIUser?
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator

    // R1: Step Goal as text input
    @State private var stepGoalText: String = "8,000"
    @State private var healthGoal: HealthGoal = .generalWellness
    @State private var weightLbsText: String = ""
    @State private var wakeTime: Date = AccountProfileTab.defaultTime(hour: 6, minute: 0)
    @State private var sleepTime: Date = AccountProfileTab.defaultTime(hour: 22, minute: 0)
    @State private var showWakePicker = false
    @State private var showSleepPicker = false
    @State private var showHealthGoalPicker = false

    @State private var biologicalSex: String = "prefer_not_to_say"
    @State private var showBioSexPicker = false

    @State private var savingField: String? = nil
    @State private var savedField: String? = nil
    @State private var saveError: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            AccountSectionHeader(label: "SCORING INPUTS")
            stepGoalRow
            healthGoalRow
            biologicalSexRow
            weightRow
            timeRow(icon: "sun.horizon", label: "Wake Time", displayValue: displayTime(wakeTime), isExpanded: $showWakePicker,
                picker: DatePicker("", selection: $wakeTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .colorScheme(.dark)
                    .accentColor(ChronosTheme.goldLight)  // R3: visible gold selection band
                    .onChange(of: wakeTime) { saveSingle(field: "wake_time", wakeTime: wakeTime) }
            )
            timeRow(icon: "moon.zzz", label: "Sleep Time", displayValue: displayTime(sleepTime), isExpanded: $showSleepPicker,
                picker: DatePicker("", selection: $sleepTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .colorScheme(.dark)
                    .accentColor(ChronosTheme.goldLight)  // R3
                    .onChange(of: sleepTime) { saveSingle(field: "sleep_time", sleepTime: sleepTime) }
            )
            // R4: Height — reads from currentUser (E-06 resolved — persisted via updateOnboardingProfile)
            AccountRow(icon: "ruler",    label: "Height", value: heightDisplayValue)
            // R5: Age — computes from currentUser.birthday (E-06 resolved)
            AccountRow(icon: "calendar", label: "Age",    value: ageDisplayValue)

            // Data confidence — surfaces range_trust_state so users understand score reliability
            AccountRow(
                icon:       "waveform.path.ecg",
                label:      "Data Confidence",
                value:      trustStateDisplayValue,
                valueColor: trustStateColor
            )

            AccountPhase2Separator()
            AccountRowGreyed(icon: "circle.dotted",          label: "Cycle Tracking",         value: biologicalSex == "female" ? "Available" : "—")
            AccountRowGreyed(icon: "chart.bar.xaxis",        label: "Goal Priority",         value: "Balanced")
            AccountRowGreyed(icon: "bandage",                label: "Illness Mode",           value: "Off")
            AccountRowGreyed(icon: "airplane",               label: "Travel / Timezone Mode", value: "Off")
            AccountRowGreyed(icon: "wineglass",              label: "Alcohol Indicator",      value: "Off")
            AccountRowGreyed(icon: "pencil.and.outline",     label: "Manual Stress Event",    value: "—")
            AccountRowGreyed(icon: "arrow.counterclockwise", label: "Baseline Reset",         value: "")
            AccountRowGreyed(icon: "lock",                   label: "Baseline Lock",          value: "Off")
        }
        .padding(.horizontal, 20).padding(.top, 20)
        .onAppear { seedFromUser() }
    }

    // MARK: - R1: Step Goal — text input + Save button

    private var stepGoalRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                Text("Daily Step Goal").font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                Spacer()
                HStack(spacing: 8) {
                    TextField("8,000", text: $stepGoalText)
                        .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                    saveButton(action: saveStepGoal)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            saveStatusRow(field: "step_goal")
        }
        .background(roundedCard)
    }

    // MARK: - Health Goal picker

    private var healthGoalRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showHealthGoalPicker.toggle() } }) {
                HStack(spacing: 14) {
                    Image(systemName: "target")
                        .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                    Text("Health Goal").font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Spacer()
                    Text(healthGoal.displayLabel).font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                    Image(systemName: showHealthGoalPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }.buttonStyle(.plain)

            if showHealthGoalPicker {
                VStack(spacing: 0) {
                    Rectangle().fill(ChronosTheme.border).frame(height: 1)
                    ForEach(HealthGoal.allCases) { goal in
                        Button(action: {
                            healthGoal = goal
                            withAnimation { showHealthGoalPicker = false }
                            saveSingle(field: "health_goal", healthGoal: goal)
                        }) {
                            HStack {
                                Text(goal.displayLabel)
                                    .font(.jost(size: 13, weight: healthGoal == goal ? .medium : .light))
                                    .foregroundColor(healthGoal == goal ? ChronosTheme.goldLight : ChronosTheme.muted)
                                Spacer()
                                if healthGoal == goal {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.gold)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }.buttonStyle(.plain)
                        if goal != HealthGoal.allCases.last {
                            Rectangle().fill(ChronosTheme.border.opacity(0.5)).frame(height: 1).padding(.leading, 16)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            saveStatusRow(field: "health_goal")
        }
        .background(roundedCard).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Biological Sex picker

    private var biologicalSexRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showBioSexPicker.toggle() } }) {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                    Text("Biological Sex").font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Spacer()
                    Text(bioSexDisplayLabel(biologicalSex))
                        .font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                    Image(systemName: showBioSexPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }.buttonStyle(.plain)

            if showBioSexPicker {
                VStack(spacing: 0) {
                    Rectangle().fill(ChronosTheme.border).frame(height: 1)
                    ForEach(["male", "female", "prefer_not_to_say"], id: \.self) { sexValue in
                        Button(action: {
                            biologicalSex = sexValue
                            withAnimation { showBioSexPicker = false }
                            saveSingle(field: "biological_sex", biologicalSex: sexValue)
                        }) {
                            HStack {
                                Text(bioSexDisplayLabel(sexValue))
                                    .font(.jost(size: 13, weight: biologicalSex == sexValue ? .medium : .light))
                                    .foregroundColor(biologicalSex == sexValue ? ChronosTheme.goldLight : ChronosTheme.muted)
                                Spacer()
                                if biologicalSex == sexValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.gold)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }.buttonStyle(.plain)
                        if sexValue != "prefer_not_to_say" {
                            Rectangle().fill(ChronosTheme.border.opacity(0.5)).frame(height: 1).padding(.leading, 16)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            saveStatusRow(field: "biological_sex")
        }
        .background(roundedCard).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func bioSexDisplayLabel(_ value: String) -> String {
        switch value {
        case "male":   return "Male"
        case "female": return "Female"
        default:       return "Prefer not to say"
        }
    }

    // MARK: - R2: Weight — text input + explicit Save button

    private var weightRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "scalemass")
                    .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                Text("Weight").font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                Spacer()
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        TextField(user?.weightLbs == nil ? "Enter lbs" : "", text: $weightLbsText)
                            .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 72)
                        if !weightLbsText.isEmpty {
                            Text("lbs").font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.muted)
                        }
                    }
                    saveButton(action: saveWeight)
                        .disabled(weightLbsText.isEmpty).opacity(weightLbsText.isEmpty ? 0.4 : 1.0)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            saveStatusRow(field: "weight_lbs")
        }
        .background(roundedCard)
    }

    // MARK: - R3: Time rows — dark scheme, gold accent

    @ViewBuilder
    private func timeRow<P: View>(icon: String, label: String, displayValue: String, isExpanded: Binding<Bool>, picker: P) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() } }) {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                    Text(label).font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Spacer()
                    Text(displayValue).font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }.buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(spacing: 0) {
                    Rectangle().fill(ChronosTheme.border).frame(height: 1)
                    picker.padding(.vertical, 4).frame(maxWidth: .infinity).background(ChronosTheme.surface)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            saveStatusRow(field: label == "Wake Time" ? "wake_time" : "sleep_time")
        }
        .background(roundedCard).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Shared UI builders

    private var roundedCard: some View {
        RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1))
    }

    private func saveButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Save")
                .font(.jost(size: 11, weight: .medium)).foregroundColor(ChronosTheme.gold).tracking(0.5)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(ChronosTheme.goldDim)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChronosTheme.gold.opacity(0.3), lineWidth: 1)))
        }
    }

    @ViewBuilder
    private func saveStatusRow(field: String) -> some View {
        if savingField == field {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).tint(ChronosTheme.gold.opacity(0.5))
                Text("Saving...").font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        } else if savedField == field {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .light))
                    .foregroundColor(Color(red: 0.40, green: 0.82, blue: 0.50))
                Text("Saved").font(.jost(size: 11, weight: .light))
                    .foregroundColor(Color(red: 0.40, green: 0.82, blue: 0.50))
            }.padding(.horizontal, 16).padding(.bottom, 12)
        } else if saveError != nil && savingField == nil && savedField == nil {
            Text(saveError ?? "").font(.jost(size: 11, weight: .light))
                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    // MARK: - Save actions

    // ── Height display (E-06 resolved) ─────────────────────────────────
    private var heightDisplayValue: String {
        guard let ft = supabase.currentUser?.heightFt, let inch = supabase.currentUser?.heightIn else {
            return "Not yet collected"
        }
        return "\(ft)'\(inch)\""
    }

    // ── Age display (E-06 resolved) ─────────────────────────────────────
    private var ageDisplayValue: String {
        guard let birthday = supabase.currentUser?.birthday else { return "Not yet collected" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: birthday) else { return "Not yet collected" }
        let age = Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
        return "\(age) years"
    }

    // ── Trust state display — surfaces range_trust_state for transparency ──
    private var trustStateDisplayValue: String {
        switch sync.dashboard?.score.rangeTrustState {
        case "establishing":  return "Building · 1–3 days"
        case "calibrating":   return "Calibrating · 4–6 days"
        case "provisional":   return "Provisional · 7–13 days"
        case "trusted":       return "Trusted · 14–27 days"
        case "established":   return "Established · 28+ days"
        default:              return "Building"
        }
    }

    private var trustStateColor: Color {
        switch sync.dashboard?.score.rangeTrustState {
        case "provisional", "trusted", "established": return ChronosTheme.goldLight
        default:                                       return ChronosTheme.muted
        }
    }

    private func saveStepGoal() {
        let cleaned = stepGoalText.replacingOccurrences(of: ",", with: "")
        guard let goal = Int(cleaned), goal >= 1000, goal <= 30000 else {
            saveError = "Enter a value between 1,000 and 30,000"; return
        }
        let f = NumberFormatter(); f.numberStyle = .decimal
        stepGoalText = f.string(from: NSNumber(value: goal)) ?? "\(goal)"
        saveSingle(field: "step_goal", stepGoal: goal)
    }

    private func saveWeight() {
        guard let lbs = Double(weightLbsText) else { saveError = "Enter a valid number"; return }
        saveSingle(field: "weight_lbs", weightLbs: lbs)
    }

    // MARK: - Helpers

    private func displayTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    private static func defaultTime(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    private func hmString(from date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }

    private func timeFromHM(_ hm: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.date(from: hm) ?? AccountProfileTab.defaultTime(hour: 6, minute: 0)
    }

    private func seedFromUser() {
        guard let u = user else { return }
        let f = NumberFormatter(); f.numberStyle = .decimal
        stepGoalText  = f.string(from: NSNumber(value: u.stepGoal)) ?? "\(u.stepGoal)"
        healthGoal    = HealthGoal(rawValue: u.healthGoal) ?? .generalWellness
        biologicalSex = u.biologicalSex ?? "prefer_not_to_say"
        if let w = u.weightLbs { weightLbsText = String(format: "%.1f", w) }
        wakeTime  = timeFromHM(u.wakeTime)
        sleepTime = timeFromHM(u.sleepTime)
    }

    private func saveSingle(field: String, stepGoal: Int? = nil, healthGoal: HealthGoal? = nil,
                            weightLbs: Double? = nil, wakeTime: Date? = nil, sleepTime: Date? = nil,
                            biologicalSex: String? = nil) {
        guard let userId = supabase.session?.userId else { return }
        savingField = field; savedField = nil; saveError = nil
        Task {
            do {
                try await supabase.updateProfile(
                    userId: userId, stepGoal: stepGoal, healthGoal: healthGoal?.rawValue,
                    weightLbs: weightLbs, wakeTime: wakeTime.map { hmString(from: $0) },
                    sleepTime: sleepTime.map { hmString(from: $0) },
                    biologicalSex: biologicalSex
                )
                await MainActor.run { savingField = nil; savedField = field }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { savedField = nil }
            } catch {
                await MainActor.run { savingField = nil; saveError = "Couldn't save — try again" }
            }
        }
    }
}

// ─────────────────────────────────────────
// TAB 2: PREFERENCES
// ─────────────────────────────────────────

// ─────────────────────────────────────────
// TAB 2: PREFERENCES
// Sprint 4 — Notification section replaced with NotificationPreferencesView.
// Sprint 5 — Display Mode and Response Tone are now active AppStorage pickers.
// Brief Delivery Time is inside NotificationPreferencesView.
// ─────────────────────────────────────────

struct AccountPreferencesTab: View {
    let user: MBIUser?
    @EnvironmentObject var supabase: SupabaseService

    @AppStorage("display_mode")  private var displayMode:  String = "Just the Highlights"
    @AppStorage("response_tone") private var responseTone: String = "Balanced"

    private let displayModeOptions  = ["Just the Highlights", "Full Detail", "Compact"]
    private let responseToneOptions = ["Balanced", "Clinical", "Motivational"]

    var body: some View {
        VStack(spacing: 10) {
            AccountSectionHeader(label: "NOTIFICATIONS")
            NotificationPreferencesView()

            AccountSectionHeader(label: "DISPLAY").padding(.top, 4)
            PickerPreferenceRow(
                icon:     "rectangle.3.group",
                label:    "Display Mode",
                options:  displayModeOptions,
                selected: $displayMode
            )
            PickerPreferenceRow(
                icon:     "waveform",
                label:    "Response Tone",
                options:  responseToneOptions,
                selected: $responseTone
            )

            AccountPhase2Separator()
            AccountRowGreyed(icon: "text.alignleft",          label: "Explanation Depth",    value: "Standard")
            AccountRowGreyed(icon: "dial.medium",             label: "Nudge Intensity",      value: "Standard")
            AccountRowGreyed(icon: "arrow.trianglehead.2.counterclockwise", label: "Nudge Type", value: "Mixed")
            AccountRowGreyed(icon: "textformat.size",         label: "Font Size",            value: "16pt")
            AccountRowGreyed(icon: "play.slash",              label: "Reduced Animation",    value: "Off")
            AccountRowGreyed(icon: "circle.lefthalf.filled",  label: "High Contrast",        value: "Off")
            AccountRowGreyed(icon: "flask",                   label: "Beta Features",        value: "Off")
        }
        .padding(.horizontal, 20).padding(.top, 20)
    }
}

// ─────────────────────────────────────────
// TAB 3: CONNECTIONS
// Sprint 5 — R7 updated: union HKSourceQuery across quantity types + BP correlation.
// Covers Apple Watch (stepCount/heartRate), smart scale (bodyMass/bodyFat/BMI),
// BP cuff via HKCorrelationType.bloodPressure — the correct registration point for BP devices.
// Deduplicated via Set<String>. UI layer unchanged — only loadConnectedDevices() is replaced.
// ─────────────────────────────────────────

struct AccountConnectionsTab: View {
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @ObservedObject private var terra = TerraService.shared

    @State private var connectedDevices: [String] = []
    @State private var devicesLoaded = false

    private var userId: String { supabase.session?.userId ?? supabase.currentUser?.id ?? "" }

    var body: some View {
        VStack(spacing: 10) {
            AccountSectionHeader(label: "APPLE HEALTH")

            AccountRow(icon: "applewatch", label: "HealthKit", value: "Connected",
                       valueColor: Color(red: 0.40, green: 0.82, blue: 0.50))

            // Sprint 5: Device list populated via union query — see loadConnectedDevices()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "iphone")
                        .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                    Text("Connected Devices").font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, devicesLoaded && !connectedDevices.isEmpty ? 8 : 14)

                if !devicesLoaded {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6).tint(ChronosTheme.gold.opacity(0.5))
                        Text("Reading devices...").font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint)
                    }.padding(.horizontal, 16).padding(.bottom, 14)
                } else if connectedDevices.isEmpty {
                    Text("None detected").font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.muted)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(connectedDevices, id: \.self) { device in
                            HStack(spacing: 10) {
                                Circle().fill(Color(red: 0.40, green: 0.82, blue: 0.50)).frame(width: 5, height: 5)
                                Text(device).font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.muted)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1)))

            ResyncCard().environmentObject(supabase).environmentObject(sync)

            // ── Sprint 8: Terra Wearable Devices ─────────────────────────────
            AccountSectionHeader(label: "WEARABLE DEVICES")

            // Beta disclosure: Terra SDK not yet active — connect() is a stub.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                Text("Wearable connections are not active in this beta. Apple Health remains your primary data source.")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(TerraProvider.supported.enumerated()), id: \.element.id) { index, provider in
                    TerraProviderRow(provider: provider, terra: terra, userId: userId)
                    if index < TerraProvider.supported.count - 1 {
                        Divider()
                            .background(ChronosTheme.border)
                            .padding(.leading, 50)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1)))

            // Terra data note
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                Text("Terra data supplements Apple Health. Apple Watch values take precedence when both sources report the same metric.")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            AccountPhase2Separator()
            AccountRowGreyed(icon: "xmark.circle",   label: "Exclude Today's Data", value: "")
            AccountRowGreyed(icon: "arrow.clockwise", label: "Sync Frequency",      value: "On app open")
        }
        .padding(.horizontal, 20).padding(.top, 20)
        .task {
            await loadConnectedDevices()
            await terra.load(userId: userId)
        }
    }

    // MARK: - Sprint 5: Union HKSourceQuery across quantity types + blood pressure correlation.
    //
    // Blood pressure is stored as HKCorrelationType (.bloodPressure), not a HKQuantityType.
    // BP devices register their source against the correlation — querying only
    // .bloodPressureSystolic (quantity) will miss the cuff entirely.
    // This function runs two query passes:
    //   Pass 1 — HKQuantityType identifiers (Watch, scale, heartRate catch-all)
    //   Pass 2 — HKCorrelationType.bloodPressure (BP cuff)
    // Both passes feed the same Set<String> and share the same DispatchGroup.
    // group.notify fires once, atomically, after all queries complete.
    // Set<String> deduplicates — any device writing multiple types appears exactly once.
    // The MBI app bundle is filtered from all passes.

    private func loadConnectedDevices() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            connectedDevices = []; devicesLoaded = true; return
        }

        let store = HKHealthStore()
        let bundlePrefix = Bundle.main.bundleIdentifier ?? "com.mbi"
        var allSourceNames: Set<String> = []
        let group = DispatchGroup()

        // Pass 1 — Quantity types: Watch (stepCount/heartRate), scale (bodyMass — weight only)
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .stepCount,             // Apple Watch, iPhone
            .heartRate,             // Broad catch — most wearables write heartRate
            .bodyMass               // Smart scale — weight only, no additional body composition metrics
        ]

        for identifier in quantityIdentifiers {
            guard let sampleType = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            group.enter()
            let query = HKSourceQuery(sampleType: sampleType, samplePredicate: nil) { _, sources, _ in
                if let sources = sources {
                    for source in sources where !source.bundleIdentifier.hasPrefix(bundlePrefix) {
                        allSourceNames.insert(source.name)
                    }
                }
                group.leave()
            }
            store.execute(query)
        }

        // Pass 2 — Blood pressure correlation type.
        // BP devices write HKCorrelationType.bloodPressure, not HKQuantityType.bloodPressureSystolic.
        // This is the correct registration point for the BP cuff source.
        if let bpType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) {
            group.enter()
            let bpQuery = HKSourceQuery(sampleType: bpType, samplePredicate: nil) { _, sources, _ in
                if let sources = sources {
                    for source in sources where !source.bundleIdentifier.hasPrefix(bundlePrefix) {
                        allSourceNames.insert(source.name)
                    }
                }
                group.leave()
            }
            store.execute(bpQuery)
        }

        group.notify(queue: .main) {
            self.connectedDevices = allSourceNames.sorted()
            self.devicesLoaded = true
        }
    }
}

// ─────────────────────────────────────────
// TERRA PROVIDER ROW
// Sprint 8: Per-provider connection row shown inside WEARABLE DEVICES card.
// Fires TerraService.connect/disconnect. While connecting, shows ProgressView
// in place of the button and disables interaction.
// ─────────────────────────────────────────

struct TerraProviderRow: View {
    let provider: TerraProvider
    @ObservedObject var terra: TerraService
    let userId: String

    private var isConnected:  Bool { terra.isConnected(provider) }
    private var isConnecting: Bool { terra.isConnecting == provider.id }

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            Image(systemName: provider.sfSymbol)
                .font(.system(size: 16, weight: .light))
                .foregroundColor(isConnected ? ChronosTheme.gold : ChronosTheme.muted)
                .frame(width: 22)

            // Label + description
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.jost(size: 13, weight: isConnected ? .medium : .light))
                    .foregroundColor(isConnected ? ChronosTheme.text : ChronosTheme.muted)
                Text(provider.description)
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
            }

            Spacer()

            // Connect / Disconnect / Loading
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(ChronosTheme.gold.opacity(0.6))
                    .frame(width: 70)
            } else if isConnected {
                Button {
                    Task { await terra.disconnect(provider: provider, userId: userId) }
                } label: {
                    Text("Disconnect")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.75, green: 0.35, blue: 0.35))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(red: 0.75, green: 0.35, blue: 0.35).opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color(red: 0.75, green: 0.35, blue: 0.35).opacity(0.35), lineWidth: 1))
                        )
                }
                .disabled(terra.isConnecting != nil)
            } else {
                Button {
                    Task { await terra.connect(provider: provider, userId: userId) }
                } label: {
                    Text("Connect")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(ChronosTheme.gold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(ChronosTheme.gold.opacity(0.10))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(ChronosTheme.gold.opacity(0.35), lineWidth: 1))
                        )
                }
                .disabled(terra.isConnecting != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// ─────────────────────────────────────────
// TAB 4: ACCOUNT
// Sprint 5: Password Change → email reset. Delete Account → destructive flow.
// ─────────────────────────────────────────

struct AccountAccountTab: View {
    let user: MBIUser?
    let score: DailyScore?
    @Binding var showSignOutConfirm: Bool
    @EnvironmentObject var supabase: SupabaseService

    @State private var showDeleteConfirm    = false
    @State private var isDeletingAccount    = false
    @State private var deleteError: String? = nil
    @State private var passwordResetSent    = false
    @State private var passwordResetError: String? = nil
    @State private var showPrivacyPolicy    = false
    @State private var showTerms            = false

    // P4.4: Horizon Check-ins toggle — persisted locally.
    // When false, escalation detection still runs server-side but no founder push is sent.
    // Default ON — opt-out model.
    @AppStorage("horizon_checkins_enabled") private var horizonCheckinsEnabled: Bool = true

    // S2: Biometric lock — observed for toggle rendering and availability check
    @ObservedObject private var biometric = BiometricAuthService.shared

    // Sprint 7: Consistency Score
    @State private var consistencyScore: Double = 0

    private var consistencyLabel: String {
        let pct = Int(consistencyScore * 100)
        if pct == 0 { return "—" }
        return "\(pct)% · last 30 days"
    }

    private var consistencyColor: Color {
        if consistencyScore >= 0.80 { return Color(red: 0.40, green: 0.82, blue: 0.50) }
        if consistencyScore >= 0.50 { return ChronosTheme.gold }
        return ChronosTheme.muted
    }

    var body: some View {
        VStack(spacing: 10) {
            AccountSectionHeader(label: "IDENTITY")
            AccountRow(icon: "person",   label: "Display Name", value: user?.displayName ?? "—")
            AccountRow(icon: "envelope", label: "Email",        value: user?.email ?? "—")

            AccountSectionHeader(label: "PLATFORM").padding(.top, 8)
            AccountRow(icon: "heart.fill", label: "Apple Health", value: "Connected",
                       valueColor: Color(red: 0.40, green: 0.82, blue: 0.50))
            if let score {
                AccountRow(icon: "waveform.path.ecg", label: "Score Status",
                           value: score.isProvisional ? "Building baseline" : "Baseline active",
                           valueColor: score.isProvisional ? ChronosTheme.gold : Color(red: 0.40, green: 0.82, blue: 0.50))
                AccountRow(icon: "cpu", label: "Engine", value: score.domainVersion)
            }
            // Sprint 7: Consistency Score — rolling 30-day tracking completeness
            AccountRow(icon: "calendar.badge.checkmark", label: "Consistency Score",
                       value: consistencyLabel, valueColor: consistencyColor)
            AccountRow(icon: "info.circle", label: "App Version",
                       value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—")

            // ── Privacy — S2: Biometric lock + P4.4: Horizon check-in toggle ──
            AccountSectionHeader(label: "PRIVACY").padding(.top, 8)

            VStack(alignment: .leading, spacing: 0) {

                // S2: Biometric lock toggle — only shown when Face ID / Touch ID is enrolled
                if biometric.isBiometricAvailable {
                    HStack(spacing: 14) {
                        Image(systemName: biometric.biometricName == "Touch ID" ? "touchid" : "faceid")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.gold)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(biometric.biometricName) Lock")
                                .font(.jost(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.text)
                            Text("Require \(biometric.biometricName) when returning to Chronos.")
                                .font(.jost(size: 10, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $biometric.isEnabled)
                            .labelsHidden()
                            .tint(ChronosTheme.gold)
                            .scaleEffect(0.85)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    Rectangle().fill(ChronosTheme.border).frame(height: 1).padding(.horizontal, 16)
                }

                // P4.4: Horizon Check-ins toggle
                HStack(spacing: 14) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Horizon Check-ins")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                        Text("Allow Mynd & Bodi to reach out if a sustained low-score trend is detected.")
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $horizonCheckinsEnabled)
                        .labelsHidden()
                        .tint(ChronosTheme.gold)
                        .scaleEffect(0.85)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(ChronosTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1))

            AccountSectionHeader(label: "LEGAL").padding(.top, 8)
            AccountTappableRow(icon: "doc.text",           label: "Privacy Policy")            { showPrivacyPolicy = true }
            AccountTappableRow(icon: "doc.badge.gearshape", label: "Terms of Service")         { showTerms = true }


            // ── Password Change ──
            AccountSectionHeader(label: "SECURITY").padding(.top, 8)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: sendPasswordReset) {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                        Text("Password Change")
                            .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }.buttonStyle(.plain)

                if passwordResetSent {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .light))
                            .foregroundColor(Color(red: 0.40, green: 0.82, blue: 0.50))
                        Text("Reset link sent to your email.")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(Color(red: 0.40, green: 0.82, blue: 0.50))
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                } else if let err = passwordResetError {
                    Text(err).font(.jost(size: 11, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1)))

            // ── Sign Out ──
            Button(action: { showSignOutConfirm = true }) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 13, weight: .light))
                    Text("Sign Out").font(.jost(size: 13, weight: .light)).tracking(1)
                }
                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45).opacity(0.8))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.15), lineWidth: 1)))
            }
            .padding(.top, 4)

            // ── Delete Account ──
            VStack(spacing: 0) {
                Button(action: { showDeleteConfirm = true }) {
                    HStack(spacing: 10) {
                        if isDeletingAccount {
                            ProgressView().scaleEffect(0.75).tint(Color(red: 1.0, green: 0.45, blue: 0.45))
                        } else {
                            Image(systemName: "trash").font(.system(size: 13, weight: .light))
                        }
                        Text(isDeletingAccount ? "Deleting account..." : "Delete Account")
                            .font(.jost(size: 13, weight: .light)).tracking(0.5)
                    }
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45).opacity(0.6))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.10), lineWidth: 1)))
                }
                .disabled(isDeletingAccount)

                if let err = deleteError {
                    Text(err).font(.jost(size: 11, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                        .padding(.top, 6).padding(.horizontal, 4)
                }
            }

            AccountPhase2Separator().padding(.top, 4)
            AccountRowGreyed(icon: "creditcard",               label: "Subscription Plan",        value: "Phase 1")
            AccountRowGreyed(icon: "bell.badge",               label: "Notification Permissions", value: "Off")
            AccountRowGreyed(icon: "exclamationmark.triangle", label: "Redline Escalation",       value: "Passive")
            AccountRowGreyed(icon: "brain",                    label: "AI Training Opt-out",      value: "Opted in")
            AccountRowGreyed(icon: "flask",                    label: "Research Participation",   value: "Opted in")
        }
        .padding(.horizontal, 20).padding(.top, 20)
        .task {
            // Sprint 7: fetch consistency score on tab appearance
            guard let userId = supabase.session?.userId else { return }
            consistencyScore = await supabase.fetchConsistencyScore(userId: userId)
        }
        .confirmationDialog(
            "Delete account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all data. This cannot be undone.")
        }
        .sheet(isPresented: $showPrivacyPolicy) { PolicyView(document: .privacyPolicy) }
        .sheet(isPresented: $showTerms)         { PolicyView(document: .termsOfService) }
    }

    // MARK: - Actions

    private func sendPasswordReset() {
        guard let email = user?.email, !email.isEmpty else { return }
        passwordResetSent  = false
        passwordResetError = nil
        Task {
            do {
                try await supabase.sendPasswordReset(email: email)
                await MainActor.run { passwordResetSent = true }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { passwordResetSent = false }
            } catch {
                await MainActor.run { passwordResetError = "Couldn't send reset link — try again." }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { passwordResetError = nil }
            }
        }
    }

    private func deleteAccount() {
        isDeletingAccount = true
        deleteError       = nil
        Task {
            do {
                try await supabase.deleteCurrentUser()
            } catch {
                await MainActor.run {
                    isDeletingAccount = false
                    deleteError = "Deletion failed — contact support@myndandbodi.com"
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// RESYNC CARD  (unchanged)
// ─────────────────────────────────────────

struct ResyncCard: View {
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator

    @State private var isResyncing = false
    @State private var isDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync History").font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Text("Imports Apple Watch history not yet in Chronos. Skips dates already synced.")
                        .font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint).lineSpacing(3)
                }
                Spacer()
                if isDone { Image(systemName: "checkmark.circle").font(.system(size: 16, weight: .light))
                    .foregroundColor(Color(red: 0.40, green: 0.82, blue: 0.50)) }
            }

            if isResyncing {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(ChronosTheme.faint.opacity(0.3)).frame(height: 2)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [ChronosTheme.gold.opacity(0.6), ChronosTheme.goldLight], startPoint: .leading, endPoint: .trailing))
                                .frame(width: sync.backfillTotal > 0
                                    ? geo.size.width * CGFloat(sync.backfillDone) / CGFloat(sync.backfillTotal)
                                    : 0, height: 2)
                        }
                    }.frame(height: 2)
                    Text(sync.backfillTotal == 0
                        ? "Scanning history..."
                        : "Day \(sync.backfillDone) of \(sync.backfillTotal)")
                        .font(.jost(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if !sync.backfillProgress.isEmpty && !isResyncing {
                Text(sync.backfillProgress)
                    .font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint).lineSpacing(3)
            }

            if !isResyncing {
                Button(action: runBackfill) {
                    Text(isDone ? "Sync Again" : "Start Sync")
                        .font(.jost(size: 12, weight: .medium)).foregroundColor(ChronosTheme.gold).tracking(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChronosTheme.gold.opacity(0.35), lineWidth: 1))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1)))
    }

    private func runBackfill() {
        guard let userId = supabase.session?.userId else { return }
        isResyncing = true; isDone = false
        Task {
            await sync.runHistoricalBackfill(userId: userId)
            await sync.loadDashboard(userId: userId)
            isDone = true
            isResyncing = false
        }
    }
}

// ─────────────────────────────────────────
// SHARED SUBCOMPONENTS
// ─────────────────────────────────────────

struct AccountSectionHeader: View {
    let label: String
    var body: some View {
        HStack {
            Text(label).font(.jost(size: 9, weight: .light)).foregroundColor(ChronosTheme.faint).tracking(2)
            Rectangle().fill(ChronosTheme.border).frame(height: 1)
        }.padding(.top, 4)
    }
}

// R6: Phase 2 separator label — muted.opacity(0.7) replaces faint.opacity(0.6)
struct AccountPhase2Separator: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(ChronosTheme.border).frame(height: 1)
            Text("PHASE 2").font(.jost(size: 8, weight: .light))
                .foregroundColor(ChronosTheme.muted.opacity(0.7)).tracking(2).fixedSize()
            Rectangle().fill(ChronosTheme.border).frame(height: 1)
        }.padding(.top, 8)
    }
}

struct AccountRow: View {
    let icon: String; let label: String; let value: String
    var valueColor: Color = ChronosTheme.muted
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
            Text(label).font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
            Spacer()
            Text(value).font(.jost(size: 12, weight: .light)).foregroundColor(valueColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1)))
    }
}

struct AccountTappableRow: View {
    let icon: String; let label: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 13, weight: .light)).foregroundColor(ChronosTheme.gold).frame(width: 20)
                Text(label).font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1)))
        }.buttonStyle(.plain)
    }
}

// R6: Opacity values raised — icon 0.4→0.6, label 0.5→0.65, value 0.4→0.55
// Greyed rows are now legible while still clearly distinct from active rows.
struct AccountRowGreyed: View {
    let icon: String; let label: String; let value: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.faint.opacity(0.6)).frame(width: 20)
            Text(label).font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.muted.opacity(0.65))
            Spacer()
            if !value.isEmpty {
                Text(value).font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.faint.opacity(0.55))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border.opacity(0.4), lineWidth: 1)))
    }
}

// ─────────────────────────────────────────
// PICKER PREFERENCE ROW
// Sprint 5 — Expandable inline option picker for Display Mode, Response Tone.
// Selected value stored via @Binding (driven by @AppStorage in parent).
// ─────────────────────────────────────────

struct PickerPreferenceRow: View {
    let icon:    String
    let label:   String
    let options: [String]
    @Binding var selected: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold).frame(width: 20)
                    Text(label)
                        .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Spacer()
                    Text(selected)
                        .font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(ChronosTheme.border).frame(height: 1)

                    ForEach(options, id: \.self) { option in
                        Button(action: {
                            selected = option
                            withAnimation(.easeInOut(duration: 0.15)) { isExpanded = false }
                        }) {
                            HStack {
                                Text(option)
                                    .font(.jost(size: 13,
                                                weight: selected == option ? .medium : .light))
                                    .foregroundColor(selected == option
                                                     ? ChronosTheme.goldLight
                                                     : ChronosTheme.muted)
                                Spacer()
                                if selected == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .light))
                                        .foregroundColor(ChronosTheme.gold)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        if option != options.last {
                            Rectangle()
                                .fill(ChronosTheme.border.opacity(0.5))
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// Retained for external reference safety
struct AccountStatsPills: View {
    let score: DailyScore
    var body: some View {
        HStack(spacing: 10) {
            AccountStatPill(label: "Today", value: "\(Int(score.chronosScore))", color: ChronosTheme.goldLight)
            AccountStatPill(label: "D1", value: score.d1Autonomic.map { "\(Int($0))" } ?? "—", color: domainColor(score.d1Autonomic))
            AccountStatPill(label: "D2", value: score.d2Sleep.map { "\(Int($0))" } ?? "—",      color: domainColor(score.d2Sleep))
            AccountStatPill(label: "D3", value: score.d3Activity.map { "\(Int($0))" } ?? "—",   color: domainColor(score.d3Activity))
        }
    }
    private func domainColor(_ val: Double?) -> Color {
        guard let v = val else { return ChronosTheme.faint }
        if v >= 80 { return Color(red: 0.40, green: 0.82, blue: 0.50) }
        if v >= 60 { return ChronosTheme.goldLight }
        if v >= 40 { return Color(red: 1.0, green: 0.78, blue: 0.28) }
        return Color(red: 1.0, green: 0.40, blue: 0.40)
    }
}

struct AccountStatPill: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.cormorant(size: 20, weight: .light)).foregroundColor(color)
            Text(label.uppercased()).font(.jost(size: 8, weight: .light)).foregroundColor(ChronosTheme.muted).tracking(1.5)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(ChronosTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChronosTheme.border, lineWidth: 1)))
    }
}
