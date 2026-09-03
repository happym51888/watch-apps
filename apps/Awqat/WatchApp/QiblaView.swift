import SwiftUI
import CoreLocation
import Observation

/// Qibla direction.
///
/// Two honesty rules govern this screen, because it is the one where being
/// confidently wrong actually matters to the user:
///
/// 1. It shows the bearing as a **number** even when the compass is
///    unavailable. A bearing is a fact derived from coordinates; the compass is
///    only how you point yourself at it. A user with a paper compass, or one
///    who knows which way is north, is served by the number alone.
/// 2. It refuses to rotate the needle when heading accuracy is poor. A needle
///    that swings confidently while reading ±40° is worse than no needle.
struct QiblaView: View {
    @Environment(PrayerModel.self) private var model
    @State private var compass = Compass()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if let qibla = model.qibla {
                        dial(bearing: qibla.bearing)

                        Text("\(Int(qibla.bearing.rounded()))° from true north")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if let distance = model.distanceToKaaba {
                            Text("\(Int(distance.rounded())) km to the Kaaba")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        accuracyNote
                    } else {
                        Text("Waiting for a location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("Qibla")
        }
        .onAppear { compass.start() }
        .onDisappear { compass.stop() }
    }

    @ViewBuilder
    private func dial(bearing: Double) -> some View {
        // When the heading is trustworthy the needle points at the Qibla
        // relative to where you are facing. When it is not, the dial locks to
        // north-up and the needle simply shows the bearing.
        let usable = compass.isUsable
        let rotation = usable ? bearing - compass.heading : bearing

        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 1)

            ForEach(0..<4) { index in
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: 6)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(index) * 90))
            }

            Text(usable ? "" : "N")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(y: -44)

            Image(systemName: "location.north.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .offset(y: -14)
                .rotationEffect(.degrees(rotation))
                .animation(.easeOut(duration: 0.25), value: rotation)
        }
        .frame(width: 96, height: 96)
    }

    @ViewBuilder
    private var accuracyNote: some View {
        if !compass.isAvailable {
            Text("No compass on this watch — the number above is still correct.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if !compass.isUsable {
            Label(
                "Compass unreliable. Move away from metal and magnets, then turn your wrist in a figure of eight.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 9))
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
        }
    }
}

/// Thin wrapper over `CLLocationManager` heading updates.
@MainActor
@Observable
final class Compass: NSObject {

    private(set) var heading: Double = 0
    private(set) var accuracy: Double = -1
    private(set) var isAvailable = CLLocationManager.headingAvailable()

    /// Core Location reports negative accuracy when the reading is invalid.
    /// Anything worse than 20° is not good enough to aim a prayer direction
    /// with, so the needle stops pretending.
    var isUsable: Bool { isAvailable && accuracy >= 0 && accuracy <= 20 }

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard isAvailable else { return }
        manager.startUpdatingHeading()
    }

    func stop() {
        guard isAvailable else { return }
        manager.stopUpdatingHeading()
    }
}

extension Compass: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        // True heading needs a location fix; magnetic is the fallback. The
        // Qibla bearing is computed from true north, so a magnetic reading is
        // off by the local declination and is flagged rather than silently used
        // as if it were true.
        // Everything needed is read off CLHeading here, on the delegate's
        // thread. CLHeading is not Sendable, so the hop below must carry only
        // these plain values and never the heading object itself.
        let isTrueNorth = newHeading.trueHeading >= 0
        let value = isTrueNorth ? newHeading.trueHeading : newHeading.magneticHeading
        let reported = newHeading.headingAccuracy
        let accuracy = isTrueNorth ? reported : max(reported, 25)
        Task { @MainActor in
            self.heading = value
            self.accuracy = accuracy
        }
    }
}
