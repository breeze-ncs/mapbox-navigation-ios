import UIKit
import MapboxMaps
import MapboxCoreNavigation
import MapboxDirections

class SpriteRepository {
    // Caching the Sprite and single shield icon images.
    var spriteCache = ImageCache()
    // Caching the single legacy shield icon images.
    var legacyCache = ImageCache()
    // Caching the metadata info for Sprite.
    var infoCache =  SpriteInfoCache()
    var styleURI: StyleURI = .navigationDay
    var baseURL: URL = URL(string: "https://api.mapbox.com/styles/v1")!
    fileprivate(set) var imageDownloader: ReentrantImageDownloader = ImageDownloader()
    
    var sessionConfiguration: URLSessionConfiguration = URLSessionConfiguration.default {
        didSet {
            imageDownloader = ImageDownloader(sessionConfiguration: sessionConfiguration)
        }
    }
    
    func updateStyle(styleURI: StyleURI,
                     representation: VisualInstruction.Component.ImageRepresentation? = nil,
                     completion: @escaping CompletionHandler) {
        guard styleURI != self.styleURI else {
            completion()
            return
        }
        
        // Reset the default styleURI when style changes without valid ImageRepresentation.
        guard let baseURL = representation?.shield?.baseURL else {
            self.styleURI = styleURI
            completion()
            return
        }
        
        // Reset Sprite cache when style changes with valid baseURL.
        updateSprite(styleURI: styleURI, baseURL: baseURL, completion: completion)
    }
    
    func updateStyle(styleURI: StyleURI,
                     instructionBanner: VisualInstructionBanner? = nil,
                     completion: @escaping CompletionHandler) {
        guard styleURI != self.styleURI else {
            completion()
            return
        }
        
        // Reset the default styleURI when style changes without valid VisualInstructionBanner.
        guard let instructionBanner = instructionBanner else {
            self.styleURI = styleURI
            completion()
            return
        }
        
        // Reset Sprite cache when style changes with valid baseURL.
        let baseURL = baseURLFor(instructionBanner: instructionBanner)
        updateSprite(styleURI: styleURI, baseURL: baseURL, completion: completion)
    }

