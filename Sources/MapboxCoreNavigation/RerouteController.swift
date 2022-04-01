import Foundation
import MapboxDirections
@_implementationOnly import MapboxNavigationNative_Private

/**
 Adapter for `MapboxNavigationNative.RerouteControllerInterface` usage inside `Navigator`.
 
 This class handles correct setup for custom or default`RerouteControllerInterface`, monitoring native reroute events and configuring the process.
 */
class RerouteController {
    
    // MARK: Configuration
    
    static let DefaultManeuverAvoidanceRadius: TimeInterval = 8.0
    
    var reroutesProactively: Bool = true {
        didSet {
            if !reroutesProactively {
                reroutingRequest?.cancel()
            }
        }
    }
    
    var initialManeuverAvoidanceRadius: TimeInterval {
        get {
            config.avoidManeuverSeconds?.doubleValue ?? Self.DefaultManeuverAvoidanceRadius
        }
        set {
            config.avoidManeuverSeconds = NSNumber(value: newValue)
        }
    }
    
    var customRoutingProvider: RoutingProvider? = nil {
        didSet {
            self.navigator?.setRerouteControllerForController(
                customRoutingProvider.map { _ in self } ?? defaultRerouteController
            )
        }
    }
    
    private var config: NavigatorConfig
    
    // MARK: Reporting Data
    
    weak var delegate: RerouteControllerDelegate?
    
    func userIsOnRoute() -> Bool {
        return !rerouteDetector.isReroute()
    }
    
    func forceReroute() {
        rerouteDetector.forceReroute()
    }
    
    // MARK: Internal State Management
    
    private let defaultRerouteController: RerouteControllerInterface
    private let rerouteDetector: RerouteDetectorInterface
    
    private var reroutingRequest: NavigationProviderRequest?
    private var recentRouteResponse: (response: RouteResponse, options: RouteOptions)?
    private var isCancelled = false
    
    private weak var navigator: MapboxNavigationNative.Navigator?
    
    func resetToDefaultSettings() {
        reroutesProactively = true
        isCancelled = false
        config.avoidManeuverSeconds = NSNumber(value: Self.DefaultManeuverAvoidanceRadius)
        customRoutingProvider = nil
    }
    
    required init(_ navigator: MapboxNavigationNative.Navigator, config: NavigatorConfig) {
        self.navigator = navigator
        self.config = config
        self.defaultRerouteController = navigator.getRerouteController()
        self.rerouteDetector = navigator.getRerouteDetector()
        self.navigator?.addRerouteObserver(for: self)
    }
    
    deinit {
        self.navigator?.removeRerouteObserver(for: self)
        self.navigator?.setRerouteControllerForController(defaultRerouteController)
    }
}

extension RerouteController: RerouteObserver {
    
    private func decode(routeRequest: String) -> (routeOptions: RouteOptions, credentials: Credentials)? {
        guard let requestURL = URL(string: routeRequest),
              let routeOptions = RouteOptions(url: requestURL) else {
                  return nil
        }
        return (routeOptions, Credentials(requestURL: requestURL))
    }
    
    private func decode(routeResponse: String,
                        routeOptions: RouteOptions,
                        credentials: Credentials) -> RouteResponse? {
        guard let data = routeResponse.data(using: .utf8) else {
            return nil
        }
        
        let decoder = JSONDecoder()
        decoder.userInfo[.options] = routeOptions
        decoder.userInfo[.credentials] = credentials
        
        return try? decoder.decode(RouteResponse.self,
                                   from: data)
    }
    
    func onSwitchToAlternative(forRoute route: RouteInterface) {
        // to be filled with Continuous Alternatives implementation
    }
    
    func onRerouteDetected(forRouteRequest routeRequest: String) {
        isCancelled = false
        recentRouteResponse = nil
        guard reroutesProactively else { return }
        delegate?.rerouteControllerDidDetectReroute(self)
    }
    
    func onRerouteReceived(forRouteResponse routeResponse: String, routeRequest: String, origin: RouterOrigin) {
        guard reroutesProactively else { return }
        
        guard let decodedRequest = decode(routeRequest: routeRequest) else {
            delegate?.rerouteControllerDidFailToReroute(self, with: DirectionsError.invalidResponse(nil))
            return
        }
        
        if let recentRouteResponse = recentRouteResponse,
           decodedRequest.routeOptions == recentRouteResponse.options {
            delegate?.rerouteControllerDidRecieveReroute(self,
                                                         response: recentRouteResponse.response,
                                                         options: recentRouteResponse.options)
        } else {
            guard let decodedResponse = decode(routeResponse: routeResponse,
                                               routeOptions: decodedRequest.routeOptions,
                                               credentials: decodedRequest.credentials) else {
                delegate?.rerouteControllerDidFailToReroute(self, with: DirectionsError.invalidResponse(nil))
                return
            }
            
            delegate?.rerouteControllerDidRecieveReroute(self,
                                                         response: decodedResponse,
                                                         options: decodedRequest.routeOptions)
        }
    }
    
    func onRerouteCancelled() {
        recentRouteResponse = nil
        guard reroutesProactively else { return }
        
        delegate?.rerouteControllerDidCancelReroute(self)
    }
    
    func onRerouteFailed(forError error: RerouteError) {
        recentRouteResponse = nil
        guard reroutesProactively else { return }
        
        delegate?.rerouteControllerDidFailToReroute(self,
                                                    with: DirectionsError.unknown(response: nil,
                                                                                  underlying: ReroutingError(error),
                                                                                  code: nil,
                                                                                  message: error.message))
    }
}

extension RerouteController: RerouteControllerInterface {
    func reroute(forUrl url: String, callback: @escaping RerouteCallback) {
        guard reroutesProactively && !isCancelled else {
            callback(.init(error: RerouteError(message: "Cancelled by user.",
                                               type: .cancelled)))
            return
        }
        
        guard let customRoutingProvider = customRoutingProvider else {
            callback(.init(error: RerouteError(message: "Custom rerouting triggered with no proper rerouting provider.",
                                               type: .routerError)))
            return
        }
        
        guard let routeOptions = RouteOptions(url: URL(string: url)!) else {
            callback(.init(error: RerouteError(message: "Unable to decode route request for rerouting.",
                                               type: .routerError)))
            return
        }
        
        reroutingRequest = customRoutingProvider.calculateRoutes(options: routeOptions) { session, result in
            switch result {
            case .failure(let error):
                callback(.init(error: RerouteError(message: error.localizedDescription,
                                                   type: .routerError)))
            case .success(let routeResponse):
                if let responseString = routeResponse.identifier {
                    self.recentRouteResponse = (routeResponse, routeOptions)
                    callback(.init(value: RerouteInfo(routeResponse: responseString,
                                                                                    routeRequest: url,
                                                                                    origin: .onboard)))
                } else {
                    callback(.init(value: RerouteError(message: "Failed to process `routeResponse`.",
                                                                                      type: .routerError)))
                }
            }
        }
    }
    
    func cancel() {
        isCancelled = true
        defaultRerouteController.cancel()
        reroutingRequest?.cancel()
    }
}
