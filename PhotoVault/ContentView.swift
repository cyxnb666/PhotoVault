import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Optimized PhotoItem Model
struct PhotoItem: Identifiable, Hashable, Codable {
    let id = UUID()
    let fileName: String
    
    // 移除原来的 image computed property，现在通过缓存系统获取图片
    
    init(image: UIImage) {
        self.fileName = "\(UUID().uuidString).jpg"
        self.saveImage(image)
    }
    
    init(fileName: String) {
        self.fileName = fileName
    }
    
    private func saveImage(_ image: UIImage) {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let imagePath = documentsPath.appendingPathComponent(fileName)
        
        // 后台保存图片，避免阻塞主线程
        DispatchQueue.global(qos: .utility).async {
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                try? imageData.write(to: imagePath)
            }
        }
    }
    
    func deleteImageFile() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let imagePath = documentsPath.appendingPathComponent(fileName)
        
        // 从缓存中移除
        ImageCache.shared.removeCachedImage(for: fileName)
        
        // 删除文件
        try? FileManager.default.removeItem(at: imagePath)
    }
    
    // MARK: - 缓存辅助方法
    func loadImageAsync(completion: @escaping (UIImage?) -> Void) {
        ImageCache.shared.getImageAsync(for: fileName, completion: completion)
    }
    
    func loadThumbnail(size: CGSize, completion: @escaping (UIImage?) -> Void) {
        ImageCache.shared.getThumbnail(for: fileName, size: size, completion: completion)
    }
    
    // 检查文件是否存在
    var fileExists: Bool {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let imagePath = documentsPath.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: imagePath.path)
    }
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Equatable conformance
    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Document Picker Coordinator
struct DocumentPickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onFolderSelected: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        
        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
            if let url = urls.first {
                parent.onFolderSelected(url)
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Optimized View Model
class PhotoGalleryViewModel: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selectedPhotoItem: PhotoItem?
    @Published var showingImageDetail = false
    @Published var showingDocumentPicker = false
    @Published var isSelectionMode = false
    @Published var selectedPhotos: Set<PhotoItem> = []
    
    private let photosKey = "SavedPhotos"
    
    init() {
        loadSavedPhotos()
    }
    
    // MARK: - Persistence Methods
    private func savePhotos() {
        let fileNames = photos.map { $0.fileName }
        UserDefaults.standard.set(fileNames, forKey: photosKey)
    }
    
    // 改进的loadSavedPhotos方法，包含验证和预加载
    private func loadSavedPhotos() {
        guard let savedFileNames = UserDefaults.standard.array(forKey: photosKey) as? [String] else {
            return
        }
        
        // 后台验证文件存在性
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let validPhotos = savedFileNames.compactMap { fileName -> PhotoItem? in
                let photoItem = PhotoItem(fileName: fileName)
                return photoItem.fileExists ? photoItem : nil
            }
            
            DispatchQueue.main.async {
                self?.photos = validPhotos
                // 开始预加载缩略图
                self?.preloadThumbnails()
            }
        }
    }
    
    // 改进的loadPhotosFromFolder方法，包含进度反馈
    func loadPhotosFromFolder(at url: URL) {
        Task {
            var newPhotos: [PhotoItem] = []
            
            guard url.startAccessingSecurityScopedResource() else {
                print("无法访问所选文件夹")
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            do {
                let fileManager = FileManager.default
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
                
                let supportedImageTypes: [UTType] = [.jpeg, .png, .heic, .gif, .bmp, .tiff]
                
                // 分批处理图片，避免内存峰值
                let batchSize = 10
                for batch in contents.chunked(into: batchSize) {
                    for fileURL in batch {
                        if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentTypeKey]),
                           let contentType = resourceValues.contentType,
                           supportedImageTypes.contains(where: { contentType.conforms(to: $0) }) {
                            
                            if let imageData = try? Data(contentsOf: fileURL),
                               let image = UIImage(data: imageData) {
                                let photoItem = PhotoItem(image: image)
                                newPhotos.append(photoItem)
                            }
                        }
                    }
                    
                    // 每处理一批就更新UI并短暂休息
                    await MainActor.run {
                        self.photos.append(contentsOf: newPhotos)
                        newPhotos.removeAll()
                        self.savePhotos()
                    }
                    
                    // 短暂休息，避免阻塞主线程
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
                
                await MainActor.run {
                    // 开始预加载新添加的照片的缩略图
                    self.preloadThumbnails()
                }
                
            } catch {
                print("读取文件夹内容时出错: \(error)")
            }
        }
    }
    
    func deletePhoto(_ photo: PhotoItem) {
        photo.deleteImageFile() // 删除本地文件
        photos.removeAll { $0.id == photo.id }
        savePhotos() // 保存更新后的列表
    }
    
    func togglePhotoSelection(_ photo: PhotoItem) {
        if selectedPhotos.contains(photo) {
            selectedPhotos.remove(photo)
        } else {
            selectedPhotos.insert(photo)
        }
    }
    
    func deleteSelectedPhotos() {
        // 删除所选照片的本地文件
        for photo in selectedPhotos {
            photo.deleteImageFile()
        }
        
        photos.removeAll { selectedPhotos.contains($0) }
        selectedPhotos.removeAll()
        isSelectionMode = false
        savePhotos() // 保存更新后的列表
    }
    
    func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedPhotos.removeAll()
        }
    }
    
    func selectAllPhotos() {
        selectedPhotos = Set(photos)
    }
    
    func deselectAllPhotos() {
        selectedPhotos.removeAll()
    }
    
    // 改进的selectPhoto方法，包含预加载
    func selectPhoto(_ photo: PhotoItem) {
        selectedPhotoItem = photo
        showingImageDetail = true
        
        // 找到选中照片的索引并预加载附近的图片
        if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            preloadNearbyHighResImages(around: index)
        }
        
        // 进入图片详细视图时退出选择模式
        if isSelectionMode {
            isSelectionMode = false
            selectedPhotos.removeAll()
        }
    }
    
    func showDocumentPicker() {
        showingDocumentPicker = true
    }
    
    // MARK: - Performance Optimization Methods
    
    // 预加载缩略图
    func preloadThumbnails() {
        let thumbnailSize = CGSize(width: 240, height: 240) // Grid用的缩略图
        let fileNames = photos.map { $0.fileName }
        
        DispatchQueue.global(qos: .utility).async {
            ImageCache.shared.preloadThumbnails(for: fileNames, size: thumbnailSize)
        }
    }
    
    // 预加载当前照片附近的高分辨率图片（用于详细视图）
    func preloadNearbyHighResImages(around index: Int) {
        let range = max(0, index - 2)...min(photos.count - 1, index + 2)
        
        for i in range {
            if i < photos.count {
                photos[i].loadImageAsync { _ in
                    // 预加载，不需要处理结果
                }
            }
        }
    }
}

