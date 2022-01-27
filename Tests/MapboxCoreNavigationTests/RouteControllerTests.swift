import XCTest
import Turf
import MapboxDirections
import CoreLocation
@testable import MapboxCoreNavigation
import TestHelper
import MapboxNavigationNative

class RouteControllerTests: TestCase {
    var replayManager: ReplayLocationManager?

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        replayManager = nil
        MapboxRoutingProvider.__testRoutesStub = nil
        super.tearDown()
    }
    
    func testRouteSnappingOvershooting() {
        let options = NavigationMatchOptions(coordinates: [
            .init(latitude: 59.337928, longitude: 18.076841),
            .init(latitude: 59.33865, longitude: 18.074935),
        ])
        let routeResponse = Fixture.routeResponseFromMatches(at: "sthlm-double-back", options: options)
        let locations = Array<CLLocation>.locations(from: "sthlm-double-back-replay").shiftedToPresent()
        let locationManager = ReplayLocationManager(locations: locations)
        replayManager = locationManager
        let equivalentRouteOptions = NavigationRouteOptions(navigationMatchOptions: options)
        let routeController = RouteController(alongRouteAtIndex: 0, in: routeResponse, options: equivalentRouteOptions, routingProvider: MapboxRoutingProvider(.offline), dataSource: self)
        locationManager.delegate = routeController
        let routerDelegateSpy = RouterDelegateSpy()
        routeController.delegate = routerDelegateSpy
        routeController.reroutesProactively = false

        var actualCoordinates = [CLLocationCoordinate2D]()
        routerDelegateSpy.onShouldDiscard = { location in
            actualCoordinates.append(location.coordinate)
            return false
        }
        let expectedTestCoordinatesCount = locationManager.locations.count
        expectation(description: "All coordinates processed") {
            actualCoordinates.count == expectedTestCoordinatesCount
        }

        let replayFinished = expectation(description: "Replay Finished")
        locationManager.replayCompletionHandler = { _ in
            replayFinished.fulfill()
            return false
        }

        let speedMultiplier: TimeInterval = 100
        locationManager.speedMultiplier = speedMultiplier
        locationManager.startUpdatingLocation()

        waitForExpectations(timeout: locationManager.expectedReplayTime, handler: nil)

        let expectedCoordinates = locations.map(\.coordinate)
        XCTAssertEqual(expectedCoordinates, actualCoordinates)
    }
}

extension RouteControllerTests: RouterDataSource {
    var location: CLLocation? {
        return replayManager?.location
    }
    
    var locationManagerType: NavigationLocationManager.Type {
        return NavigationLocationManager.self
    }
}
