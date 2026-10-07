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
      locationManager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse:
      locationManager.requestAlwaysAuthorization()
    case .denied, .restricted:
      logger.info("Location denied; movement retry unavailable")
      return
    default:
      break
    }
    isMonitoring = true
    anchor = nil
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.showsBackgroundLocationIndicator = true
    locationManager.startUpdatingLocation()
    logger.info("Movement monitoring started")
  }

  func stop() {
    guard isMonitoring else { return }
    isMonitoring = false
    anchor = nil
    locationManager.stopUpdatingLocation()
    locationManager.allowsBackgroundLocationUpdates = false
    logger.info("Movement monitoring stopped")
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last else { return }
    Task { @MainActor in self.handle(latest) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in self.logger.warning("Location error: \(error.localizedDescription)") }
  }

  private func handle(_ location: CLLocation) {
    guard isMonitoring, location.horizontalAccuracy >= 0 else { return }
    guard let anchor else {
      self.anchor = location
      return
    }
    // Ignore fixes too imprecise to tell a real move from drift.
    let slack = max(Self.threshold, location.horizontalAccuracy)
    guard location.distance(from: anchor) >= slack else { return }
    logger.info("Moved \(Int(location.distance(from: anchor))) m; triggering retry")
    self.anchor = location
    onMoved?()
  }
}