// 数组分批扩展
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
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
            .navigationTitle(viewModel.isSelectionMode ? "Select Photos" : "PhotoVault")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.isSelectionMode {
                        Button(viewModel.selectedPhotos.count == viewModel.photos.count ? "Deselect All" : "Select All") {
                            if viewModel.selectedPhotos.count == viewModel.photos.count {
                                viewModel.deselectAllPhotos()
                            } else {
                                viewModel.selectAllPhotos()
                            }
                        }
                    } else {
                        HStack {
                            // 添加性能监控按钮（可选）
                            PerformanceMonitorButton()
                            
                            // 可选：添加状态指示器
                            StatusBadge(isMetalEnabled: MetalImageProcessor.isSupported)
                        }
                    }
                }
                
                // 其他toolbar items保持不变...
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if viewModel.isSelectionMode {
                            Button("Cancel") {
                                viewModel.toggleSelectionMode()
                            }
                        } else {
                            if !viewModel.photos.isEmpty {
                                Button("Select") {
                                    viewModel.toggleSelectionMode()
                                }
                            }
                            
                            Button {
                                viewModel.showDocumentPicker()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.title2)
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .bottomBar) {
                    if viewModel.isSelectionMode && !viewModel.selectedPhotos.isEmpty {
                        Button {
                            viewModel.deleteSelectedPhotos()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete (\(viewModel.selectedPhotos.count))")
                            }
                            .foregroundColor(.red)
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showingDocumentPicker) {
                DocumentPickerView(isPresented: $viewModel.showingDocumentPicker) { url in
                    viewModel.loadPhotosFromFolder(at: url)
                }
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
                
                Text("Tap the + button to select a folder with photos")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                viewModel.showDocumentPicker()
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Select Folder")
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

// MARK: - Optimized Photo Grid View
struct PhotoGridView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    // 调整为更紧凑的布局
    let columns = [
        GridItem(.flexible(), spacing: 1),  // 减少spacing从2到1
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 1) {  // 减少垂直spacing从2到1
                ForEach(viewModel.photos) { photo in
                    PhotoGridCell(photo: photo)
                        .onAppear {
                            // 当item出现时，预加载附近的缩略图
                            preloadNearbyThumbnails(for: photo)
                        }
                        .onDisappear {
                            // 当item消失时，可以清理一些不必要的缓存
                            // 但我们保留缓存以提高性能
                        }
                }
            }
            .padding(4)  // 减少外边距从8到4
        }
        .onAppear {
            // 视图出现时开始预加载
            viewModel.preloadThumbnails()
        }
    }
    
    private func preloadNearbyThumbnails(for photo: PhotoItem) {
        guard let currentIndex = viewModel.photos.firstIndex(where: { $0.id == photo.id }) else { return }
        
        // 预加载当前照片前后5张的缩略图
        let range = max(0, currentIndex - 5)...min(viewModel.photos.count - 1, currentIndex + 5)
        let nearbyPhotos = range.map { viewModel.photos[$0].fileName }
        
        ImageCache.shared.preloadThumbnails(
            for: nearbyPhotos,
            size: CGSize(width: 240, height: 240)
        )
    }
}

