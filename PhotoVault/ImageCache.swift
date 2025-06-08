import Foundation
import UIKit

// MARK: - Enhanced Image Cache with Seamless Loading
class EnhancedImageCache {
    static let shared = EnhancedImageCache()
    
    // 内存缓存 - 用于快速访问原图
    private let memoryCache = NSCache<NSString, UIImage>()
    
    // 缩略图缓存 - 专门用于缩略图
    private let thumbnailCache = NSCache<NSString, UIImage>()
    
    // 预加载队列 - 高优先级用于可见内容
    private let preloadQueue = DispatchQueue(label: "com.photovault.preload", qos: .userInitiated)
    
    // 后台预加载队列 - 低优先级用于预测性加载
    private let backgroundPreloadQueue = DispatchQueue(label: "com.photovault.background", qos: .utility)
    
    // 可选的Metal处理器
    private let metalProcessor: MetalImageProcessor?
    
    // 预加载状态跟踪
    private var preloadingFiles: Set<String> = []
    private let preloadLock = NSLock()
    
    // 性能统计
    private var cacheHitCount = 0
    private var cacheMissCount = 0
    
    private init() {
        // 设置内存缓存限制
        memoryCache.countLimit = 100 // 增加到100张原图
        memoryCache.totalCostLimit = 200 * 1024 * 1024 // 200MB
        
        // 缩略图缓存
        thumbnailCache.countLimit = 500 // 增加到500张缩略图
        thumbnailCache.totalCostLimit = 100 * 1024 * 1024 // 100MB
        
        // 初始化Metal处理器
        self.metalProcessor = MetalImageProcessor.shared
        
        if let metalProcessor = metalProcessor {
            print("EnhancedImageCache: Metal GPU acceleration available - Device: \(metalProcessor.deviceName)")
        } else {
            print("EnhancedImageCache: Using CPU-only processing")
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
        preloadLock.lock()
        preloadingFiles.removeAll()
        preloadLock.unlock()
        print("EnhancedImageCache: Cleared caches due to memory warning")
    }
    
    // MARK: - 🚀 核心功能：无缝图片加载
    
    /// 获取图片，先返回缩略图（如果有），然后异步加载高分辨率版本
    func getImageWithSeamlessUpgrade(
        for fileName: String,
        thumbnailSize: CGSize = CGSize(width: 300, height: 300),
        onThumbnail: @escaping (UIImage?) -> Void,
        onHighRes: @escaping (UIImage?) -> Void
    ) {
        let key = NSString(string: fileName)
        
        // 1. 立即检查是否有原图缓存
        if let cachedImage = memoryCache.object(forKey: key) {
            cacheHitCount += 1
            onThumbnail(cachedImage)
            onHighRes(cachedImage)
            return
        }
        
        // 2. 检查是否有缩略图可以立即显示
        let thumbnailKey = NSString(string: "\(fileName)_\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))")
        if let cachedThumbnail = thumbnailCache.object(forKey: thumbnailKey) {
            onThumbnail(cachedThumbnail) // 立即显示缩略图
        } else {
            onThumbnail(nil) // 没有缩略图，显示loading
        }
        
        // 3. 后台加载高分辨率图片
        cacheMissCount += 1
        preloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 加载原图
            let highResImage = self.loadImageFromDisk(fileName: fileName)
            
            if let image = highResImage {
                // 缓存原图
                let cost = Int(image.size.width * image.size.height * 4)
                self.memoryCache.setObject(image, forKey: key, cost: cost)
                
                // 如果之前没有缩略图，现在生成并缓存
                if self.thumbnailCache.object(forKey: thumbnailKey) == nil {
                    if let thumbnail = self.generateThumbnail(from: image, targetSize: thumbnailSize) {
                        let thumbnailCost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                        self.thumbnailCache.setObject(thumbnail, forKey: thumbnailKey, cost: thumbnailCost)
                    }
                }
            }
            
            DispatchQueue.main.async {
                onHighRes(highResImage)
            }
        }
    }
    
    // MARK: - 🧠 智能预加载系统
    
    /// 智能预加载网格中可见照片的原图
    func preloadVisiblePhotos(_ fileNames: [String], currentIndex: Int, visibleRange: Int = 5) {
        let startIndex = max(0, currentIndex - visibleRange)
        let endIndex = min(fileNames.count - 1, currentIndex + visibleRange)
        
        for i in startIndex...endIndex {
            let fileName = fileNames[i]
            
            // 检查是否已经在预加载或已缓存
            preloadLock.lock()
            let isPreloading = preloadingFiles.contains(fileName)
            preloadLock.unlock()
            
            if !isPreloading && memoryCache.object(forKey: NSString(string: fileName)) == nil {
                preloadOriginalImage(fileName: fileName, priority: i == currentIndex ? .high : .normal)
            }
        }
    }
    
