import Foundation
import UIKit

// MARK: - Image Cache Manager
class ImageCache {
    static let shared = ImageCache()
    
    // 内存缓存 - 用于快速访问
    private let memoryCache = NSCache<NSString, UIImage>()
    
    // 缩略图缓存 - 专门用于缩略图
    private let thumbnailCache = NSCache<NSString, UIImage>()
    
    // 后台队列用于图片处理
    private let imageProcessingQueue = DispatchQueue(label: "com.photovault.imageprocessing", qos: .userInitiated)
    
    // 缩略图生成队列
    private let thumbnailQueue = DispatchQueue(label: "com.photovault.thumbnail", qos: .utility)
    
    private init() {
        // 设置内存缓存限制
        memoryCache.countLimit = 50 // 最多缓存50张原图
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100MB
        
        // 缩略图缓存可以更大
        thumbnailCache.countLimit = 200 // 最多缓存200张缩略图
        thumbnailCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
        // 监听内存警告
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearCacheOnMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func clearCacheOnMemoryWarning() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        print("ImageCache: Cleared caches due to memory warning")
    }
    
    // MARK: - 原图缓存
    func getImage(for fileName: String) -> UIImage? {
        let key = NSString(string: fileName)
        
        // 先检查内存缓存
        if let cachedImage = memoryCache.object(forKey: key) {
            return cachedImage
        }
        
        // 从磁盘加载
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let imagePath = documentsPath.appendingPathComponent(fileName)
        guard let imageData = try? Data(contentsOf: imagePath),
              let image = UIImage(data: imageData) else {
            return nil
        }
        
        // 缓存到内存
        let cost = Int(image.size.width * image.size.height * 4) // 估算内存占用
        memoryCache.setObject(image, forKey: key, cost: cost)
        
        return image
    }
    
    // MARK: - 缩略图缓存
    func getThumbnail(for fileName: String, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let thumbnailKey = NSString(string: "\(fileName)_\(Int(size.width))x\(Int(size.height))")
        
        // 先检查缩略图缓存
        if let cachedThumbnail = thumbnailCache.object(forKey: thumbnailKey) {
            DispatchQueue.main.async {
                completion(cachedThumbnail)
            }
            return
        }
        
        // 后台生成缩略图
        thumbnailQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 先尝试从原图缓存获取
            let originalImage = self.getImage(for: fileName)
            guard let image = originalImage else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            // 生成缩略图
            let thumbnail = self.generateThumbnail(from: image, targetSize: size)
            
            // 缓存缩略图
            if let thumbnail = thumbnail {
                let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                self.thumbnailCache.setObject(thumbnail, forKey: thumbnailKey, cost: cost)
            }
            
            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }
    
    // MARK: - 异步获取原图
    func getImageAsync(for fileName: String, completion: @escaping (UIImage?) -> Void) {
        // 先检查缓存
        if let cachedImage = getImage(for: fileName) {
            completion(cachedImage)
            return
        }
        
        // 后台加载
        imageProcessingQueue.async { [weak self] in
            let image = self?.getImage(for: fileName)
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
    
    // MARK: - 缩略图生成
    private func generateThumbnail(from image: UIImage, targetSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        
        return renderer.image { context in
            // 计算缩放比例，保持宽高比
            let aspectRatio = image.size.width / image.size.height
            let targetAspectRatio = targetSize.width / targetSize.height
            
            var drawRect: CGRect
            
            if aspectRatio > targetAspectRatio {
                // 图片更宽，以高度为准
                let scaledWidth = targetSize.height * aspectRatio
                drawRect = CGRect(
                    x: (targetSize.width - scaledWidth) / 2,
                    y: 0,
                    width: scaledWidth,
                    height: targetSize.height
                )
            } else {
                // 图片更高，以宽度为准
                let scaledHeight = targetSize.width / aspectRatio
                drawRect = CGRect(
                    x: 0,
                    y: (targetSize.height - scaledHeight) / 2,
                    width: targetSize.width,
                    height: scaledHeight
                )
            }
            
            image.draw(in: drawRect)
        }
    }
    
    // MARK: - 预加载缩略图
    func preloadThumbnails(for fileNames: [String], size: CGSize) {
        for fileName in fileNames {
            getThumbnail(for: fileName, size: size) { _ in
                // 预加载，不需要处理结果
            }
        }
    }
    
    // MARK: - 缓存管理
    func clearCache() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
    }
    
    func removeCachedImage(for fileName: String) {
        let key = NSString(string: fileName)
        memoryCache.removeObject(forKey: key)
        
        // 移除相关的缩略图 - 由于NSCache没有allKeys，我们预先定义常用尺寸进行清理
        let commonThumbnailSizes = [
            CGSize(width: 44, height: 44),
            CGSize(width: 88, height: 88),  // 2x
            CGSize(width: 120, height: 120),
            CGSize(width: 240, height: 240), // 2x
            CGSize(width: 300, height: 300),
            CGSize(width: 600, height: 600)  // 2x
        ]
        
        for size in commonThumbnailSizes {
            let thumbnailKey = NSString(string: "\(fileName)_\(Int(size.width))x\(Int(size.height))")
            thumbnailCache.removeObject(forKey: thumbnailKey)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
