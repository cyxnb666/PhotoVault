import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Models
struct PhotoItem: Identifiable, Hashable, Codable {
    let id = UUID()
    let fileName: String
    
    var image: UIImage? {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let imagePath = documentsPath.appendingPathComponent(fileName)
        guard let imageData = try? Data(contentsOf: imagePath) else {
            return nil
        }
        return UIImage(data: imageData)
    }
    
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
        
        if let imageData = image.jpegData(compressionQuality: 0.8) {
            try? imageData.write(to: imagePath)
        }
    }
    
    func deleteImageFile() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let imagePath = documentsPath.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: imagePath)
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

// MARK: - View Model
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
    
    private func loadSavedPhotos() {
        guard let savedFileNames = UserDefaults.standard.array(forKey: photosKey) as? [String] else {
            return
        }
        
        let loadedPhotos = savedFileNames.compactMap { fileName -> PhotoItem? in
            let photoItem = PhotoItem(fileName: fileName)
            // 验证文件是否存在
            return photoItem.image != nil ? photoItem : nil
        }
        
        self.photos = loadedPhotos
    }
    
    func loadPhotosFromFolder(at url: URL) {
        Task {
            var newPhotos: [PhotoItem] = []
            
            // 开始访问安全范围资源
            guard url.startAccessingSecurityScopedResource() else {
                print("无法访问所选文件夹")
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            do {
                // 获取文件夹中的所有内容
                let fileManager = FileManager.default
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])
                
                // 支持的图片格式
                let supportedImageTypes: [UTType] = [.jpeg, .png, .heic, .gif, .bmp, .tiff]
                
                for fileURL in contents {
                    // 检查文件类型是否为图片
                    if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentTypeKey]),
                       let contentType = resourceValues.contentType,
                       supportedImageTypes.contains(where: { contentType.conforms(to: $0) }) {
                        
                        // 读取图片数据
                        if let imageData = try? Data(contentsOf: fileURL),
                           let image = UIImage(data: imageData) {
                            let photoItem = PhotoItem(image: image)
                            newPhotos.append(photoItem)
                        }
                    }
                }
                
                await MainActor.run {
                    self.photos.append(contentsOf: newPhotos)
                    self.savePhotos() // 保存到本地
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
    
    func selectPhoto(_ photo: PhotoItem) {
        selectedPhotoItem = photo
        showingImageDetail = true
        // 进入图片详细视图时退出选择模式
        if isSelectionMode {
            isSelectionMode = false
            selectedPhotos.removeAll()
        }
    }
    
    func showDocumentPicker() {
        showingDocumentPicker = true
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
                        EmptyView()
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
    
    var isSelected: Bool {
        viewModel.selectedPhotos.contains(photo)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if let image = photo.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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
                } else {
                    // 占位图片，如果图片加载失败
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .cornerRadius(12)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                                .font(.title)
                        )
                }
                
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

// MARK: - Simple Image View
struct SimpleImageView: View {
    let photo: PhotoItem
    
    var body: some View {
        GeometryReader { geometry in
            if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                // 占位图片，如果图片加载失败
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                            .font(.system(size: 60))
                    )
            }
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
                            if !photos.isEmpty && currentIndex >= 0 && currentIndex < photos.count {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(currentIndex, anchor: .center)
                                }
                            }
                        }
                    }
                    .onChange(of: currentIndex) { newIndex in
                        // 当外部改变currentIndex时，滚动到对应位置
                        if !isDragging {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if !photos.isEmpty && newIndex >= 0 && newIndex < photos.count {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        proxy.scrollTo(newIndex, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: photos.count) { _ in
                        // 当照片数组发生变化时，确保 currentIndex 在有效范围内
                        DispatchQueue.main.async {
                            validateCurrentIndex()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if !photos.isEmpty && currentIndex >= 0 && currentIndex < photos.count {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        proxy.scrollTo(currentIndex, anchor: .center)
                                    }
                                }
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
                                    if newIndex != currentIndex && newIndex < photos.count {
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
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        if !photos.isEmpty && currentIndex >= 0 && currentIndex < photos.count {
                                            withAnimation(.easeInOut(duration: 0.3)) {
                                                proxy.scrollTo(currentIndex, anchor: .center)
                                            }
                                        }
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
    
    private func validateCurrentIndex() {
        if photos.isEmpty {
            currentIndex = 0
        } else if currentIndex >= photos.count {
            currentIndex = photos.count - 1
        } else if currentIndex < 0 {
            currentIndex = 0
        }
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
        Group {
            if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                // 占位图片，如果图片加载失败
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
        .scaleEffect(isSelected ? 1.0 : 0.85)
        // 拖拽时增强高亮效果
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(isDragging && isSelected ? 0.2 : 0))
        )
        .animation(.easeInOut(duration: isDragging ? 0.1 : 0.2), value: isSelected)
    }
}
