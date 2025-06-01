import SwiftUI
import PhotosUI

// MARK: - Models
struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let image: UIImage
    
    init(image: UIImage) {
        self.image = image
    }
}

// MARK: - View Model
class PhotoGalleryViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selectedPhotos: [PhotosPickerItem] = []
    @Published var selectedPhotoItem: PhotoItem?
    @Published var showingImageDetail = false
    
    func loadSelectedPhotos() {
        Task {
            var newPhotos: [PhotoItem] = []
            
            for item in selectedPhotos {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let photoItem = PhotoItem(image: image)
                    newPhotos.append(photoItem)
                }
            }
            
            await MainActor.run {
                self.photos.append(contentsOf: newPhotos)
                self.selectedPhotos = []
            }
        }
    }
    
    func deletePhoto(_ photo: PhotoItem) {
        photos.removeAll { $0.id == photo.id }
    }
    
    func selectPhoto(_ photo: PhotoItem) {
        selectedPhotoItem = photo
        showingImageDetail = true
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = PhotoGalleryViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                if viewModel.photos.isEmpty {
                    EmptyStateView()
                } else {
                    PhotoGridView()
                }
            }
            .navigationTitle("PhotoVault")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    PhotosPicker(
                        selection: $viewModel.selectedPhotos,
                        maxSelectionCount: 10,
                        matching: .images
                    ) {
                        Image(systemName: "plus")
                            .font(.title2)
                    }
                }
            }
            .onChange(of: viewModel.selectedPhotos) { _ in
                viewModel.loadSelectedPhotos()
            }
        }
        .environmentObject(viewModel)
        .fullScreenCover(isPresented: $viewModel.showingImageDetail) {
            ImageDetailView()
                .environmentObject(viewModel)
        }
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 80))
                .foregroundColor(.gray)
            
            VStack(spacing: 8) {
                Text("No Photos Yet")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Tap the + button to add photos from your library")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            PhotosPicker(
                selection: $viewModel.selectedPhotos,
                maxSelectionCount: 10,
                matching: .images
            ) {
                HStack {
                    Image(systemName: "plus")
                    Text("Add Photos")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(25)
            }
        }
        .padding()
    }
}

// MARK: - Photo Grid View
struct PhotoGridView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(viewModel.photos) { photo in
                    PhotoGridCell(photo: photo)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Photo Grid Cell
struct PhotoGridCell: View {
    let photo: PhotoItem
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    @State private var showingDeleteAlert = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Image(uiImage: photo.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .cornerRadius(12)
                    .onTapGesture {
                        viewModel.selectPhoto(photo)
                    }
                
                Button {
                    showingDeleteAlert = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                .padding(8)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .alert("Delete Photo", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                withAnimation {
                    viewModel.deletePhoto(photo)
                }
            }
        } message: {
            Text("Are you sure you want to delete this photo?")
        }
    }
}

// MARK: - Image Detail View
struct ImageDetailView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    @State private var currentIndex: Int = 0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                // Header
                HStack {
                    Button("Done") {
                        viewModel.showingImageDetail = false
                    }
                    .foregroundColor(.white)
                    .font(.headline)
                    
                    Spacer()
                    
                    Text("\(currentIndex + 1) of \(viewModel.photos.count)")
                        .foregroundColor(.white)
                        .font(.caption)
                }
                .padding()
                
