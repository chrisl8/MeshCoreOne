import CoreLocation
import OSLog

/// Watches for movement while a DM is waiting out a retry backoff.
///
/// A phone that is driving is probably somewhere new long before the backoff ends,
/// so once it has moved `threshold` meters from where the wait began, `onMoved`
/// fires and the caller retries immediately. Location updates run only during the
/// wait, and the monitor asks for "Always" access the first time it is needed so it
/// can keep working with the app in the background.
@MainActor
final class RetryMovementMonitor: NSObject, CLLocationManagerDelegate {
  /// Meters moved from the starting fix before a retry is triggered.
  static let threshold: CLLocationDistance = 200

  private let logger = Logger(subsystem: "com.mc1", category: "RetryMovementMonitor")
  private let locationManager = CLLocationManager()
  private var anchor: CLLocation?
  private var isMonitoring = false
  private var lastTriggerAt: Date?

  /// Minimum time between movement-triggered retries, so GPS jitter or a fast
  /// drive cannot burn through attempts back to back.
  private static let cooldown: TimeInterval = 120

  var onMoved: (() -> Void)?

  override init() {
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    locationManager.distanceFilter = 50
    locationManager.pausesLocationUpdatesAutomatically = false
  }

  func start() {
    guard !isMonitoring else { return }
    switch locationManager.authorizationStatus {
    case .notDetermined:
      // Updates begin once the user answers; see locationManagerDidChangeAuthorization.
      locationManager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse:
      locationManager.requestAlwaysAuthorization()
    case .denied, .restricted:
      logger.info("Location unavailable; time-based retry only")
      return
    default:
      break
    }
    isMonitoring = true
    anchor = nil
    // Setting this without the background mode declared aborts the app.
    if Self.declaresLocationBackgroundMode {
      locationManager.allowsBackgroundLocationUpdates = true
      locationManager.showsBackgroundLocationIndicator = true
    }
    locationManager.startUpdatingLocation()
    logger.info("Movement monitoring started")
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    anchor = nil
    locationManager.stopUpdatingLocation()
    if Self.declaresLocationBackgroundMode { locationManager.allowsBackgroundLocationUpdates = false }
    logger.info("Movement monitoring stopped")
  }

  private static var declaresLocationBackgroundMode: Bool {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
    return modes?.contains("location") == true
  }

  /// Location was turned off or revoked mid-wait: stop quietly; the timer still runs.
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    guard status == .denied || status == .restricted else { return }
    Task { @MainActor in self.stop() }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last else { return }
    Task { @MainActor in self.handle(latest) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Failures (no fix, denied) just mean no movement trigger; never retry on them.
    Task { @MainActor in self.logger.warning("Location error: \(error.localizedDescription)") }
  }

  private func handle(_ location: CLLocation) {
    // Only trust fresh, reasonably precise fixes; the first fix after starting is
    // often a stale cached one that would make a false "moved" against the next.
    guard isMonitoring, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
          abs(location.timestamp.timeIntervalSinceNow) < 15 else { return }
    guard let anchor else {
      self.anchor = location
      return
    }
    // Ignore fixes too imprecise to tell a real move from drift.
    let slack = max(Self.threshold, location.horizontalAccuracy)
    guard location.distance(from: anchor) >= slack else { return }
    if let lastTriggerAt, Date().timeIntervalSince(lastTriggerAt) < Self.cooldown { return }
    lastTriggerAt = Date()
    logger.info("Moved \(Int(location.distance(from: anchor))) m; triggering retry")
    self.anchor = location
    onMoved?()
  }
}
