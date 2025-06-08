import SwiftUI
import UIKit

// MARK: - Async Image View with Enhanced Caching
struct AsyncImageView: View {
    let fileName: String
    let targetSize: CGSize
    let contentMode: ContentMode
    
    
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var loadingTask: Task<Void, Never>?
    
    init(fileName: String, targetSize: CGSize = CGSize(width: 120, height: 120), contentMode: ContentMode = .fill) {
        self.fileName = fileName
        self.targetSize = targetSize
        self.contentMode = contentMode
    }
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                // 加载中的占位符
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Group {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundColor(.gray)
                                    .font(.title2)
                            }
                        }
                    )
            }
        }
        .onAppear {
            loadImage()
        }
        .onDisappear {
            cancelLoading()
        }
        .onChange(of: fileName) { _ in
            cancelLoading()
            loadImage()
        }
    }
    
    private func loadImage() {
        loadingTask = Task {
            // 稍微延迟一下再显示loading状态，避免闪烁
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if self.image == nil && !Task.isCancelled {
                    self.isLoading = true
                }
            }
            
            // 使用增强缓存系统加载缩略图
            EnhancedImageCache.shared.getThumbnail(for: fileName, size: targetSize) { loadedImage in
                if !Task.isCancelled {
                    self.image = loadedImage
                    self.isLoading = false
                }
            }
        }
    }
    
    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
}

// MARK: - High Resolution Image View for Detail View
struct HighResAsyncImageView: View {
    let fileName: String
    
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var loadingTask: Task<Void, Never>?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Group {
                            if isLoading {
                                VStack(spacing: 16) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.2)
                                    
                                    Text("Loading...")
                                        .foregroundColor(.white)
                                        .font(.caption)
                                }
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 60))
                                    
                                    Text("Failed to load image")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                            }
                        }
                    )
            }
        }
        .onAppear {
            loadHighResImage()
        }
        .onDisappear {
            cancelLoading()
        }
        .onChange(of: fileName) { _ in
            cancelLoading()
            loadHighResImage()
        }
    }
    
    private func loadHighResImage() {
        loadingTask = Task {
            await MainActor.run {
                isLoading = true
                image = nil
            }
            
            // 🔄 使用 EnhancedImageCache 的无缝升级功能
            EnhancedImageCache.shared.getImageWithSeamlessUpgrade(
                for: fileName,
                thumbnailSize: CGSize(width: 300, height: 300),
                onThumbnail: { thumbnailImage in
                    if !Task.isCancelled && self.image == nil {
                        self.image = thumbnailImage
                    }
                },
                onHighRes: { highResImage in
                    if !Task.isCancelled {
                        if let highResImage = highResImage {
                            self.image = highResImage
                            self.isLoading = false
                        } else {
                            self.isLoading = false
                        }
                    }
                }
            )
        }
    }
    
    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
}

// MARK: - Thumbnail View for Filmstrip
struct ThumbnailView: View {
    let fileName: String
    let size: CGFloat
    let isSelected: Bool
    
    @State private var image: UIImage?
    @State private var loadingTask: Task<Void, Never>?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                            .font(.caption)
                    )
            }
        }
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isSelected ? 1.0 : 0.6)
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            cancelLoading()
        }
    }
    
    private func loadThumbnail() {
        let thumbnailSize = CGSize(width: size * 2, height: size * 2) // 2x for retina
        
        loadingTask = Task {
            // 🔄 使用 EnhancedImageCache 替代 ImageCache
            EnhancedImageCache.shared.getThumbnail(for: fileName, size: thumbnailSize) { loadedImage in
                if !Task.isCancelled {
                    self.image = loadedImage
                }
            }
        }
    }
    
    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
}

// MARK: - 零延迟图片显示组件
struct ZeroDelayImageView: View {
    let fileName: String
    let targetSize: CGSize
    
    @State private var displayImage: UIImage?
    @State private var currentQuality: UltraFastThumbnailGenerator.QualityLevel = .micro
    @State private var loadingTasks: [Task<Void, Never>] = []
    
