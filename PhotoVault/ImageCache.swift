import Foundation
import UIKit

// MARK: - Enhanced Image Cache Manager with Optional Metal GPU Acceleration
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
    
    // 可选的Metal处理器
    private let metalProcessor: MetalImageProcessor?
    
    // 性能统计
    private var metalSuccessCount = 0
    private var metalFailureCount = 0
    private var totalProcessingTime: Double = 0
    private var metalProcessingTime: Double = 0
    
    private init() {
        // 设置内存缓存限制
        memoryCache.countLimit = 50 // 最多缓存50张原图
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100MB
        
        // 缩略图缓存可以更大
        thumbnailCache.countLimit = 200 // 最多缓存200张缩略图
        thumbnailCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
        // 尝试初始化Metal处理器（可选）
        self.metalProcessor = MetalImageProcessor.shared
        
        if let metalProcessor = metalProcessor {
            print("ImageCache: Metal GPU acceleration available - Device: \(metalProcessor.deviceName)")
        } else {
            print("ImageCache: Using CPU-only processing")
        }
        
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
    
    // MARK: - 原图缓存 (保持原有接口完全不变)
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
    
    // MARK: - Enhanced 缩略图缓存 with Optional Metal Acceleration
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
            
            let startTime = CFAbsoluteTimeGetCurrent()
            var thumbnail: UIImage?
            
            // 尝试使用Metal加速（如果可用）
            if let metalProcessor = self.metalProcessor {
                thumbnail = metalProcessor.generateThumbnailIfPossible(from: image, targetSize: size)
                
                if thumbnail != nil {
                    self.metalSuccessCount += 1
                    let metalTime = CFAbsoluteTimeGetCurrent() - startTime
                    self.metalProcessingTime += metalTime
                } else {
                    self.metalFailureCount += 1
                }
            }
            
            // 如果Metal失败或不可用，使用原有CPU方法
            if thumbnail == nil {
                thumbnail = self.generateThumbnailCPU(from: image, targetSize: size)
            }
            
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            self.totalProcessingTime += totalTime
            
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
    
    // MARK: - 异步获取原图 (保持原有接口完全不变)
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
    
    // MARK: - AspectFill模式的CPU缩略图生成 (与Metal版本一致)
    private func generateThumbnailCPU(from image: UIImage, targetSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        
        return renderer.image { context in
            // 计算宽高比
            let imageSize = image.size
            let targetAspectRatio = targetSize.width / targetSize.height
            let imageAspectRatio = imageSize.width / imageSize.height
            
            // AspectFill模式：选择较大的缩放比例，确保填满整个目标区域
            let scaleX = targetSize.width / imageSize.width
            let scaleY = targetSize.height / imageSize.height
            let scale = max(scaleX, scaleY)  // 选择较大的缩放比例
            
            // 计算缩放后的图片尺寸
            let scaledSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            
            // 计算绘制位置（居中裁剪）
            let drawRect = CGRect(
                x: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )
            
            // 绘制图片（会被自动裁剪到targetSize范围内）
            image.draw(in: drawRect)
        }
    }
    
    // MARK: - 预加载缩略图 (保持原有接口，增加可选Metal加速)
    func preloadThumbnails(for fileNames: [String], size: CGSize) {
        for fileName in fileNames {
            getThumbnail(for: fileName, size: size) { _ in
                // 预加载，不需要处理结果
            }
        }
    }
    
    // MARK: - 缓存管理 (保持原有接口完全不变)
    func clearCache() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        
        // 重置性能统计
        metalSuccessCount = 0
        metalFailureCount = 0
        totalProcessingTime = 0
        metalProcessingTime = 0
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
    
    // MARK: - 性能监控 (新增)
    func getPerformanceStats() -> [String: Any] {
        let totalRequests = metalSuccessCount + metalFailureCount
        let metalSuccessRate = totalRequests > 0 ? Double(metalSuccessCount) / Double(totalRequests) : 0
        let avgMetalTime = metalSuccessCount > 0 ? metalProcessingTime / Double(metalSuccessCount) : 0
        let avgTotalTime = (metalSuccessCount + metalFailureCount) > 0 ? totalProcessingTime / Double(metalSuccessCount + metalFailureCount) : 0
        
        return [
            "metal_supported": MetalImageProcessor.isSupported,
            "metal_success_count": metalSuccessCount,
            "metal_failure_count": metalFailureCount,
            "metal_success_rate": metalSuccessRate,
            "avg_metal_time_ms": avgMetalTime * 1000,
            "avg_total_time_ms": avgTotalTime * 1000,
            "device_name": metalProcessor?.deviceName ?? "CPU Only"
        ]
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