                // Image Viewer - 移除 TabView，使用自定义实现
                ZoomableImageView(
                    photo: viewModel.photos[currentIndex],
                    onPreviousPhoto: {
                        if currentIndex > 0 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentIndex -= 1
                            }
                        }
                    },
                    onNextPhoto: {
                        if currentIndex < viewModel.photos.count - 1 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentIndex += 1
                            }
                        }
                    }
                )
                .onAppear {
                    if let selectedPhoto = viewModel.selectedPhotoItem,
                       let index = viewModel.photos.firstIndex(where: { $0.id == selectedPhoto.id }) {
                        currentIndex = index
                    }
                }
                
                // Page Indicator
                if viewModel.photos.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(0..<viewModel.photos.count, id: \.self) { index in
                            Circle()
                                .fill(currentIndex == index ? Color.white : Color.white.opacity(0.5))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

// MARK: - Zoomable Image View
struct ZoomableImageView: View {
    let photo: PhotoItem
    let onPreviousPhoto: () -> Void
    let onNextPhoto: () -> Void
    
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @GestureState private var magnifyBy = 1.0
    @GestureState private var dragOffset = CGSize.zero
    
    // 用于手势速度和边界检测
    @State private var dragStartTime: Date = Date()
    @State private var dragStartLocation: CGPoint = .zero
    @State private var imageSize: CGSize = .zero
    @State private var containerSize: CGSize = .zero
    
    // 交互参数
    private let scaleThreshold: CGFloat = 1.05
    private let velocityThreshold: Double = 200
    private let minimumSwipeDistance: CGFloat = 50
    private let boundaryTolerance: CGFloat = 20
    
    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: photo.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale * magnifyBy)
                .offset(
                    x: offset.width + dragOffset.width,
                    y: offset.height + dragOffset.height
                )
                .onAppear {
                    containerSize = geometry.size
                    calculateImageSize(containerSize: geometry.size)
                }
                .onChange(of: geometry.size) { newSize in
                    containerSize = newSize
                    calculateImageSize(containerSize: newSize)
                }
                .gesture(
                    SimultaneousGesture(
                        // 缩放手势
                        MagnificationGesture()
                            .updating($magnifyBy) { currentState, gestureState, _ in
                                gestureState = currentState
                            }
                            .onEnded { value in
                                scale *= value
                                if scale < 1 {
                                    withAnimation(.easeInOut) {
                                        scale = 1
                                        offset = .zero
                                    }
                                } else if scale > 5 {
                                    scale = 5
                                }
                                // 缩放后重新计算边界
                                constrainOffset()
                            },
                        
                        // 拖拽手势
                        DragGesture()
                            .updating($dragOffset) { currentState, gestureState, _ in
                                gestureState = currentState.translation
                            }
                            .onChanged { value in
                                if dragStartTime.timeIntervalSinceNow < -0.1 {
                                    dragStartTime = Date()
                                    dragStartLocation = value.startLocation
                                }
                            }
                            .onEnded { value in
                                handleDragEnd(value: value)
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut) {
                        if scale > scaleThreshold {
                            scale = 1
                            offset = .zero
                        } else {
                            scale = 2
                            // 双击位置为中心进行缩放
                            // 这里可以根据点击位置调整offset，暂时简化
                        }
                    }
                }
        }
    }
    
    private func calculateImageSize(containerSize: CGSize) {
        let imageAspectRatio = photo.image.size.width / photo.image.size.height
        let containerAspectRatio = containerSize.width / containerSize.height
        
        if imageAspectRatio > containerAspectRatio {
            // 图片更宽，以容器宽度为准
            imageSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / imageAspectRatio
            )
        } else {
            // 图片更高，以容器高度为准
            imageSize = CGSize(
                width: containerSize.height * imageAspectRatio,
                height: containerSize.height
            )
        }
    }
    
    private func handleDragEnd(value: DragGesture.Value) {
        let dragDuration = Date().timeIntervalSince(dragStartTime)
        let dragDistance = sqrt(pow(value.translation.x, 2) + pow(value.translation.y, 2))
        let velocity = dragDistance / max(dragDuration, 0.01)
        
        // 如果图片未放大，左右滑动切换照片
        if scale <= scaleThreshold {
            if abs(value.translation.x) > minimumSwipeDistance && abs(value.translation.x) > abs(value.translation.y) {
                if value.translation.x > 0 {
                    onPreviousPhoto()
                } else {
                    onNextPhoto()
                }
                return
            }
        } else {
            // 图片已放大，检查是否在边界且为快速滑动
            let currentOffsetWidth = offset.width + value.translation.x
            let currentOffsetHeight = offset.height + value.translation.y
            
            let maxOffset = calculateMaxOffset()
            let isAtLeftBoundary = currentOffsetWidth >= maxOffset.width - boundaryTolerance
            let isAtRightBoundary = currentOffsetWidth <= -maxOffset.width + boundaryTolerance
            
            if velocity > velocityThreshold && abs(value.translation.x) > minimumSwipeDistance {
                if value.translation.x > 0 && isAtLeftBoundary {
                    onPreviousPhoto()
                    return
                } else if value.translation.x < 0 && isAtRightBoundary {
                    onNextPhoto()
                    return
                }
            }
        }
        
        // 否则进行正常的图片移动
        offset.width += value.translation.x
        offset.height += value.translation.y
        constrainOffset()
    }
    
    private func calculateMaxOffset() -> CGSize {
        let scaledImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        
        let maxOffsetWidth = max(0, (scaledImageSize.width - containerSize.width) / 2)
        let maxOffsetHeight = max(0, (scaledImageSize.height - containerSize.height) / 2)
        
        return CGSize(width: maxOffsetWidth, height: maxOffsetHeight)
    }
    
    private func constrainOffset() {
        let maxOffset = calculateMaxOffset()
        
        withAnimation(.easeOut(duration: 0.2)) {
            offset.width = min(maxOffset.width, max(-maxOffset.width, offset.width))
            offset.height = min(maxOffset.height, max(-maxOffset.height, offset.height))
        }
    }
}
