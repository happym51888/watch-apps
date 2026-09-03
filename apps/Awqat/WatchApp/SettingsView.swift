import SwiftUI

struct SettingsView: View {
    @Environment(PrayerModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Calculation") {
                    NavigationLink {
                        MethodPicker()
                    } label: {
                        LabeledContent("Method") {
                            Text(model.settings.method.displayName)
                                .font(.caption2)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    Picker("Asr", selection: asrBinding) {
                        Text("Standard").tag(AsrSchool.standard)
                        Text("Hanafi").tag(AsrSchool.hanafi)
                    }

                    NavigationLink("High latitude") { HighLatitudePicker() }
                }

                Section {
                    NavigationLink("Adjust minutes") { AdjustmentsView() }
                } footer: {
                    Text("Shift any prayer by a few minutes to match your mosque's printed timetable.")
                        .font(.system(size: 9))
                }

                Section("Fajr alarm") { fajrAlarmSection }

                Section("Notifications") {
                    ForEach(Prayer.allCases.filter(\.isObligatoryPrayer)) { prayer in
                        Toggle(prayer.displayName, isOn: notifyBinding(prayer))
                            .disabled(prayer == .fajr && model.settings.fajrAlarmEnabled)
                    }
                }

                Section("Tasbih") {
                    Picker("Set size", selection: targetBinding) {
                        Text("33").tag(33)
                        Text("34").tag(34)
                        Text("100").tag(100)
                        Text("No target").tag(0)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Fajr alarm

    @ViewBuilder
    private var fajrAlarmSection: some View {
        Toggle("Wake me for Fajr", isOn: fajrAlarmBinding)

        if model.settings.fajrAlarmEnabled {
            Picker("Ring", selection: leadBinding) {
                Text("At Fajr").tag(0)
                Text("10 min before").tag(10)
                Text("20 min before").tag(20)
                Text("30 min before").tag(30)
                Text("45 min before").tag(45)
                Text("1 hour before").tag(60)
            }

            if let armed = model.alarmArmedFor {
                Label {
                    Text("Set for \(armed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                } icon: {
                    Image(systemName: "alarm.waves.left.and.right.fill")
                }
                .foregroundStyle(.green)
            } else if let problem = model.alarmProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            // Said plainly, because the honest limits are what make the feature
            // trustworthy rather than a promise the watch cannot keep.
            Text("This is a real alarm, not a notification: it buzzes repeatedly until you dismiss it, and it works in Silent Mode. watchOS allows one at a time and only 36 hours ahead, so Awqat re-arms it each time you open the app.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var asrBinding: Binding<AsrSchool> {
        Binding(
            get: { model.settings.asrSchool },
            set: { value in model.update { $0.asrSchool = value } }
        )
    }

    private var fajrAlarmBinding: Binding<Bool> {
        Binding(
            get: { model.settings.fajrAlarmEnabled },
            set: { value in model.update { $0.fajrAlarmEnabled = value } }
        )
    }

    private var leadBinding: Binding<Int> {
        Binding(
            get: { model.settings.fajrAlarmLeadMinutes },
            set: { value in model.update { $0.fajrAlarmLeadMinutes = value } }
        )
    }

    private var targetBinding: Binding<Int> {
        Binding(
            get: { model.settings.tasbihTarget },
            set: { value in model.update { $0.tasbihTarget = value } }
        )
    }

    private func notifyBinding(_ prayer: Prayer) -> Binding<Bool> {
        Binding(
            get: { model.settings.notify.contains(prayer.rawValue) },
            set: { value in
                model.update {
                    if value { $0.notify.insert(prayer.rawValue) }
                    else { $0.notify.remove(prayer.rawValue) }
                }
            }
        )
    }
}

// MARK: - Method

private struct MethodPicker: View {
    @Environment(PrayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(CalculationMethod.allCases) { method in
            Button {
                model.update { $0.method = method }
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(method.displayName)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                        Text(describe(method))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if method == model.settings.method {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Method")
    }

    /// Showing the actual angles is what lets a user reconcile the app with
    /// their mosque instead of guessing which name to pick.
    private func describe(_ method: CalculationMethod) -> String {
        let parameters = method.parameters
        let isha = switch parameters.ishaRule {
        case .angle(let degrees): "Isha \(format(degrees))°"
        case .intervalAfterMaghrib(let minutes): "Isha +\(minutes) min"
        }
        return "Fajr \(format(parameters.fajrAngle))° · \(isha)"
    }

    private func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

// MARK: - High latitude

private struct HighLatitudePicker: View {
    @Environment(PrayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(HighLatitudeRule.allCases, id: \.self) { rule in
                    Button {
                        model.update { $0.highLatitudeRule = rule }
                        dismiss()
                    } label: {
                        HStack {
                            Text(rule.displayName).font(.caption)
                            Spacer()
                            if rule == model.settings.highLatitudeRule {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("In summer at northern latitudes the sun never goes far enough below the horizon for Fajr and Isha to have an astronomical time. None of these rules is more correct than the others — they are conventions. Follow whichever your local mosque uses.")
                    .font(.system(size: 9))
            }
        }
        .navigationTitle("High latitude")
    }
}

// MARK: - Adjustments

private struct AdjustmentsView: View {
    @Environment(PrayerModel.self) private var model

    var body: some View {
        List {
            stepper("Fajr", \.adjustmentFajr)
            stepper("Sunrise", \.adjustmentSunrise)
            stepper("Dhuhr", \.adjustmentDhuhr)
            stepper("Asr", \.adjustmentAsr)
            stepper("Maghrib", \.adjustmentMaghrib)
            stepper("Isha", \.adjustmentIsha)
        }
        .navigationTitle("Adjust")
    }

    private func stepper(
        _ title: String,
        _ keyPath: WritableKeyPath<Settings, Int>
    ) -> some View {
        let value = model.settings[keyPath: keyPath]
        return Stepper(
            value: Binding(
                get: { value },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } }
            ),
            in: -30...30
        ) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(value == 0 ? "—" : (value > 0 ? "+\(value)" : "\(value)"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
        }
    }
}