    /// 预加载单个原图
    private func preloadOriginalImage(fileName: String, priority: Priority = .normal) {
        preloadLock.lock()
        preloadingFiles.insert(fileName)
        preloadLock.unlock()
        
        let queue = priority == .high ? preloadQueue : backgroundPreloadQueue
        
        queue.async { [weak self] in
            defer {
                self?.preloadLock.lock()
                self?.preloadingFiles.remove(fileName)
                self?.preloadLock.unlock()
            }
            
            guard let self = self else { return }
            
            // 检查是否已经缓存
            let key = NSString(string: fileName)
            if self.memoryCache.object(forKey: key) != nil {
                return // 已经缓存，跳过
            }
            
            // 加载图片
            if let image = self.loadImageFromDisk(fileName: fileName) {
                let cost = Int(image.size.width * image.size.height * 4)
                self.memoryCache.setObject(image, forKey: key, cost: cost)
                
                print("预加载完成: \(fileName)")
            }
        }
    }
    
    private enum Priority {
        case high, normal
    }
    
    // MARK: - 📈 优化的缩略图生成（保持原有接口）
    
    func getThumbnail(for fileName: String, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let thumbnailKey = NSString(string: "\(fileName)_\(Int(size.width))x\(Int(size.height))")
        
        // 先检查缩略图缓存
        if let cachedThumbnail = thumbnailCache.object(forKey: thumbnailKey) {
            DispatchQueue.main.async {
                completion(cachedThumbnail)
            }
            return
        }
        
        // 检查是否有原图可以快速生成缩略图
        let originalKey = NSString(string: fileName)
        if let originalImage = memoryCache.object(forKey: originalKey) {
            // 从缓存的原图快速生成缩略图
            backgroundPreloadQueue.async { [weak self] in
                guard let self = self else { return }
                
                let thumbnail = self.generateThumbnail(from: originalImage, targetSize: size)
                
                if let thumbnail = thumbnail {
                    let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                    self.thumbnailCache.setObject(thumbnail, forKey: thumbnailKey, cost: cost)
                }
                
                DispatchQueue.main.async {
                    completion(thumbnail)
                }
            }
            return
        }
        
        // 否则按原来的方法加载
        backgroundPreloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            let originalImage = self.loadImageFromDisk(fileName: fileName)
            guard let image = originalImage else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let thumbnail = self.generateThumbnail(from: image, targetSize: size)
            
            // 缓存缩略图
            if let thumbnail = thumbnail {
                let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                self.thumbnailCache.setObject(thumbnail, forKey: thumbnailKey, cost: cost)
            }
            
            // 同时缓存原图（为将来的高分辨率加载做准备）
            let originalCost = Int(image.size.width * image.size.height * 4)
            self.memoryCache.setObject(image, forKey: originalKey, cost: originalCost)
            
            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }
    
    // MARK: - 🔧 辅助方法
    
    private func loadImageFromDisk(fileName: String) -> UIImage? {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let imagePath = documentsPath.appendingPathComponent(fileName)
        guard let imageData = try? Data(contentsOf: imagePath),
              let image = UIImage(data: imageData) else {
            return nil
        }
        
        return image
    }
    
    private func generateThumbnail(from image: UIImage, targetSize: CGSize) -> UIImage? {
        // 尝试使用Metal加速
        if let metalProcessor = metalProcessor,
           let metalThumbnail = metalProcessor.generateThumbnailIfPossible(from: image, targetSize: targetSize) {
            return metalThumbnail
        }
        
        // 回退到CPU生成
        return generateThumbnailCPU(from: image, targetSize: targetSize)
    }

    private func generateThumbnailCPU(from image: UIImage, targetSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        
        return renderer.image { context in
            let imageSize = image.size
            
            // 计算保持宽高比的缩放 (AspectFill模式)
            let scaleX = targetSize.width / imageSize.width
            let scaleY = targetSize.height / imageSize.height
            let scale = max(scaleX, scaleY) // 使用较大的缩放比例确保填满
            
            let scaledSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            
            // 计算居中绘制的矩形
            let drawRect = CGRect(
                x: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )
            
            // 填充背景色
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: targetSize))
            
