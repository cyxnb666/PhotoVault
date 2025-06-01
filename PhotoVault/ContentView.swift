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

// MARK: - Filmstrip View (iOS Style)
struct FilmstripView: View {
    let photos: [PhotoItem]
    @Binding var currentIndex: Int
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let thumbnailSize: CGFloat = 44
            let spacing: CGFloat = 4
            
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        // 添加前导空白，让第一个缩略图能居中
                        Spacer()
                            .frame(width: (screenWidth - thumbnailSize) / 2)
                        
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            FilmstripThumbnail(
                                photo: photo,
                                isSelected: index == currentIndex,
                                size: thumbnailSize
                            )
                            .id(index)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentIndex = index
                                }
                            }
                        }
                        
                        // 添加后导空白，让最后一个缩略图能居中
                        Spacer()
                            .frame(width: (screenWidth - thumbnailSize) / 2)
                    }
                }
                .onChange(of: currentIndex) { newIndex in
                    // 主图切换时，自动滚动缩略图条让当前图片居中
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    // 初始时滚动到当前照片位置
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
            
            // 左右渐变遮罩效果
            HStack {
                LinearGradient(
                    gradient: Gradient(colors: [Color.black, Color.clear]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 20)
                
                Spacer()
                
                LinearGradient(
                    gradient: Gradient(colors: [Color.clear, Color.black]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 20)
            }
            .allowsHitTesting(false) // 不阻止点击事件
        }
        .frame(height: 60)
    }
}

// MARK: - Filmstrip Thumbnail
struct FilmstripThumbnail: View {
    let photo: PhotoItem
    let isSelected: Bool
    let size: CGFloat
    
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
            .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
