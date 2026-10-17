//
//  ContentView.swift
//  FlyingTrafficPOC
//
//  Created by Chaitanya Takalikar on 10/16/26.
//

import SwiftUI
import MapboxMaps
import CoreLocation
import Combine
import Foundation
import Turf
import UIKit

// MARK: - Main view

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    
    @StateObject private var location = UserLocationManager()
    @StateObject private var traffic = NearbyTrafficSimulation()
    
    @State private var viewport: Viewport = .followPuck(
        zoom: 17,
        bearing: .heading,
        pitch: 60
    )
    
    @State private var isPlaying = true
    @State private var heightOffset = 0.0
    @State private var lastTick: Date?
    
    private let timer = Timer.publish(
        every: 1.0 / 30.0,
        on: .main,
        in: .common
    ).autoconnect()
    
    private let modelURL: URL? =
    Bundle.main.url(
        forResource: "white",
        withExtension: "glb"
    )
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(viewport: $viewport) {
                Puck2D(bearing: .heading)
                    .showsAccuracyRing(true)

                FleetTrajectoryStyle(
                    lineFeatures: traffic.lineFeatures,
                    verticalFeatures: traffic.verticalFeatures
                )

                ForEvery(traffic.pads, id: \.id) { pad in
                    TrafficPadStyle(pad: pad)
                }

                if let modelURL {
                    ForEvery(traffic.cars, id: \.id) { car in
                        FlyingVehicleStyle(
                            car: car,
                            modelURL: modelURL,
                            heightOffset: heightOffset
                        )
                    }
                }
            }
            .mapStyle(.standard)
            .ignoresSafeArea()

            statusPanel
                .padding()
        }
        .overlay(alignment: .bottomTrailing) {
            recenterButton
                .padding(.trailing, 16)
                .padding(.bottom, 24)
        }
        .onAppear {
            location.start()
        }
        .onReceive(location.$latestLocation) { newLocation in
            guard let newLocation else {
                return
            }

            traffic.updateArea(around: newLocation)
        }
        .onReceive(timer) { now in
            let previous = lastTick ?? now
            lastTick = now

            guard scenePhase == .active, isPlaying else {
                return
            }

            let delta = min(
                max(now.timeIntervalSince(previous), 0),
                0.1
            )

            traffic.advance(by: delta)
        }
        .onChange(of: heightOffset) { _, newValue in
            traffic.cruiseHeight = 120 + newValue
        }
    }
    
    private var recenterButton: some View {
        Button {
            withViewportAnimation(.default(maxDuration: 1)) {
                viewport = .followPuck(
                    zoom: 17,
                    bearing: .constant(0),
                    pitch: 55
                )
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    Color.blue,
                    in: Circle()
                )
                .shadow(
                    color: .black.opacity(0.2),
                    radius: 6,
                    x: 0,
                    y: 3
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Center on my location")
    }
    
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Nearby Flying Traffic")
                .font(.headline)
            
            Text("SIMULATION • Not real traffic")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            Text(traffic.departureSignal.label)
                .font(.caption)
                .foregroundStyle(
                    Color(uiColor: traffic.departureSignal.color)
                )
            
            if let message = location.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            
            if modelURL == nil {
                Text(
                    "Add flying-car.glb"
                    + "to your app target."
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            
            if traffic.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading nearby roads…")
                        .font(.caption)
                }
            }
            
            Text(traffic.status)
                .font(.caption)
            
            Text("Active vehicles: \(traffic.cars.count)")
                .font(.caption)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
    
    // MARK: - Location
    
    @MainActor
    final class UserLocationManager:
        NSObject,
        ObservableObject,
        CLLocationManagerDelegate
    {
        @Published var latestLocation: CLLocation?
        @Published var message: String? = "Waiting for location…"
        
        private let manager = CLLocationManager()
        
        override init() {
            super.init()
            
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 10
        }
        
        func start() {
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
                
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
                
            case .denied, .restricted:
                message =
                "Allow location access in iPhone Settings "
                + "to show nearby traffic."
                
            @unknown default:
                message = "Location access is unavailable."
            }
        }
        
        func locationManagerDidChangeAuthorization(
            _ manager: CLLocationManager
        ) {
            start()
        }
        
        func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]
        ) {
            guard let newest = locations.last,
                  newest.horizontalAccuracy >= 0,
                  newest.horizontalAccuracy <= 100,
                  abs(newest.timestamp.timeIntervalSinceNow) < 30
            else {
                return
            }
            
            latestLocation = newest
            message = nil
        }
        
        func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: Error
        ) {
            if let locationError = error as? CLError,
               locationError.code == .locationUnknown {
                return
            }
            
            message = error.localizedDescription
        }
    }
    
    // MARK: - Render state
    
    struct FlyingVehicle: Identifiable {
        let id: String

        var coordinate: CLLocationCoordinate2D
        var heading: Double
        var height: Double

        // Normal climb/descent attitude.
        var pitchDegrees: Double = 0

        // Additional stunt rotations.
        var stuntRollDegrees: Double = 0
        var stuntPitchDegrees: Double = 0
    }
    
    // MARK: - Signals and overlays
    
    enum DemoSignal {
        case green
        case yellow
        case red
        
        var color: UIColor {
            switch self {
            case .green:
                return .systemGreen
            case .yellow:
                return .systemYellow
            case .red:
                return .systemRed
            }
        }
        
        var label: String {
            switch self {
            case .green:
                return "Green: departure permitted"
            case .yellow:
                return "Yellow: hold new departures"
            case .red:
                return "Red: stop / hold"
            }
        }
    }
    
    // MARK: - Shared 3D trajectory
    
    struct FlightPoint {
        let coordinate: CLLocationCoordinate2D
        let heightMeters: Double
    }
    
    struct LocalFlightPoint {
        let east: Double
        let north: Double
        let height: Double
    }
    
    struct FlightTrajectory {
        let origin: CLLocationCoordinate2D
        let points: [LocalFlightPoint]
        let cumulativeDistances: [Double]
        
        var totalDistance: Double {
            cumulativeDistances.last ?? 0
        }
        
        var geographicPoints: [FlightPoint] {
            points.map { point in
                FlightPoint(
                    coordinate: geographicCoordinate(for: point),
                    heightMeters: point.height
                )
            }
        }
        
        init(
            origin: CLLocationCoordinate2D,
            points: [LocalFlightPoint]
        ) {
            self.origin = origin
            self.points = points
            
            var distances = [0.0]
            
            if points.count >= 2 {
                for index in 1..<points.count {
                    let previous = points[index - 1]
                    let current = points[index]
                    
                    let east = current.east - previous.east
                    let north = current.north - previous.north
                    let height = current.height - previous.height
                    
                    distances.append(
                        distances[index - 1]
                        + sqrt(
                            east * east
                            + north * north
                            + height * height
                        )
                    )
                }
            }
            
            self.cumulativeDistances = distances
        }
        
        func sample(distance: Double) -> FlightPoint {
            guard let first = points.first else {
                return FlightPoint(
                    coordinate: origin,
                    heightMeters: 0
                )
            }
            
            guard points.count >= 2 else {
                return FlightPoint(
                    coordinate: geographicCoordinate(for: first),
                    heightMeters: first.height
                )
            }
            
            let target = min(max(distance, 0), totalDistance)
            
            var segment = points.count - 1
            
            for index in 1..<cumulativeDistances.count {
                if cumulativeDistances[index] >= target {
                    segment = index
                    break
                }
            }
            
            let start = points[segment - 1]
            let end = points[segment]
            
            let segmentDistance =
            cumulativeDistances[segment]
            - cumulativeDistances[segment - 1]
            
            let fraction: Double
            
            if segmentDistance > 0.000001 {
                fraction = (
                    target - cumulativeDistances[segment - 1]
                ) / segmentDistance
            } else {
                fraction = 0
            }
            
            let point = LocalFlightPoint(
                east: start.east
                + (end.east - start.east) * fraction,
                north: start.north
                + (end.north - start.north) * fraction,
                height: start.height
                + (end.height - start.height) * fraction
            )
            
            return FlightPoint(
                coordinate: geographicCoordinate(for: point),
                heightMeters: point.height
            )
        }
        
        private func geographicCoordinate(
            for point: LocalFlightPoint
        ) -> CLLocationCoordinate2D {
            let metersPerDegree = 111_320.0
            let latitudeRadians = origin.latitude * .pi / 180
            
            return CLLocationCoordinate2D(
                latitude: origin.latitude
                + point.north / metersPerDegree,
                longitude: origin.longitude
                + point.east
                / (metersPerDegree * cos(latitudeRadians))
            )
        }
    }
    
    enum FlightTrajectoryBuilder {
        static func make(
            pickup: CLLocationCoordinate2D,
            destination: CLLocationCoordinate2D,
            cruiseHeight: Double,
            nearThresholdMeters: Double = 150
        ) -> FlightTrajectory {
            let metersPerDegree = 111_320.0

            let latitudeRadians =
                pickup.latitude * .pi / 180

            let east =
                (destination.longitude - pickup.longitude)
                * metersPerDegree
                * cos(latitudeRadians)

            let north =
                (destination.latitude - pickup.latitude)
                * metersPerDegree

            let groundDistance = sqrt(
                east * east + north * north
            )

            let start = LocalFlightPoint(
                east: 0,
                north: 0,
                height: 0
            )

            let end = LocalFlightPoint(
                east: east,
                north: north,
                height: 0
            )

            // Handle a degenerate trip without building an arc.
            guard groundDistance > 0.01 else {
                return FlightTrajectory(
                    origin: pickup,
                    points: [start, end]
                )
            }

            let isLongTrip =
                groundDistance > nearThresholdMeters

            // Preserve the first 5% ground-driving requirement
            // for longer trips only.
            let groundFraction = isLongTrip ? 0.05 : 0.0

            let takeoffEast = east * groundFraction
            let takeoffNorth = north * groundFraction

            let flightEast = east - takeoffEast
            let flightNorth = north - takeoffNorth

            // All routes are curved, but short trips have
            // a lower peak than long trips.
            let maximumHeight = max(cruiseHeight, 1)

            let peakHeight: Double

            if isLongTrip {
                peakHeight = maximumHeight
            } else {
                peakHeight = min(
                    maximumHeight,
                    max(20, groundDistance * 0.35)
                )
            }

            let sampleCount = 40

            var points: [LocalFlightPoint] = []
            points.reserveCapacity(sampleCount + 2)

            if isLongTrip {
                // Ground leg: pickup -> takeoff position.
                points.append(start)
            }

            // Smooth altitude profile:
            //
            // height(t) = H * 64 * t³ * (1 - t)³
            //
            // t = 0: ground
            // t = 0.5: peak height
            // t = 1: ground
            //
            // The altitude slope is zero at both endpoints,
            // avoiding a vertical takeoff/landing corner.
            for index in 0...sampleCount {
                let t =
                    Double(index) / Double(sampleCount)

                let u = 1 - t

                let heightFactor =
                    64 * t * t * t * u * u * u

                points.append(
                    LocalFlightPoint(
                        east: takeoffEast + flightEast * t,
                        north: takeoffNorth + flightNorth * t,
                        height: peakHeight * heightFactor
                    )
                )
            }

            return FlightTrajectory(
                origin: pickup,
                points: points
            )
        }
    }
    
    struct TrafficPad: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let signal: DemoSignal
    }
    
    struct TrafficPath: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        
        // Height relative to the ground.
        let heightMeters: Double
    }
    
    private struct TrafficPadStyle: MapStyleContent {
        let pad: TrafficPad
        
        private var sourceID: String {
            "pad-source-\(pad.id)"
        }
        
        private var layerID: String {
            "pad-layer-\(pad.id)"
        }
        
        private var feature: Feature {
            // A small approximately 8 m × 5 m rectangle.
            let halfWidth = 10.0
            let halfLength = 6.0
            
            let latitudeRadians =
            pad.coordinate.latitude * .pi / 180
            
            let latitudeOffset = halfLength / 111_320
            let longitudeOffset =
            halfWidth / (111_320 * cos(latitudeRadians))
            
            let center = pad.coordinate
            
            let ring: [CLLocationCoordinate2D] = [
                CLLocationCoordinate2D(
                    latitude: center.latitude - latitudeOffset,
                    longitude: center.longitude - longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude - latitudeOffset,
                    longitude: center.longitude + longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude + latitudeOffset,
                    longitude: center.longitude + longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude + latitudeOffset,
                    longitude: center.longitude - longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude - latitudeOffset,
                    longitude: center.longitude - longitudeOffset
                )
            ]
            
            return Feature(
                geometry: .polygon(
                    Polygon([ring])
                )
            )
        }
        
        var body: some MapStyleContent {
            GeoJSONSource(id: sourceID)
                .data(.feature(feature))
            
            FillLayer(
                id: layerID,
                source: sourceID
            )
            .fillColor(pad.signal.color)
            .fillOpacity(0.75)
            .fillOutlineColor(.white)
        }
    }
    
    private struct TrafficPathStyle: MapStyleContent {
        let path: TrafficPath
        
        private var sourceID: String {
            "path-source-\(path.id)"
        }
        
        private var layerID: String {
            "path-layer-\(path.id)"
        }
        
        var body: some MapStyleContent {
            GeoJSONSource(id: sourceID)
                .data(
                    .feature(
                        Feature(
                            geometry: .lineString(
                                LineString(path.coordinates)
                            )
                        )
                    )
                )
            
            LineLayer(
                id: layerID,
                source: sourceID
            )
            .lineColor(.systemBlue)
            .lineWidth(3)
            .lineOpacity(0.8)
            .lineElevationReference(.ground)
            .lineZOffset(path.heightMeters)
        }
    }
    
    private struct FleetTrajectoryStyle: MapStyleContent {
        let lineFeatures: FeatureCollection
        let verticalFeatures: FeatureCollection

        private var flightLineSource: GeoJSONSource {
            var source = GeoJSONSource(
                id: "fleet-flight-lines"
            )

            source.data = .featureCollection(lineFeatures)
            source.lineMetrics = true

            return source
        }

        private var verticalLineSource: GeoJSONSource {
            var source = GeoJSONSource(
                id: "fleet-vertical-lines"
            )

            source.data = .featureCollection(verticalFeatures)

            return source
        }

        var body: some MapStyleContent {
            flightLineSource

            LineLayer(
                id: "fleet-flight-line-layer",
                source: "fleet-flight-lines"
            )
            .lineColor(.systemBlue)
            .lineWidth(3)
            .lineOpacity(0.8)
            .lineElevationReference(.ground)
            .lineZOffset(
                Exp(.interpolate) {
                    Exp(.linear)

                    Exp(.lineProgress)

                    0
                    Exp(.get) {
                        "startHeight"
                    }

                    1
                    Exp(.get) {
                        "endHeight"
                    }
                }
            )

            verticalLineSource

            FillExtrusionLayer(
                id: "fleet-vertical-line-layer",
                source: "fleet-vertical-lines"
            )
            .fillExtrusionColor(.systemBlue)
            .fillExtrusionOpacity(0.7)
            .fillExtrusionBase(
                Exp(.get) {
                    "bottom"
                }
            )
            .fillExtrusionHeight(
                Exp(.get) {
                    "top"
                }
            )
        }
    }
    
    // MARK: - Model rendering
    private struct FlyingVehicleStyle: MapStyleContent {
        let car: FlyingVehicle
        let modelURL: URL
        let heightOffset: Double

        private var sourceID: String {
            "source-\(car.id)"
        }

        private var layerID: String {
            "layer-\(car.id)"
        }

        var body: some MapStyleContent {
            ModelSource(id: sourceID)
                .models([
                    Model(
                        id: car.id,
                        uri: modelURL,
                        position: [
                            car.coordinate.longitude,
                            car.coordinate.latitude
                        ],

                        // Apply visual rotation through the layer below.
                        orientation: [0, 0, 0]
                    )
                ])

            ModelLayer(
                id: layerID,
                source: sourceID
            )
            .modelType(.common3d)
            .modelScale(
                x: 0.01,
                y: 0.01,
                z: 0.01
            )
            .modelRotation(
                x : car.stuntRollDegrees,
                y: car.pitchDegrees + car.stuntPitchDegrees,
                z: car.heading + 90
            )
            .modelTranslation(
                x: 0,
                y: 0,
                z: car.height
            )
            .modelOpacity(1)
        }
    }
    
    // MARK: - Nearby traffic simulation
    @MainActor
    final class NearbyTrafficSimulation: ObservableObject {

        // MARK: Published state

        @Published private(set) var cars: [FlyingVehicle] = []
        @Published private(set) var pads: [TrafficPad] = []

        @Published private(set) var lineFeatures =
            FeatureCollection(features: [])

        @Published private(set) var verticalFeatures =
            FeatureCollection(features: [])

        @Published private(set) var isLoading = false

        @Published private(set) var status =
            "Waiting for your location."

        @Published private(set) var departureSignal:
            DemoSignal = .green

        // Changes apply when the next local area is generated.
        var cruiseHeight = 120.0

        // MARK: Configuration

        private let fleetSize: Int = 7
        private let activeRadius: Double = 804.672
        private let padRingRadius: Double = 350.0
        private let regenerateDistance: Double = 180.0

        private let speed = 12.0
        private let groundDwell = 10.0
        private var lastFleetMaintenanceTime = -1.0

        // A conservative POC envelope around each route.
        // Increase if your rendered vehicles are unusually large.
        private let envelopeRadius = 8.0

        // This permits up to 10 simultaneous flights,
        // but reservations can hold conflicting departures.
        private let maximumConcurrentFlights: Int = 7

        // MARK: Internal state

        private var currentLocation: CLLocation?
        private var areaCenter: CLLocationCoordinate2D?

        private var clock = 0.0

        private var fleet: [TaxiAgent] = []
        private enum StuntKind {
            case none
            case roll
            case pitchFlip
        }
        private struct TaxiAgent {
            let id: String

            // Rotation values at the beginning of the current stunt.
            var stuntStartRoll: Double = 0
            var stuntStartPitch: Double = 0

            // Flight routes.
            let outbound: FlightTrajectory
            let inbound: FlightTrajectory

            // Reserved flight corridors.
            let outboundBoxes: [ReservationBox]
            let inboundBoxes: [ReservationBox]

            // Movement state.
            var returning = false
            var flying = false

            var distance = 0.0
            var nextDepartureTime = 0.0

            // Normal climb/descent pitch.
            var pitchDegrees: Double = 0

            // Stunt state.
            var stuntKind: StuntKind = .none
            var stuntElapsed: Double = 0

            var rollCompleted = false
            var pitchFlipCompleted = false

            var stuntRollDegrees: Double = 0
            var stuntPitchDegrees: Double = 0

            var stuntEntryPitch: Double = 0
            var stuntAttitudePitch: Double = 0
            var stuntHeadingDegrees: Double = 0

            // Select the route for the current direction.
            var trajectory: FlightTrajectory {
                returning ? inbound : outbound
            }

            // Select reservations for the current direction.
            var boxes: [ReservationBox] {
                returning ? inboundBoxes : outboundBoxes
            }

            mutating func resetStunts() {
                stuntKind = .none
                stuntElapsed = 0

                rollCompleted = false
                pitchFlipCompleted = false

                // Keep accumulated rotations.
                // Do not reset 360° to 0° between trips.
                stuntStartRoll = stuntRollDegrees
                stuntStartPitch = stuntPitchDegrees

                stuntEntryPitch = pitchDegrees
                stuntAttitudePitch = pitchDegrees
                stuntHeadingDegrees = 0
            }
        }

        private struct Position3D {
            let x: Double
            let y: Double
            let z: Double
        }

        private struct ReservationBox {
            let minX: Double
            let maxX: Double
            let minY: Double
            let maxY: Double
            let minZ: Double
            let maxZ: Double

            init(
                start: Position3D,
                end: Position3D,
                padding: Double
            ) {
                minX = min(start.x, end.x) - padding
                maxX = max(start.x, end.x) + padding

                minY = min(start.y, end.y) - padding
                maxY = max(start.y, end.y) + padding

                minZ = min(start.z, end.z) - padding
                maxZ = max(start.z, end.z) + padding
            }

            func overlaps(_ other: ReservationBox) -> Bool {
                minX <= other.maxX
                    && maxX >= other.minX
                    && minY <= other.maxY
                    && maxY >= other.minY
                    && minZ <= other.maxZ
                    && maxZ >= other.minZ
            }
        }

        private func updateVehicleStunts(by seconds: Double) {
            let entryDuration = 0.5
            let rotationDuration = 3.0

            // Longer recovery prevents a quick nose-angle correction.
            let exitDuration = 1.0

            let totalDuration =
                entryDuration
                + rotationDuration
                + exitDuration

            let triggerHeight = 40.0
            let minimumHeightDuringStunt = 20.0

            for index in fleet.indices {
                guard fleet[index].flying else {
                    continue
                }

                let trajectory = fleet[index].trajectory
                let distance = fleet[index].distance

                let position = trajectory.sample(
                    distance: distance
                )

                let before = trajectory.sample(
                    distance: max(distance - 1, 0)
                )

                let after = trajectory.sample(
                    distance: min(
                        distance + 1,
                        trajectory.totalDistance
                    )
                )

                let heightChange =
                    after.heightMeters - before.heightMeters

                let ascending = heightChange > 0.02
                let descending = heightChange < -0.02

                // MARK: Start a new maneuver

                if fleet[index].stuntKind == .none {
                    let remainingTime =
                        max(
                            trajectory.totalDistance - distance,
                            0
                        ) / max(speed, 0.1)

                    guard position.heightMeters >= triggerHeight,
                          remainingTime >= totalDuration + 1 else {
                        continue
                    }

                    let futureEnd = min(
                        distance + speed * totalDuration,
                        trajectory.totalDistance
                    )

                    let futureHeights = (0...16).map { sampleIndex in
                        let fraction = Double(sampleIndex) / 16.0

                        return trajectory.sample(
                            distance:
                                distance
                                + (futureEnd - distance) * fraction
                        ).heightMeters
                    }

                    guard futureHeights.allSatisfy({
                        $0 >= minimumHeightDuringStunt
                    }) else {
                        continue
                    }

                    let nextStunt: StuntKind

                    if ascending && !fleet[index].rollCompleted {
                        nextStunt = .roll

                    } else if descending
                                && !fleet[index].pitchFlipCompleted {
                        nextStunt = .pitchFlip

                    } else {
                        continue
                    }

                    fleet[index].stuntKind = nextStunt
                    fleet[index].stuntElapsed = 0

                    // Begin from the accumulated rotation values.
                    fleet[index].stuntStartRoll =
                        fleet[index].stuntRollDegrees

                    fleet[index].stuntStartPitch =
                        fleet[index].stuntPitchDegrees

                    fleet[index].stuntEntryPitch =
                        fleet[index].pitchDegrees

                    fleet[index].stuntAttitudePitch =
                        fleet[index].pitchDegrees

                    fleet[index].stuntHeadingDegrees = Self.bearing(
                        from: before.coordinate,
                        to: after.coordinate
                    )
                }

                // MARK: Animate the active maneuver

                fleet[index].stuntElapsed += seconds

                let time = fleet[index].stuntElapsed
                let kind = fleet[index].stuntKind

                let startRoll =
                    fleet[index].stuntStartRoll

                let startPitch =
                    fleet[index].stuntStartPitch

                if time < entryDuration {
                    // Smoothly enter the clean, level stunt attitude.
                    let progress = Self.stuntEase(
                        time / entryDuration
                    )

                    fleet[index].stuntAttitudePitch =
                        fleet[index].stuntEntryPitch
                        * (1 - progress)

                    fleet[index].stuntRollDegrees = startRoll
                    fleet[index].stuntPitchDegrees = startPitch

                } else if time < entryDuration + rotationDuration {
                    // Perform the full rotation with no changing
                    // normal climb/descent pitch mixed into it.
                    fleet[index].stuntAttitudePitch = 0

                    let progress = Self.stuntEase(
                        (time - entryDuration) / rotationDuration
                    )

                    switch kind {
                    case .roll:
                        fleet[index].stuntRollDegrees =
                            startRoll + 360 * progress

                        fleet[index].stuntPitchDegrees =
                            startPitch

                    case .pitchFlip:
                        fleet[index].stuntRollDegrees =
                            startRoll

                        fleet[index].stuntPitchDegrees =
                            startPitch - 360 * progress

                    case .none:
                        break
                    }

                } else {
                    // Keep the completed rotation—never wrap it to zero.
                    switch kind {
                    case .roll:
                        fleet[index].stuntRollDegrees =
                            startRoll + 360

                        fleet[index].stuntPitchDegrees =
                            startPitch

                    case .pitchFlip:
                        fleet[index].stuntRollDegrees =
                            startRoll

                        fleet[index].stuntPitchDegrees =
                            startPitch - 360

                    case .none:
                        break
                    }

                    // Blend directly into the current trajectory attitude.
                    // Uphill: positive nose-up pitch.
                    // Downhill: negative nose-down pitch.
                    let progress = Self.stuntEase(
                        (
                            time
                            - entryDuration
                            - rotationDuration
                        ) / exitDuration
                    )

                    fleet[index].stuntAttitudePitch =
                        fleet[index].pitchDegrees * progress

                    if time >= totalDuration {
                        switch kind {
                        case .roll:
                            fleet[index].rollCompleted = true

                        case .pitchFlip:
                            fleet[index].pitchFlipCompleted = true

                        case .none:
                            break
                        }

                        // Match the normal attitude exactly at handoff.
                        fleet[index].stuntAttitudePitch =
                            fleet[index].pitchDegrees

                        fleet[index].stuntElapsed = 0
                        fleet[index].stuntKind = .none
                    }
                }
            }
        }

        private static func stuntEase(_ value: Double) -> Double {
            let value = min(max(value, 0), 1)

            return value * value * (3 - 2 * value)
        }
        
        private func updateVehiclePitch(by seconds: Double) {
            let maximumPitch = 30.0
            let responseTime = 0.2

            let blend = 1 - exp(
                -seconds / responseTime
            )

            for index in fleet.indices {
                let agent = fleet[index]

                var targetPitch = 0.0

                if agent.flying {
                    let trajectory = agent.trajectory

                    let before = trajectory.sample(
                        distance: max(
                            agent.distance - 1,
                            0
                        )
                    )

                    let after = trajectory.sample(
                        distance: min(
                            agent.distance + 1,
                            trajectory.totalDistance
                        )
                    )

                    let horizontalDistance = Self.distance(
                        before.coordinate,
                        after.coordinate
                    )

                    let verticalDistance =
                        after.heightMeters - before.heightMeters

                    // Positive slope = climbing.
                    // Negative slope = descending.
                    let slopeDegrees = atan2(
                        verticalDistance,
                        horizontalDistance
                    ) * 180 / .pi

                    targetPitch = min(
                        max(slopeDegrees, -maximumPitch),
                        maximumPitch
                    )
                }

                fleet[index].pitchDegrees +=
                    (targetPitch - fleet[index].pitchDegrees)
                    * blend

                if abs(
                    fleet[index].pitchDegrees - targetPitch
                ) < 0.01 {
                    fleet[index].pitchDegrees = targetPitch
                }
            }
        }
        
        // MARK: Location
        func updateArea(
            around location: CLLocation,
            force: Bool = false
        ) {
            currentLocation = location

            // Keep this origin fixed for collision calculations.
            // Do not move it on every GPS update.
            if areaCenter == nil {
                areaCenter = location.coordinate
            }

            // A manual force refresh resets this demo population.
            if force {
                fleet.removeAll()
            }

            streamFleet(around: location)
            publishSnapshot()
        }
        
        private func spawnPositionIsClear(
            _ candidate: TaxiAgent
        ) -> Bool {
            guard let areaCenter else {
                return false
            }

            let spawnPoint = candidate.trajectory.sample(
                distance: 0
            )

            let spawnPosition = localPosition(
                spawnPoint,
                center: areaCenter
            )

            let spawnBox = ReservationBox(
                start: spawnPosition,
                end: spawnPosition,
                padding: envelopeRadius
            )

            for other in fleet {
                if other.flying {
                    // Do not spawn inside an airborne taxi's
                    // reserved route, including its landing area.
                    if other.boxes.contains(
                        where: { $0.overlaps(spawnBox) }
                    ) {
                        return false
                    }
                } else {
                    let otherPoint = other.trajectory.sample(
                        distance: 0
                    )

                    let otherPosition = localPosition(
                        otherPoint,
                        center: areaCenter
                    )

                    let otherBox = ReservationBox(
                        start: otherPosition,
                        end: otherPosition,
                        padding: envelopeRadius
                    )

                    if spawnBox.overlaps(otherBox) {
                        return false
                    }
                }
            }

            return true
        }
        
        private func makeSpawnCandidate(
            around userCoordinate: CLLocationCoordinate2D
        ) -> TaxiAgent? {
            guard let areaCenter else {
                return nil
            }

            // Spawn inside the active area rather than on one fixed ring.
            let spawnDistance = Double.random(
                in: 150...550
            )

            let spawnBearing = Double.random(
                in: 0..<360
            )

            let pickup = Self.offset(
                userCoordinate,
                meters: spawnDistance,
                bearingDegrees: spawnBearing
            )

            // A mixture of short curved trips and longer vertical trips.
            let tripDistance = Double.random(
                in: 70...350
            )

            let tripBearing = Double.random(
                in: 0..<360
            )

            let destination = Self.offset(
                pickup,
                meters: tripDistance,
                bearingDegrees: tripBearing
            )

            // Keep both endpoints within the current local area.
            let userLocation = CLLocation(
                latitude: userCoordinate.latitude,
                longitude: userCoordinate.longitude
            )

            let destinationLocation = CLLocation(
                latitude: destination.latitude,
                longitude: destination.longitude
            )

            guard userLocation.distance(
                from: destinationLocation
            ) <= activeRadius - 40 else {
                return nil
            }

            let altitudeLane = Int.random(in: 0..<7)

            let height =
                cruiseHeight + Double(altitudeLane) * 15

            let outbound = FlightTrajectoryBuilder.make(
                pickup: pickup,
                destination: destination,
                cruiseHeight: height,
                nearThresholdMeters: 150
            )

            let inbound = FlightTrajectoryBuilder.make(
                pickup: destination,
                destination: pickup,
                cruiseHeight: height,
                nearThresholdMeters: 150
            )

            return TaxiAgent(
                id: "taxi-\(UUID().uuidString)",
                outbound: outbound,
                inbound: inbound,
                outboundBoxes: reservationBoxes(
                    for: outbound,
                    center: areaCenter
                ),
                inboundBoxes: reservationBoxes(
                    for: inbound,
                    center: areaCenter
                ),
                nextDepartureTime:
                    clock + Double.random(in: 0...8)
            )
        }
        
        private func streamFleet(
            around location: CLLocation
        ) {
            let previousIDs = Set(
                fleet.map { $0.id }
            )

            // Remove cars based on their current world positions.
            // Their routes are never recentered around the user.
            fleet.removeAll { agent in
                let position = agent.trajectory.sample(
                    distance: agent.distance
                )

                let carLocation = CLLocation(
                    latitude: position.coordinate.latitude,
                    longitude: position.coordinate.longitude
                )

                return location.distance(
                    from: carLocation
                ) > activeRadius
            }

            // Try to fill vacant fleet slots.
            // A bounded number of attempts avoids an endless loop
            // if no safe spawn position is available.
            var attempts = 0
            let maximumAttempts = 40

            while fleet.count < fleetSize,
                  attempts < maximumAttempts {
                attempts += 1

                guard let agent = makeSpawnCandidate(
                    around: location.coordinate
                ) else {
                    continue
                }

                guard spawnPositionIsClear(agent) else {
                    continue
                }

                fleet.append(agent)
            }

            let updatedIDs = Set(
                fleet.map { $0.id }
            )

            // Route geometry changes only when fleet membership changes.
            if previousIDs != updatedIDs {
                rebuildTrajectoryGeometry()
            }
        }

        // MARK: Shared simulation clock

        func advance(by seconds: Double) {
            guard seconds.isFinite, seconds > 0 else {
                return
            }

            var remaining = min(seconds, 5)

            while remaining > 0.000001 {
                let step = min(remaining, 0.1)

                clock += step
                departureSignal = Self.signal(at: clock)

                // Keep your existing movement loop.
                for index in fleet.indices {
                    guard fleet[index].flying else {
                        continue
                    }

                    let routeLength =
                        fleet[index].trajectory.totalDistance

                    fleet[index].distance = min(
                        fleet[index].distance + speed * step,
                        routeLength
                    )

                    if fleet[index].distance >= routeLength {
                        fleet[index].flying = false
                        fleet[index].returning.toggle()
                        fleet[index].distance = 0

                        fleet[index].nextDepartureTime =
                            clock + groundDwell

                        // Allow one new stunt sequence on the return trip.
                        fleet[index].stuntElapsed = 0
                        fleet[index].resetStunts()
                    }

                }
                
                updateVehiclePitch(by: step)
                updateVehicleStunts(by: step)

                if departureSignal == .green {
                    admitDepartures()
                }

                // Add this:
                updateVehiclePitch(by: step)

                if departureSignal == .green {
                    admitDepartures()
                }

                remaining -= step
            }

            // Check spawning/despawning once per simulation second,
            // rather than on every animation update.
            if clock - lastFleetMaintenanceTime >= 1 {
                lastFleetMaintenanceTime = clock

                if let currentLocation {
                    streamFleet(around: currentLocation)
                }
            }

            // Update visible vehicle positions on every animation tick.
            publishSnapshot()
        }

        // MARK: Departure reservations

        private func admitDepartures() {
            var airborneCount =
                fleet.filter { $0.flying }.count

            // Oldest waiting taxis receive priority.
            let waitingIndices = fleet.indices
                .filter {
                    !fleet[$0].flying
                        && clock >= fleet[$0].nextDepartureTime
                }
                .sorted {
                    fleet[$0].nextDepartureTime
                        < fleet[$1].nextDepartureTime
                }

            for index in waitingIndices {
                guard airborneCount < maximumConcurrentFlights else {
                    break
                }

                guard departureIsClear(for: index) else {
                    continue
                }

                fleet[index].flying = true
                airborneCount += 1
            }
        }

        private func departureIsClear(
            for candidateIndex: Int
        ) -> Bool {
            guard let areaCenter else {
                return false
            }

            let candidateBoxes = fleet[candidateIndex].boxes

            for otherIndex in fleet.indices {
                guard otherIndex != candidateIndex else {
                    continue
                }

                let other = fleet[otherIndex]

                if other.flying {
                    // Reserve the whole active route.
                    // This is conservative: paths may be held even
                    // when a time-aware planner could allow both.
                    for candidate in candidateBoxes {
                        if other.boxes.contains(
                            where: { candidate.overlaps($0) }
                        ) {
                            return false
                        }
                    }
                } else {
                    // Also protect occupied ground pads.
                    let sample = other.trajectory.sample(
                        distance: 0
                    )

                    let position = localPosition(
                        sample,
                        center: areaCenter
                    )

                    let occupiedPad = ReservationBox(
                        start: position,
                        end: position,
                        padding: envelopeRadius
                    )

                    if candidateBoxes.contains(
                        where: { $0.overlaps(occupiedPad) }
                    ) {
                        return false
                    }
                }
            }

            return true
        }

        private func reservationBoxes(
            for trajectory: FlightTrajectory,
            center: CLLocationCoordinate2D
        ) -> [ReservationBox] {
            let points = trajectory.geographicPoints

            guard points.count >= 2 else {
                return []
            }

            return (1..<points.count).map { index in
                ReservationBox(
                    start: localPosition(
                        points[index - 1],
                        center: center
                    ),
                    end: localPosition(
                        points[index],
                        center: center
                    ),
                    padding: envelopeRadius
                )
            }
        }

        // MARK: Render snapshot

        private func publishSnapshot() {
            guard let currentLocation else {
                return
            }

            var updatedCars: [FlyingVehicle] = []
            var updatedPads: [TrafficPad] = []

            for agent in fleet {
                let trajectory = agent.trajectory

                let position = trajectory.sample(
                    distance: agent.distance
                )

                let before = trajectory.sample(
                    distance: max(agent.distance - 1, 0)
                )

                let after = trajectory.sample(
                    distance: min(
                        agent.distance + 1,
                        trajectory.totalDistance
                    )
                )

                let horizontalMovement = Self.distance(
                    before.coordinate,
                    after.coordinate
                )

                let heading: Double

                if horizontalMovement > 0.01 {
                    heading = Self.bearing(
                        from: before.coordinate,
                        to: after.coordinate
                    )
                } else {
                    heading = Self.bearing(
                        from: trajectory.sample(
                            distance: 0
                        ).coordinate,
                        to: trajectory.sample(
                            distance: trajectory.totalDistance
                        ).coordinate
                    )
                }

                let distanceFromUser = currentLocation.distance(
                    from: CLLocation(
                        latitude: position.coordinate.latitude,
                        longitude: position.coordinate.longitude
                    )
                )

                if distanceFromUser <= activeRadius {
                    let performingStunt =
                        agent.stuntKind != .none

                    updatedCars.append(
                        FlyingVehicle(
                            id: agent.id,
                            coordinate: position.coordinate,
                            heading: performingStunt
                                ? agent.stuntHeadingDegrees
                                : heading,
                            height: position.heightMeters,
                            pitchDegrees: performingStunt
                                ? agent.stuntAttitudePitch
                                : agent.pitchDegrees,
                            stuntRollDegrees: agent.stuntRollDegrees,
                            stuntPitchDegrees: agent.stuntPitchDegrees
                        )
                    )
                }

                let currentPad = trajectory.sample(
                    distance: 0
                ).coordinate

                updatedPads.append(
                    TrafficPad(
                        id: "\(agent.id)-departure",
                        coordinate: currentPad,
                        signal: agent.flying
                            ? .red
                            : departureSignal
                    )
                )

                updatedPads.append(
                    TrafficPad(
                        id: "\(agent.id)-arrival",
                        coordinate: trajectory.sample(
                            distance: trajectory.totalDistance
                        ).coordinate,
                        signal: .red
                    )
                )
            }

            cars = updatedCars
            pads = updatedPads

            let airborne =
                fleet.filter { $0.flying }.count

            status =
                "\(airborne) travelling • "
                + "\(fleet.count - airborne) waiting"
        }

        // MARK: Cached trajectory geometry

        private func rebuildTrajectoryGeometry() {
            var lines: [Feature] = []
            var columns: [Feature] = []

            // Return routes use the same corridor in reverse,
            // so draw each corridor only once.
            for agent in fleet {
                let points = agent.outbound.geographicPoints

                guard points.count >= 2 else {
                    continue
                }

                for index in 1..<points.count {
                    let start = points[index - 1]
                    let end = points[index]

                    let horizontalLength = Self.distance(
                        start.coordinate,
                        end.coordinate
                    )

                    if horizontalLength < 0.01 {
                        let bottom = min(
                            start.heightMeters,
                            end.heightMeters
                        )

                        let top = max(
                            start.heightMeters,
                            end.heightMeters
                        )

                        guard top - bottom > 0.01 else {
                            continue
                        }

                        var feature = Feature(
                            geometry: .polygon(
                                Self.square(
                                    center: start.coordinate,
                                    halfSize: 2.0
                                )
                            )
                        )

                        feature.properties = [
                            "bottom": .number(bottom),
                            "top": .number(top)
                        ]

                        columns.append(feature)
                    } else {
                        var feature = Feature(
                            geometry: .lineString(
                                LineString([
                                    start.coordinate,
                                    end.coordinate
                                ])
                            )
                        )

                        feature.properties = [
                            "startHeight": .number(
                                start.heightMeters
                            ),
                            "endHeight": .number(
                                end.heightMeters
                            )
                        ]

                        lines.append(feature)
                    }
                }
            }

            lineFeatures = FeatureCollection(
                features: lines
            )

            verticalFeatures = FeatureCollection(
                features: columns
            )
        }

        // MARK: Geographic helpers

        private func localPosition(
            _ point: FlightPoint,
            center: CLLocationCoordinate2D
        ) -> Position3D {
            let latitudeRadians =
                center.latitude * .pi / 180

            return Position3D(
                x:
                    (point.coordinate.longitude - center.longitude)
                    * 111_320 * cos(latitudeRadians),
                y:
                    (point.coordinate.latitude - center.latitude)
                    * 111_320,
                z: point.heightMeters
            )
        }

        private static func signal(
            at time: Double
        ) -> DemoSignal {
            let phase = time.truncatingRemainder(
                dividingBy: 50
            )

            if phase < 30 {
                return .green
            } else if phase < 35 {
                return .yellow
            } else {
                return .red
            }
        }

        private static func distance(
            _ first: CLLocationCoordinate2D,
            _ second: CLLocationCoordinate2D
        ) -> Double {
            CLLocation(
                latitude: first.latitude,
                longitude: first.longitude
            ).distance(
                from: CLLocation(
                    latitude: second.latitude,
                    longitude: second.longitude
                )
            )
        }

        private static func bearing(
            from start: CLLocationCoordinate2D,
            to end: CLLocationCoordinate2D
        ) -> Double {
            let latitude1 = start.latitude * .pi / 180
            let latitude2 = end.latitude * .pi / 180

            let deltaLongitude =
                (end.longitude - start.longitude) * .pi / 180

            let y = sin(deltaLongitude) * cos(latitude2)

            let x =
                cos(latitude1) * sin(latitude2)
                - sin(latitude1) * cos(latitude2)
                * cos(deltaLongitude)

            let degrees = atan2(y, x) * 180 / .pi

            return (degrees + 360)
                .truncatingRemainder(dividingBy: 360)
        }

        private static func offset(
            _ center: CLLocationCoordinate2D,
            meters: Double,
            bearingDegrees: Double
        ) -> CLLocationCoordinate2D {
            let bearing = bearingDegrees * .pi / 180
            let latitude = center.latitude * .pi / 180

            return CLLocationCoordinate2D(
                latitude:
                    center.latitude
                    + meters * cos(bearing) / 111_320,
                longitude:
                    center.longitude
                    + meters * sin(bearing)
                    / (111_320 * cos(latitude))
            )
        }

        private static func square(
            center: CLLocationCoordinate2D,
            halfSize: Double
        ) -> Polygon {
            let latitudeOffset = halfSize / 111_320

            let longitudeOffset =
                halfSize
                / (
                    111_320
                    * cos(center.latitude * .pi / 180)
                )

            let ring = [
                CLLocationCoordinate2D(
                    latitude: center.latitude - latitudeOffset,
                    longitude: center.longitude - longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude - latitudeOffset,
                    longitude: center.longitude + longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude + latitudeOffset,
                    longitude: center.longitude + longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude + latitudeOffset,
                    longitude: center.longitude - longitudeOffset
                ),
                CLLocationCoordinate2D(
                    latitude: center.latitude - latitudeOffset,
                    longitude: center.longitude - longitudeOffset
                )
            ]

            return Polygon([ring])
        }
    }
}