            // 绘制图片
            image.draw(in: drawRect)
        }
    }
    
    // MARK: - 📊 性能监控
    
    func getPerformanceStats() -> [String: Any] {
        let totalRequests = cacheHitCount + cacheMissCount
        let hitRate = totalRequests > 0 ? Double(cacheHitCount) / Double(totalRequests) : 0
        
        var metalStats: [String: Any] = [:]
        if let metalProcessor = metalProcessor {
            // 这里可以添加Metal处理器的统计信息
            metalStats["device_name"] = metalProcessor.deviceName
            metalStats["metal_supported"] = true
        } else {
            metalStats["metal_supported"] = false
            metalStats["device_name"] = "CPU Only"
        }
        
        return [
            "cache_hit_count": cacheHitCount,
            "cache_miss_count": cacheMissCount,
            "cache_hit_rate": hitRate,
            "preloading_count": preloadingFiles.count,
            "cached_originals": memoryCache.countLimit,
            "cached_thumbnails": thumbnailCache.countLimit
        ].merging(metalStats, uniquingKeysWith: { $1 })
    }
    
    // MARK: - 🧹 缓存管理
    
    func clearCache() {
        memoryCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        preloadLock.lock()
        preloadingFiles.removeAll()
        preloadLock.unlock()
        
        cacheHitCount = 0
        cacheMissCount = 0
    }
    
    func removeCachedImage(for fileName: String) {
        let key = NSString(string: fileName)
        memoryCache.removeObject(forKey: key)
        
        // 移除预加载状态
        preloadLock.lock()
        preloadingFiles.remove(fileName)
        preloadLock.unlock()
        
        // 移除相关缩略图
        let commonSizes = [
            CGSize(width: 44, height: 44),
            CGSize(width: 88, height: 88),
            CGSize(width: 120, height: 120),
            CGSize(width: 240, height: 240),
            CGSize(width: 300, height: 300),
            CGSize(width: 600, height: 600)
        ]
        
        for size in commonSizes {
            let thumbnailKey = NSString(string: "\(fileName)_\(Int(size.width))x\(Int(size.height))")
            thumbnailCache.removeObject(forKey: thumbnailKey)
        }
    }
    
    // MARK: - 图片预加载到缓存
    func preloadImageToCache(image: UIImage, fileName: String) {
        let key = NSString(string: fileName)
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key, cost: cost)
        
        // 同时生成一些常用尺寸的缩略图
        let commonSizes = [
            CGSize(width: 120, height: 120),
            CGSize(width: 240, height: 240),
            CGSize(width: 300, height: 300)
        ]
        
        backgroundPreloadQueue.async { [weak self] in
            guard let self = self else { return }
            
            for size in commonSizes {
                if let thumbnail = self.generateThumbnail(from: image, targetSize: size) {
                    let thumbnailKey = NSString(string: "\(fileName)_\(Int(size.width))x\(Int(size.height))")
                    let thumbnailCost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                    self.thumbnailCache.setObject(thumbnail, forKey: thumbnailKey, cost: thumbnailCost)
                }
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension EnhancedImageCache {
    // 添加快速缓存查询方法
    func getCachedThumbnail(key: String) -> UIImage? {
        return thumbnailCache.object(forKey: NSString(string: key))
    }
    
    // 添加快速缓存存储方法
    func cacheThumbnail(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        thumbnailCache.setObject(image, forKey: NSString(string: key), cost: cost)
    }
}

// MARK: - 超快速缩略图生成器
class UltraFastThumbnailGenerator {
    static let shared = UltraFastThumbnailGenerator()
    
    // 预先生成的质量级别
    enum QualityLevel: Int, CaseIterable {
        case micro = 1    // 16x16 - 极速显示
        case tiny = 2     // 64x64 - 快速浏览
        case small = 3    // 120x120 - 普通缩略图
        case medium = 4   // 240x240 - 中等质量
        case large = 5    // 480x480 - 高质量预览
        
        var size: CGSize {
            switch self {
            case .micro: return CGSize(width: 16, height: 16)
            case .tiny: return CGSize(width: 64, height: 64)
            case .small: return CGSize(width: 120, height: 120)
            case .medium: return CGSize(width: 240, height: 240)
            case .large: return CGSize(width: 480, height: 480)
            }
        }
        
        var compressionQuality: CGFloat {
            switch self {
            case .micro, .tiny: return 0.3
            case .small: return 0.5
            case .medium: return 0.7
            case .large: return 0.8
            }
        }
    }
    
    private init() {}
    
    // 生成优化缩略图
    func generateOptimizedThumbnail(
        from image: UIImage,
        quality: QualityLevel
    ) -> UIImage? {
        let imageSize = image.size
        let targetSize = quality.size
        
        // 计算保持宽高比的实际绘制尺寸 (AspectFill模式)
        let scaleX = targetSize.width / imageSize.width
        let scaleY = targetSize.height / imageSize.height
        let scale = max(scaleX, scaleY) // 使用较大的缩放比例确保填满
        
        let scaledSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        
        // 计算居中裁剪的绘制矩形
        let drawRect = CGRect(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
        
        // 使用最高效的iOS系统API
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // 避免不必要的缩放
        format.opaque = true // 性能优化
        
        let renderer = UIGraphicsImageRenderer(
            size: targetSize,
            format: format
        )
        
        return renderer.image { context in
            // 填充背景色（防止透明区域）
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            
            // 绘制保持宽高比的图片
            image.draw(in: drawRect)
        }
    }
    
    // 生成所有质量级别的缩略图（一次性处理）
    func generateAllQualityLevels(from image: UIImage, fileName: String) {
        DispatchQueue.global(qos: .utility).async {
            for quality in QualityLevel.allCases {
                if let thumbnail = self.generateOptimizedThumbnail(
                    from: image,
                    quality: quality
                ) {
                    // 立即缓存到内存
                    let key = "\(fileName)_\(quality.rawValue)"
                    EnhancedImageCache.shared.cacheThumbnail(
                        thumbnail,
                        forKey: key
                    )
                }
            }
        }
    }
}
