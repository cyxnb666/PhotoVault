import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Optimized PhotoItem Model
struct PhotoItem: Identifiable, Hashable, Codable {
    let id = UUID()
    let fileName: String
    
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
        
        // 同步保存图片，确保文件完全写入后再继续
        if let imageData = image.jpegData(compressionQuality: 0.8) {
            try? imageData.write(to: imagePath)
        }
        
        // 立即将图片添加到内存缓存，避免重复读取
        EnhancedImageCache.shared.preloadImageToCache(image: image, fileName: fileName)
        
        // 🆕 新增：预生成所有质量级别的缩略图
        UltraFastThumbnailGenerator.shared.generateAllQualityLevels(from: image, fileName: fileName)
    }
    
    func deleteImageFile() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let imagePath = documentsPath.appendingPathComponent(fileName)
        
        // 从增强缓存中移除
        EnhancedImageCache.shared.removeCachedImage(for: fileName)
        
        // 删除文件
        try? FileManager.default.removeItem(at: imagePath)
    }
    
    // MARK: - 缓存辅助方法
    func loadImageAsync(completion: @escaping (UIImage?) -> Void) {
        EnhancedImageCache.shared.getImageWithSeamlessUpgrade(
            for: fileName,
            onThumbnail: { _ in }, // 忽略缩略图回调
            onHighRes: completion
        )
    }
    
    func loadThumbnail(size: CGSize, completion: @escaping (UIImage?) -> Void) {
        EnhancedImageCache.shared.getThumbnail(for: fileName, size: size, completion: completion)
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

// MARK: - Enhanced Photo Gallery View Model
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
                // 开始智能预加载
                self?.triggerInitialPreload()
            }
        }
    }
    
    // 改进的loadPhotosFromFolder方法，包含进度反馈
    func loadPhotosFromFolder(at url: URL) {
        Task {
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
                
                // 在后台处理所有图片，完成后一次性更新UI
                let processedPhotos = await withTaskGroup(of: PhotoItem?.self, returning: [PhotoItem].self) { group in
                    var results: [PhotoItem] = []
                    
                    for fileURL in contents {
                        if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentTypeKey]),
                           let contentType = resourceValues.contentType,
                           supportedImageTypes.contains(where: { contentType.conforms(to: $0) }) {
                            
                            group.addTask {
                                if let imageData = try? Data(contentsOf: fileURL),
                                   let image = UIImage(data: imageData) {
                                    return PhotoItem(image: image)
                                }
                                return nil
                            }
                        }
                    }
                    
                    for await result in group {
                        if let photoItem = result {
                            results.append(photoItem)
                        }
                    }
                    
                    return results
                }
                
                // 一次性更新UI，避免频繁刷新
                await MainActor.run {
                    self.photos.append(contentsOf: processedPhotos)
                    self.savePhotos()
                    
                    // 触发预加载
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.triggerInitialPreload()
                    }
                }
                
            } catch {
                print("读取文件夹内容时出错: \(error)")
            }
        }
    }
    
    func deletePhoto(_ photo: PhotoItem) {
        photo.deleteImageFile() // 删除本地文件和缓存
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
    
    // 改进的selectPhoto方法，包含智能预加载
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
    
    // MARK: - 🚀 Enhanced Performance Optimization Methods
    
    // 初始预加载
    func triggerInitialPreload() {
        guard !photos.isEmpty else { return }
        
        let fileNames = photos.map { $0.fileName }
        
        // 预加载前20张照片的缩略图
        for (index, fileName) in fileNames.prefix(20).enumerated() {
            EnhancedImageCache.shared.getThumbnail(
                for: fileName,
                size: CGSize(width: 240, height: 240)
            ) { _ in }
        }
        
        // 预加载前10张照片的原图
        EnhancedImageCache.shared.preloadVisiblePhotos(
            fileNames,
            currentIndex: 0,
            visibleRange: 10
        )
    }
    
    // 预加载当前照片附近的高分辨率图片（用于详细视图）
    func preloadNearbyHighResImages(around index: Int) {
        let allFileNames = photos.map { $0.fileName }
        EnhancedImageCache.shared.preloadVisiblePhotos(
            allFileNames,
            currentIndex: index,
            visibleRange: 8
        )
    }
    
    // 清理缓存
    func clearCache() {
        EnhancedImageCache.shared.clearCache()
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

// MARK: - 🚀 无缝升级图片视图
struct SeamlessImageView: View {
    let fileName: String
    let contentMode: ContentMode
    
    @State private var displayImage: UIImage?
    @State private var isHighRes = false
    @State private var loadingTask: Task<Void, Never>?
    
    init(fileName: String, contentMode: ContentMode = .fit) {
        self.fileName = fileName
        self.contentMode = contentMode
    }
    
    var body: some View {
        Group {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .opacity(isHighRes ? 1.0 : 0.9) // 高分辨率时完全不透明
                    .animation(.easeInOut(duration: 0.3), value: isHighRes)
            } else {
                // 加载中的占位符
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                            
                            Text("Loading...")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                    )
            }
        }
        .onAppear {
            loadImageSeamlessly()
        }
        .onDisappear {
            cancelLoading()
        }
        .onChange(of: fileName) { _ in
            cancelLoading()
            loadImageSeamlessly()
        }
    }
    
    private func loadImageSeamlessly() {
        loadingTask = Task {
            await MainActor.run {
                displayImage = nil
                isHighRes = false
            }
            
            // 使用增强缓存的无缝加载功能
            EnhancedImageCache.shared.getImageWithSeamlessUpgrade(
                for: fileName,
                thumbnailSize: CGSize(width: 600, height: 600), // 使用较大的缩略图作为占位符
                onThumbnail: { thumbnailImage in
                    if !Task.isCancelled {
                        self.displayImage = thumbnailImage
                        self.isHighRes = false
                    }
                },
                onHighRes: { highResImage in
                    if !Task.isCancelled && highResImage != nil {
                        self.displayImage = highResImage
                        self.isHighRes = true
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

// MARK: - 🎯 智能预加载网格视图
struct SmartPreloadGridView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    @State private var visiblePhotos: Set<String> = []
    
    let columns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(Array(viewModel.photos.enumerated()), id: \.element.id) { index, photo in
                    SmartGridCell(photo: photo, index: index)
                        .onAppear {
                            handlePhotoAppeared(photo: photo, index: index)
                        }
                        .onDisappear {
                            handlePhotoDisappeared(photo: photo)
                        }
                }
            }
            .padding(4)
        }
        .onAppear {
            // 初始预加载
            viewModel.triggerInitialPreload()
        }
    }
    
    private func handlePhotoAppeared(photo: PhotoItem, index: Int) {
        visiblePhotos.insert(photo.fileName)
        
        // 触发智能预加载
        let allFileNames = viewModel.photos.map { $0.fileName }
        EnhancedImageCache.shared.preloadVisiblePhotos(
            allFileNames,
            currentIndex: index,
            visibleRange: 8 // 预加载当前位置前后8张照片的原图
        )
    }
    
    private func handlePhotoDisappeared(photo: PhotoItem) {
        visiblePhotos.remove(photo.fileName)
    }
}

// MARK: - 🔥 高性能网格单元格
struct SmartGridCell: View {
    let photo: PhotoItem
    let index: Int
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    var isSelected: Bool {
        viewModel.selectedPhotos.contains(photo)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // 🔄 替换 AsyncImageView 为 ZeroDelayImageView
                ZeroDelayImageView(
                    fileName: photo.fileName,
                    targetSize: CGSize(
                        width: geometry.size.width * 2,
                        height: geometry.size.height * 2
                    )
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped() // 🔧 重要：确保裁剪超出部分
                .cornerRadius(12)
                .onTapGesture {
                    if viewModel.isSelectionMode {
                        viewModel.togglePhotoSelection(photo)
                    } else {
                        // 点击时立即预加载附近照片的原图
                        preloadNearbyHighResImages()
                        viewModel.selectPhoto(photo)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(viewModel.isSelectionMode && isSelected ? 0.3 : 0))
                )
                .overlay(
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
    
    private func preloadNearbyHighResImages() {
        let allFileNames = viewModel.photos.map { $0.fileName }
        EnhancedImageCache.shared.preloadVisiblePhotos(
            allFileNames,
            currentIndex: index,
            visibleRange: 5 // 预加载当前照片前后5张的原图
        )
    }
}

// MARK: - ⚡ 优化的详细视图
struct OptimizedImageDetailView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    @State private var currentIndex: Int = 0
    @State private var dragOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if viewModel.photos.isEmpty {
                Color.clear
                    .onAppear {
                        viewModel.showingImageDetail = false
                    }
            } else {
                VStack {
                    Spacer()
                    
                    // 使用无缝升级的图片视图
                    TabView(selection: $currentIndex) {
                        ForEach(Array(viewModel.photos.enumerated()), id: \.element.id) { index, photo in
                            ZeroDelayImageView(
                                fileName: photo.fileName,
                                targetSize: CGSize(width: 800, height: 600)
                            )
                            .aspectRatio(contentMode: .fit) // 🔧 详细视图使用 .fit 以显示完整图片
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .scaleEffect(scale)
                    .offset(x: dragOffset.width, y: dragOffset.height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.height > 0 {
                                    dragOffset = value.translation
                                    let dragProgress = min(value.translation.height / 200, 1.0)
                                    scale = 1.0 - (dragProgress * 0.3)
                                }
                            }
                            .onEnded { value in
                                if value.translation.height > 100 {
                                    viewModel.showingImageDetail = false
                                } else {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        dragOffset = .zero
                                        scale = 1.0
                                    }
                                }
                            }
                    )
                    .onAppear {
                        updateCurrentIndex()
                        triggerAdvancedPreload()
                    }
                    .onChange(of: currentIndex) { newIndex in
                        // 切换照片时预加载附近照片
                        triggerAdvancedPreload()
                    }
                    .onChange(of: viewModel.photos) { _ in
                        updateCurrentIndex()
                    }
                    
                    Spacer()
                    
                    // 优化的缩略图条
                    OptimizedFilmstripView(
                        photos: viewModel.photos,
                        currentIndex: $currentIndex
                    )
                    .opacity(1.0 - min(dragOffset.height / 100, 1.0))
                    .padding(.bottom, 50)
                }
            }
        }
    }
    
    private func updateCurrentIndex() {
        // 添加延迟检查，给数组更新时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !self.viewModel.photos.isEmpty else {
                self.viewModel.showingImageDetail = false
                return
            }
            
            if let selectedPhoto = self.viewModel.selectedPhotoItem,
               let newIndex = self.viewModel.photos.firstIndex(where: { $0.id == selectedPhoto.id }) {
                self.currentIndex = newIndex
            } else {
                if self.currentIndex >= self.viewModel.photos.count {
                    self.currentIndex = max(0, self.viewModel.photos.count - 1)
                }
                if self.currentIndex < self.viewModel.photos.count {
                    self.viewModel.selectedPhotoItem = self.viewModel.photos[self.currentIndex]
                }
            }
        }
    }
    
    private func triggerAdvancedPreload() {
        let allFileNames = viewModel.photos.map { $0.fileName }
        
        // 预加载当前照片前后10张的原图
        EnhancedImageCache.shared.preloadVisiblePhotos(
            allFileNames,
            currentIndex: currentIndex,
            visibleRange: 10
        )
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
                            // 性能监控按钮
                            EnhancedPerformanceButton()
                            
                            // 状态指示器
                            StatusBadge(isMetalEnabled: MetalImageProcessor.isSupported)
                        }
                    }
                }
                
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

