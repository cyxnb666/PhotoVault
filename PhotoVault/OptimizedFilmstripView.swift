import SwiftUI

// MARK: - Optimized Filmstrip View with Fixed Animation Conflicts
struct OptimizedFilmstripView: View {
    let photos: [PhotoItem]
    @Binding var currentIndex: Int
    
    @State private var hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    @State private var lastHapticIndex = -1
    @State private var isDragging = false
    @State private var dragStartIndex = 0
    @State private var dragOffset: CGFloat = 0
    
    private let thumbnailSize: CGFloat = 44
    private let spacing: CGFloat = 4
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 主滚动视图
                mainScrollView(geometry: geometry)
                
                // 中心指示器
                centerIndicator
                
                // 渐变遮罩
                gradientMasks
            }
        }
        .frame(height: 60)
    }
    
    // MARK: - 主滚动视图
    private func mainScrollView(geometry: GeometryProxy) -> some View {
        let screenWidth = geometry.size.width
        let leadingPadding = max(0, (screenWidth - thumbnailSize) / 2)
        let itemWidth = thumbnailSize + spacing
        
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                Spacer().frame(width: leadingPadding)
                
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    ThumbnailView(
                        fileName: photo.fileName,
                        size: thumbnailSize,
                        isSelected: index == currentIndex
                    )
                    .scaleEffect(index == currentIndex ? 1.0 : 0.85)
                    .animation(.easeInOut(duration: 0.2), value: currentIndex)
                    .onTapGesture {
                        // 点击缩略图直接跳转
                        if !isDragging {
                            currentIndex = index
                        }
                    }
                }
                
                Spacer().frame(width: leadingPadding)
            }
            .offset(x: calculateScrollOffset(itemWidth: itemWidth))
        }
        .overlay(
            dragGestureOverlay(itemWidth: itemWidth)
        )
        .onChange(of: currentIndex) { _ in
            // 只在非拖拽状态下预加载
            if !isDragging {
                preloadNearbyThumbnails()
            }
        }
    }
    
    // MARK: - 位置计算（避免动画冲突）
    private func calculateScrollOffset(itemWidth: CGFloat) -> CGFloat {
        if isDragging {
            // 拖拽时：基础位置 + 拖拽偏移
            let basePosition = -CGFloat(dragStartIndex) * itemWidth
            return basePosition + dragOffset
        } else {
            // 非拖拽时：根据当前索引计算位置
            return -CGFloat(currentIndex) * itemWidth
        }
    }
    
    // MARK: - 手势覆盖层
    private func dragGestureOverlay(itemWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        handleDragChanged(value, itemWidth: itemWidth)
                    }
                    .onEnded { value in
                        handleDragEnded(value, itemWidth: itemWidth)
                    }
            )
    }
    
    // MARK: - 手势处理（无动画冲突）
    private func handleDragChanged(_ value: DragGesture.Value, itemWidth: CGFloat) {
        if !isDragging {
            startDragging()
        }
        
        // 更新拖拽偏移（不使用动画）
        dragOffset = value.translation.width
        
        // 计算目标索引
        let indexChange = -value.translation.width / itemWidth
        let targetIndex = dragStartIndex + Int(round(indexChange))
        let newIndex = max(0, min(photos.count - 1, targetIndex))
        
        // 只在索引真正改变时更新（避免频繁触发）
        if newIndex != currentIndex {
            currentIndex = newIndex
            provideTactileFeedback(for: newIndex)
        }
    }
    
    private func handleDragEnded(_ value: DragGesture.Value, itemWidth: CGFloat) {
        let velocity = value.predictedEndTranslation.width
        
        // 基于速度的最终调整
        if abs(velocity) > 300 { // 只有很快的滑动才会额外移动
            let direction = velocity > 0 ? -1 : 1
            let newIndex = max(0, min(photos.count - 1, currentIndex + direction))
            currentIndex = newIndex
        }
        
        // 结束拖拽，触发最终动画
        finishDragging()
    }
    
    // MARK: - 状态管理
    private func startDragging() {
        isDragging = true
        dragStartIndex = currentIndex
        dragOffset = 0
        hapticFeedback.prepare()
        lastHapticIndex = currentIndex
    }
    
    private func finishDragging() {
        // 使用单一动画重置到最终位置
        withAnimation(.easeOut(duration: 0.25)) {
            isDragging = false
            dragOffset = 0
        }
        
        lastHapticIndex = -1
        
        // 预加载最终位置附近的缩略图
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            preloadNearbyThumbnails()
        }
    }
    
    private func provideTactileFeedback(for newIndex: Int) {
        if newIndex != lastHapticIndex {
            hapticFeedback.impactOccurred()
            lastHapticIndex = newIndex
        }
    }
    
    // MARK: - UI组件
    private var centerIndicator: some View {
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
    
    private var gradientMasks: some View {
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
    
    // MARK: - 预加载
    private func preloadNearbyThumbnails() {
        let range = max(0, currentIndex - 3)...min(photos.count - 1, currentIndex + 3)
        let nearbyPhotos = range.map { photos[$0].fileName }
        
        ImageCache.shared.preloadThumbnails(
            for: nearbyPhotos,
            size: CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)
        )
    }
}
