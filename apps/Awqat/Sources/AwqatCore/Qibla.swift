import Foundation

/// Direction of the Kaaba from a point on Earth.
public struct Qibla: Sendable, Equatable {
    /// The Kaaba, Masjid al-Haram, Makkah.
    public static let kaaba = Coordinates(latitude: 21.4225241, longitude: 39.8261818)

    /// Initial great-circle bearing to the Kaaba, degrees clockwise from true north.
    public let bearing: Double

    public init(from coordinates: Coordinates) {
        let phi1 = radians(coordinates.latitude)
        let phi2 = radians(Self.kaaba.latitude)
        let deltaLambda = radians(Self.kaaba.longitude - coordinates.longitude)

        // Standard initial-bearing formula for a great circle. This is the correct
        // one for Qibla: a rhumb line drawn on a Mercator map gives a visibly wrong
        // direction from high latitudes, which is why "the Qibla points north-east
        // from North America" surprises people.
        let y = sin(deltaLambda)
        let x = cos(phi1) * tan(phi2) - sin(phi1) * cos(deltaLambda)
        self.bearing = normalizeDegrees(degrees(atan2(y, x)))
    }

    /// Great-circle distance to the Kaaba in kilometres, mean-Earth-radius sphere.
    public static func distanceKilometres(from coordinates: Coordinates) -> Double {
        let earthRadius = 6371.0088
        let phi1 = radians(coordinates.latitude)
        let phi2 = radians(kaaba.latitude)
        let dPhi = phi2 - phi1
        let dLambda = radians(kaaba.longitude - coordinates.longitude)
        let a = pow(sin(dPhi / 2), 2) + cos(phi1) * cos(phi2) * pow(sin(dLambda / 2), 2)
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }
}