// MARK: - Optimized Photo Grid Cell
struct PhotoGridCell: View {
    let photo: PhotoItem
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    var isSelected: Bool {
        viewModel.selectedPhotos.contains(photo)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // 使用新的AsyncImageView替代原来的同步图片加载
                AsyncImageView(
                    fileName: photo.fileName,
                    targetSize: CGSize(
                        width: geometry.size.width * 2, // 2x for retina
                        height: geometry.size.height * 2
                    ),
                    contentMode: .fill
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .cornerRadius(12)
                .onTapGesture {
                    if viewModel.isSelectionMode {
                        viewModel.togglePhotoSelection(photo)
                    } else {
                        viewModel.selectPhoto(photo)
                    }
                }
                .overlay(
                    // 选择模式下的遮罩
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(viewModel.isSelectionMode && isSelected ? 0.3 : 0))
                )
                .overlay(
                    // 选择边框
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: viewModel.isSelectionMode && isSelected ? 3 : 0)
                )
                
                if viewModel.isSelectionMode {
                    // 选择指示器
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 24, height: 24)
                        
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        } else {
                            Circle()
                                .stroke(Color.gray, lineWidth: 2)
                                .frame(width: 20, height: 20)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
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
            
            // 如果没有照片了，自动关闭详细视图
            if viewModel.photos.isEmpty {
                Color.clear
                    .onAppear {
                        viewModel.showingImageDetail = false
                    }
            } else {
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
                        updateCurrentIndex()
                    }
                    .onChange(of: viewModel.photos) { _ in
                        // 当照片数组发生变化时，重新计算当前索引
                        updateCurrentIndex()
                    }
                    
                    Spacer()
                    
                    // 底部缩略图条 - 使用优化版本
                    OptimizedFilmstripView(
                        photos: viewModel.photos,
                        currentIndex: $currentIndex
                    )
                    .opacity(1.0 - min(dragOffset.height / 100, 1.0)) // 滑动时淡出
                    .padding(.bottom, 50)
                }
            }
        }
    }
    
    private func updateCurrentIndex() {
        // 如果没有照片，直接返回
        guard !viewModel.photos.isEmpty else {
            viewModel.showingImageDetail = false
            return
        }
        
        // 如果有选中的照片，尝试找到它的新索引
        if let selectedPhoto = viewModel.selectedPhotoItem,
           let newIndex = viewModel.photos.firstIndex(where: { $0.id == selectedPhoto.id }) {
            currentIndex = newIndex
        } else {
            // 如果当前选中的照片已被删除，调整到有效范围内
            if currentIndex >= viewModel.photos.count {
                currentIndex = max(0, viewModel.photos.count - 1)
            }
            // 更新 selectedPhotoItem 为当前显示的照片
            if currentIndex < viewModel.photos.count {
                viewModel.selectedPhotoItem = viewModel.photos[currentIndex]
            }
        }
    }
}

// MARK: - Optimized Simple Image View
struct SimpleImageView: View {
    let photo: PhotoItem
    
    var body: some View {
        HighResAsyncImageView(fileName: photo.fileName)
    }
}
