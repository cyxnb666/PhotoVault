import SwiftUI
import UIKit

// MARK: - Async Image View with Caching
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
            // 使用缓存系统加载缩略图
            await MainActor.run {
                isLoading = true
            }
            
            ImageCache.shared.getThumbnail(for: fileName, size: targetSize) { loadedImage in
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
            
            // 先显示缩略图作为占位符
            ImageCache.shared.getThumbnail(for: fileName, size: CGSize(width: 300, height: 300)) { thumbnailImage in
                if !Task.isCancelled && self.image == nil {
                    self.image = thumbnailImage
                }
            }
            
            // 然后加载高分辨率图片
            ImageCache.shared.getImageAsync(for: fileName) { highResImage in
                if !Task.isCancelled {
                    if let highResImage = highResImage {
                        self.image = highResImage
                        self.isLoading = false
                    } else {
                        self.isLoading = false
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
        // 移除这里的 scaleEffect 和 animation，让外层控制
        // .scaleEffect(isSelected ? 1.0 : 0.85)
        // .animation(.easeInOut(duration: 0.2), value: isSelected)
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
            ImageCache.shared.getThumbnail(for: fileName, size: thumbnailSize) { loadedImage in
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