// MARK: - Photo Grid View (使用智能预加载)
struct PhotoGridView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    var body: some View {
        SmartPreloadGridView()
            .environmentObject(viewModel)
    }
}

// MARK: - Image Detail View (使用无缝加载)
struct ImageDetailView: View {
    @EnvironmentObject var viewModel: PhotoGalleryViewModel
    
    var body: some View {
        OptimizedImageDetailView()
            .environmentObject(viewModel)
    }
}

// MARK: - 📊 增强性能监控按钮
struct EnhancedPerformanceButton: View {
    @State private var showingMonitor = false
    
    var body: some View {
        Button {
            showingMonitor = true
        } label: {
            Image(systemName: "speedometer")
                .font(.title2)
        }
        .sheet(isPresented: $showingMonitor) {
            EnhancedPerformanceView()
        }
    }
}

struct EnhancedPerformanceView: View {
    @State private var stats: [String: Any] = [:]
    
    var body: some View {
        NavigationView {
            List {
                systemSection
                cacheSection
                performanceSection
                controlSection
            }
            .navigationTitle("Performance Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                updateStats()
            }
        }
    }
    
    private var systemSection: some View {
        Section("System") {
            HStack {
                Label("Metal Support", systemImage: "cpu")
                Spacer()
                if stats["metal_supported"] as? Bool == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            
            if let deviceName = stats["device_name"] as? String {
                HStack {
                    Label("Device", systemImage: "display")
                    Spacer()
                    Text(deviceName)
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        }
    }
    
    private var cacheSection: some View {
        Section("Smart Cache") {
            if let hitCount = stats["cache_hit_count"] as? Int,
               let missCount = stats["cache_miss_count"] as? Int {
                
                HStack {
                    Label("Cache Hits", systemImage: "checkmark.circle")
                    Spacer()
                    Text("\(hitCount)")
                        .foregroundColor(.green)
                }
                
                HStack {
                    Label("Cache Misses", systemImage: "xmark.circle")
                    Spacer()
                    Text("\(missCount)")
                        .foregroundColor(.orange)
                }
                
                if let hitRate = stats["cache_hit_rate"] as? Double {
                    HStack {
                        Label("Hit Rate", systemImage: "percent")
                        Spacer()
                        Text("\(Int(hitRate * 100))%")
                            .foregroundColor(hitRate > 0.8 ? .green : .orange)
                    }
                }
            }
            
            if let preloadingCount = stats["preloading_count"] as? Int {
                HStack {
                    Label("Preloading", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("\(preloadingCount)")
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private var performanceSection: some View {
        Section("Performance") {
            HStack {
                Label("Seamless Upgrades", systemImage: "bolt.circle")
                Spacer()
                Text("Enabled")
                    .foregroundColor(.green)
            }
            
            HStack {
                Label("Smart Preloading", systemImage: "brain")
                Spacer()
                Text("Active")
                    .foregroundColor(.green)
            }
        }
    }
    
    private var controlSection: some View {
        Section("Controls") {
            Button(action: {
                EnhancedImageCache.shared.clearCache()
                updateStats()
            }) {
                Label("Clear Cache", systemImage: "trash")
                    .foregroundColor(.red)
            }
            
            Button(action: {
                updateStats()
            }) {
                Label("Refresh Stats", systemImage: "arrow.clockwise")
            }
        }
    }
    
    private func updateStats() {
        stats = EnhancedImageCache.shared.getPerformanceStats()
    }
}

// StatusBadge 已在 PerformanceMonitorView.swift 中定义