    var body: some View {
        Group {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)  // 确保使用 .fill 模式
                    // 质量提升时的平滑过渡
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            } else {
                // 极简占位符（避免白屏闪烁）
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
            }
        }
        .clipped() // 重要：确保裁剪超出部分
        .onAppear {
            startProgressiveLoading()
        }
        .onDisappear {
            cancelAllTasks()
        }
    }
    
    private func startProgressiveLoading() {
        // 立即显示最小质量图片
        loadQuality(.micro)
        
        // 🔧 调整升级时间，减少变形感知
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.loadQuality(.tiny)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.loadQuality(.small)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.loadQuality(.medium)
        }
        
        // 最终高质量版本 - 稍微延迟以确保用户感知到改善
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.loadOriginalImage()
        }
    }
    
    private func loadQuality(_ quality: UltraFastThumbnailGenerator.QualityLevel) {
        let task = Task {
            let key = "\(fileName)_\(quality.rawValue)"
            
            // 先尝试从缓存获取
            if let cachedImage = EnhancedImageCache.shared.getCachedThumbnail(key: key) {
                await MainActor.run {
                    if !Task.isCancelled && (displayImage == nil || quality.rawValue > currentQuality.rawValue) {
                        displayImage = cachedImage
                        currentQuality = quality
                    }
                }
                return
            }
            
            // 如果缓存中没有，快速生成
            if let originalImage = await loadImageFromDisk() {
                let thumbnail = UltraFastThumbnailGenerator.shared.generateOptimizedThumbnail(
                    from: originalImage,
                    quality: quality
                )
                
                await MainActor.run {
                    if !Task.isCancelled && (displayImage == nil || quality.rawValue > currentQuality.rawValue) {
                        displayImage = thumbnail
                        currentQuality = quality
                        
                        // 同时缓存这个质量级别
                        if let thumbnail = thumbnail {
                            EnhancedImageCache.shared.cacheThumbnail(thumbnail, forKey: key)
                        }
                    }
                }
            }
        }
        
        loadingTasks.append(task)
    }
    
    private func loadOriginalImage() {
        let task = Task {
            // 使用EnhancedImageCache的无缝升级功能
            EnhancedImageCache.shared.getImageWithSeamlessUpgrade(
                for: fileName,
                onThumbnail: { _ in }, // 已经有渐进式加载了
                onHighRes: { highResImage in
                    if !Task.isCancelled, let highResImage = highResImage {
                        self.displayImage = highResImage
                    }
                }
            )
        }
        
        loadingTasks.append(task)
    }
    
    private func loadImageFromDisk() async -> UIImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let imagePath = documentsPath.appendingPathComponent(fileName)
                if let imageData = try? Data(contentsOf: imagePath),
                   let image = UIImage(data: imageData) {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private func cancelAllTasks() {
        loadingTasks.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }
}

// MARK: - 增强的缩略图视图（替换现有的ThumbnailView）
struct EnhancedThumbnailView: View {
    let fileName: String
    let size: CGFloat
    let isSelected: Bool
    
    @State private var image: UIImage?
    @State private var loadingTask: Task<Void, Never>?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)  // 确保使用 .fill 模式
                    .frame(width: size, height: size)
                    .clipped() // 重要：裁剪超出部分
            } else {
                // 使用我们修复后的ZeroDelayImageView
                ZeroDelayImageView(
                    fileName: fileName,
                    targetSize: CGSize(width: size * 2, height: size * 2)
                )
                .frame(width: size, height: size)
                .clipped() // 确保裁剪
            }
        }
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isSelected ? 1.0 : 0.6)
        .onAppear {
            startEnhancedLoading()
        }
        .onDisappear {
            cancelLoading()
        }
    }
    
    private func startEnhancedLoading() {
        loadingTask = Task {
            // 先尝试快速显示已缓存的小缩略图
            let quickKey = "\(fileName)_\(UltraFastThumbnailGenerator.QualityLevel.small.rawValue)"
            if let quickImage = EnhancedImageCache.shared.getCachedThumbnail(key: quickKey) {
                await MainActor.run {
                    if !Task.isCancelled {
                        self.image = quickImage
                    }
                }
            }
            
            // 然后加载更高质量的缩略图
            let thumbnailSize = CGSize(width: size * 2, height: size * 2)
            
            // 🔧 修复布尔值判断错误
            EnhancedImageCache.shared.getThumbnail(for: fileName, size: thumbnailSize) { loadedImage in
                Task { @MainActor in
                    // 正确的可选值判断方式
                    let taskNotCancelled = self.loadingTask?.isCancelled == false || self.loadingTask == nil
                    if taskNotCancelled, let loadedImage = loadedImage {
                        self.image = loadedImage
                    }
                }
            }
        }
    }
    
    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
}
