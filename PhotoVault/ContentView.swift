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
    @State private var dragOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                Spacer()
                
                // Image Viewer - 简单的 TabView 滑动
                TabView(selection: $currentIndex) {
                    ForEach(Array(viewModel.photos.enumerated()), id: \.element.id) { index, photo in
                        SimpleImageView(photo: photo)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .scaleEffect(scale)
                .offset(x: dragOffset.width, y: dragOffset.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // 只响应向下滑动
                            if value.translation.height > 0 {
                                dragOffset = value.translation
                                // 根据拖拽距离计算缩放比例
                                let dragProgress = min(value.translation.height / 200, 1.0)
                                scale = 1.0 - (dragProgress * 0.3) // 最多缩小到70%
                            }
                        }
                        .onEnded { value in
                            // 如果向下滑动超过100像素，关闭详细视图
                            if value.translation.height > 100 {
                                viewModel.showingImageDetail = false
                            } else {
                                // 否则弹回原位
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    dragOffset = .zero
                                    scale = 1.0
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
                
                Spacer()
                
                // 底部缩略图条 - iOS风格
                FilmstripView(
                    photos: viewModel.photos,
                    currentIndex: $currentIndex
                )
                .opacity(1.0 - min(dragOffset.height / 100, 1.0)) // 滑动时淡出
                .padding(.bottom, 50)
            }
        }
    }
}

// MARK: - Simple Image View
struct SimpleImageView: View {
    let photo: PhotoItem
    
    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: photo.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - Filmstrip View (iOS Style Thumbnail Scrubber)
struct FilmstripView: View {
    let photos: [PhotoItem]
    @Binding var currentIndex: Int
    @State private var hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    @State private var lastHapticIndex = -1
    @State private var isDragging = false
    @State private var dragStartIndex = 0
    @State private var currentScrollOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let thumbnailSize: CGFloat = 44
            let spacing: CGFloat = 4
            let totalThumbnailWidth = thumbnailSize + spacing
            let leadingPadding = max(0, (screenWidth - thumbnailSize) / 2)
            
            ScrollViewReader { proxy in
                ZStack {
                    // 可滚动的缩略图ScrollView
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            // 前导空白
                            Spacer()
                                .frame(width: leadingPadding)
                            
                            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                FilmstripThumbnail(
                                    photo: photo,
                                    isSelected: index == currentIndex,
                                    size: thumbnailSize,
                                    isDragging: isDragging
                                )
                                .id(index)
                            }
                            
                            // 后导空白
                            Spacer()
                                .frame(width: leadingPadding)
                        }
                    }
                    .scrollDisabled(false) // 允许原生滚动
                    .onAppear {
                        // 初始时滚动到当前照片位置
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                    .onChange(of: currentIndex) { newIndex in
                        // 当外部改变currentIndex时，滚动到对应位置
                        if !isDragging {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                    
                    // 透明手势层用于检测滑动并计算照片索引
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(coordinateSpace: .local)
                                .onChanged { value in
                                    if !isDragging {
                                        isDragging = true
                                        dragStartIndex = currentIndex
                                        hapticFeedback.prepare()
                                        lastHapticIndex = currentIndex
                                        currentScrollOffset = 0
                                        print("Started dragging from index: \(currentIndex)")
                                    }
                                    
                                    // 计算滑动距离
                                    let translation = value.translation.width
                                    currentScrollOffset = translation
                                    
                                    // 根据滑动距离计算新的照片索引
                                    let sensitivity: CGFloat = 1.0
                                    let indexChange = -translation / (totalThumbnailWidth * sensitivity)
                                    let targetIndex = Double(dragStartIndex) + Double(indexChange)
                                    let newIndex = max(0, min(photos.count - 1, Int(round(targetIndex))))
                                    
                                    print("Translation: \(translation), Target index: \(newIndex)")
                                    
                                    // 实时更新照片索引实现快速浏览
                                    if newIndex != currentIndex {
                                        currentIndex = newIndex
                                        
                                        // 让缩略图条滚动到对应位置
                                        proxy.scrollTo(newIndex, anchor: .center)
                                        
                                        // 触觉反馈
                                        if newIndex != lastHapticIndex {
                                            hapticFeedback.impactOccurred()
                                            lastHapticIndex = newIndex
                                        }
                                        
                                        print("Updated to index: \(newIndex)")
                                    }
                                }
                                .onEnded { value in
                                    print("Drag ended at index: \(currentIndex)")
                                    
                                    // 确保最终位置居中
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        proxy.scrollTo(currentIndex, anchor: .center)
                                    }
                                    
                                    // 重置状态
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        isDragging = false
                                        lastHapticIndex = -1
                                        currentScrollOffset = 0
                                    }
                                }
                        )
                    
                    // 中心指示器
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 2, height: 10)
                            .cornerRadius(1)
                        Spacer().frame(height: 2)
                    }
                    .allowsHitTesting(false)
                }
                
                // 左右渐变遮罩
                HStack {
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.8), Color.clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)
                    .allowsHitTesting(false)
                    
                    Spacer()
                    
                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.8)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 60)
    }
}

// MARK: - ScrollOffset Preference Key (保留以备后用)
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Enhanced Filmstrip Thumbnail
struct FilmstripThumbnail: View {
    let photo: PhotoItem
    let isSelected: Bool
    let size: CGFloat
    let isDragging: Bool
    
    var body: some View {
        Image(uiImage: photo.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isSelected ? Color.white : Color.white.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .opacity(isSelected ? 1.0 : 0.6)
            .scaleEffect(isSelected ? 1.0 : 0.85)
            // 拖拽时增强高亮效果
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(isDragging && isSelected ? 0.2 : 0))
            )
            .animation(.easeInOut(duration: isDragging ? 0.1 : 0.2), value: isSelected)
    }
}