    func updateRepresentation(representation: VisualInstruction.Component.ImageRepresentation? = nil, completion: @escaping CompletionHandler) {
        let dispatchGroup = DispatchGroup()

        // Reset Sprite cache when the baseURL changes or no valid Sprite image cached.
        let baseURL = representation?.shield?.baseURL ?? self.baseURL
        if needUpdateSprite(for: baseURL) {
            dispatchGroup.enter()
            updateSprite(styleURI: self.styleURI, baseURL: baseURL) {
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.enter()
        updateLegacy(representation: representation) {
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) {
            completion()
        }
    }
    
    func updateInstructionBanner(instructionBanner: VisualInstructionBanner, completion: @escaping CompletionHandler) {
        let baseURL = baseURLFor(instructionBanner: instructionBanner)
        guard needUpdateSprite(for: baseURL) else {
            completion()
            return
        }
        updateSprite(styleURI: self.styleURI, baseURL: baseURL, completion: completion)
    }
    
    func updateSprite(styleURI: StyleURI, baseURL: URL, completion: @escaping CompletionHandler) {
        spriteCache.clearMemory()
        infoCache.clearMemory()
        
        // Update the styleURI and baseURL just after the Sprite memory reset. When the connection is poor, the next round of style update
        // or the representation update could use the correct ones.
        self.styleURI = styleURI
        self.baseURL = baseURL
        
        guard let styleID = styleURI.rawValue.components(separatedBy: "styles")[safe: 1],
              let infoRequestURL = spriteURL(isImage: false, baseURL: baseURL, styleID: styleID),
              let spriteRequestURL = spriteURL(isImage: true, baseURL: baseURL, styleID: styleID) else {
                  completion()
                  return
              }
        
        let spriteKey = "\(styleID)-\(baseURL.absoluteString)"
        let dispatchGroup = DispatchGroup()
        
        dispatchGroup.enter()
        downloadInfo(infoRequestURL, spriteKey: spriteKey) { (_) in
            dispatchGroup.leave()
        }
        
        dispatchGroup.enter()
        downloadSprite(spriteRequestURL, spriteKey: spriteKey) { (_) in
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) {
            completion()
        }
    }
    
    func updateLegacy(representation: VisualInstruction.Component.ImageRepresentation? = nil, completion: @escaping CompletionHandler) {
        guard let cacheKey = representation?.legacyCacheKey else {
            completion()
            return
        }
        
        if let _ = legacyCache.image(forKey: cacheKey) {
            completion()
        } else {
            downloadLegacyShield(representation: representation) { (_) in
                completion()
            }
        }
    }
    
    func spriteURL(isImage: Bool, baseURL: URL, styleID: String) -> URL? {
        guard var urlComponent = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let accessToken = NavigationSettings.shared.directions.credentials.accessToken else { return nil }
        
        let requestType = isImage ? "/sprite@\(Int(VisualInstruction.Component.scale))x.png" : "/sprite@\(Int(VisualInstruction.Component.scale))x"
        urlComponent.path += styleID
        urlComponent.path += requestType
        urlComponent.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        return urlComponent.url
    }
    
    func needUpdateSprite(for baseURL: URL) -> Bool {
        return baseURL != self.baseURL || getSpriteImage() == nil
    }
    
    func baseURLFor(instructionBanner: VisualInstructionBanner) -> URL {
        let components = instructionBanner.primaryInstruction.components
        let baseURLs = components.compactMap { (component) -> URL? in
            if case let VisualInstruction.Component.image(image: representation, alternativeText: _) = component {
                return representation.shield?.baseURL
            } else {
                return nil
            }
        }
        return baseURLs.first ?? self.baseURL
    }
    
    func downloadInfo(_ infoURL: URL, spriteKey: String, completion: @escaping (Data?) -> Void) {
        let _ = imageDownloader.downloadImage(with: infoURL, completion: { [weak self] (_, data, error)  in
            guard let strongSelf = self, let data = data else {
                completion(nil)
                return
            }

            guard strongSelf.infoCache.store(data, spriteKey: spriteKey) else {
                completion(nil)
                return
            }
            
            completion(data)
        })
    }
    
    func downloadSprite(_ spriteURL: URL, spriteKey: String, completion: @escaping (UIImage?) -> Void) {
        let _ = imageDownloader.downloadImage(with: spriteURL, completion: { [weak self] (image, data, error) in
            guard let strongSelf = self, let image = image else {
                completion(nil)
                return
            }

            strongSelf.spriteCache.store(image, forKey: spriteKey, toDisk: false, completion: {
                completion(image)
            })
        })
    }
    
    func downloadLegacyShield(representation: VisualInstruction.Component.ImageRepresentation? = nil, completion: @escaping (UIImage?) -> Void) {
        guard let legacyURL = representation?.imageURL(scale: VisualInstruction.Component.scale, format: .png),
              let cacheKey = representation?.legacyCacheKey else {
                  completion(nil)
                  return
              }
        
        let _ = imageDownloader.downloadImage(with: legacyURL, completion: { [weak self] (image, data, error) in
            guard let strongSelf = self, let image = image else {
                completion(nil)
                return
            }

            strongSelf.legacyCache.store(image, forKey: cacheKey, toDisk: false, completion: {
                completion(image)
            })
        })
    }
    
    func getShieldIcon(shield: VisualInstruction.Component.ShieldRepresentation?) -> UIImage? {
        guard let shield = shield else { return nil }
        // Use the styleURI and baseURL of current repository for spriteKey.
        guard let styleID = styleURI.rawValue.components(separatedBy: "styles")[safe: 1] else { return nil }
        let spriteKey = "\(styleID)-\(shield.baseURL.absoluteString)"

        let iconLeght = max(shield.text.count, 2)
        let shieldKey = shield.name + "-\(iconLeght)" + "-\(spriteKey)"
        
        // Retrieve the single shield icon if it has been cached.
        if let shieldIcon = spriteCache.image(forKey: shieldKey) {
            return shieldIcon
        }
        
        guard let spriteImage = spriteCache.image(forKey: spriteKey),
              let spriteInfo = infoCache.spriteInfo(forKey: shieldKey) else { return nil }
        
        let shieldRect = CGRect(x: spriteInfo.x, y: spriteInfo.y, width: spriteInfo.width, height: spriteInfo.height)
        if let croppedCGIImage = spriteImage.cgImage?.cropping(to: shieldRect) {
            
            // Cache the single shield icon if it hasn't been stored.
            let shieldIcon = UIImage(cgImage: croppedCGIImage)
            spriteCache.store(shieldIcon, forKey: shieldKey, toDisk: false, completion: nil)
            
            return UIImage(cgImage: croppedCGIImage)
        }
        
        return nil
    }
    
    func getLegacyShield(with cacheKey: String?) -> UIImage? {
        return legacyCache.image(forKey: cacheKey)
    }
    
    func getSpriteImage() -> UIImage? {
        // Use the styleURI and baseURL of current repository to retrieve Sprite image.
        guard let styleID = styleURI.rawValue.components(separatedBy: "styles")[safe: 1] else { return nil }
        let spriteKey = "\(styleID)-\(baseURL.absoluteString)"
        return spriteCache.image(forKey: spriteKey)
    }
    
    func resetCache() {
        spriteCache.clearMemory()
        infoCache.clearMemory()
        legacyCache.clearMemory()
    }

}
