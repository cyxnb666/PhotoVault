import SwiftUI

// MARK: - Fixed Optimized Filmstrip View (Updated for EnhancedImageCache)
struct OptimizedFilmstripView: View {
    let photos: [PhotoItem]
    @Binding var currentIndex: Int
    
    @State private var hapticFeedback = UIImpactFeedbackGenerator(style: .light)
    @State private var lastHapticIndex = -1
    @State private var isDragging = false
    @State private var dragStartIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var animationID = UUID() // 用于避免动画冲突
    
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
                    // 使用现有的 ThumbnailView，但控制其动画
                    ThumbnailView(
                        fileName: photo.fileName,
                        size: thumbnailSize,
                        isSelected: index == currentIndex
                    )
                    // 在这里控制动画，避免传递 isDragging 参数
                    .scaleEffect(index == currentIndex ? 1.0 : 0.85)
                    .animation(
                        isDragging ? .none : .easeInOut(duration: 0.2),
                        value: currentIndex
                    )
                    .onTapGesture {
                        // 点击缩略图直接跳转（只在非拖拽状态下）
                        if !isDragging {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentIndex = index
                                animationID = UUID() // 更新动画ID
                            }
                        }
                    }
                }
                
                Spacer().frame(width: leadingPadding)
            }
            .offset(x: calculateScrollOffset(itemWidth: itemWidth))
            .id(animationID) // 使用ID来重置动画状态
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
    
    // MARK: - 位置计算（修复动画冲突）
    private func calculateScrollOffset(itemWidth: CGFloat) -> CGFloat {
        if isDragging {
            // 拖拽时：基础位置 + 拖拽偏移（无动画）
            let basePosition = -CGFloat(dragStartIndex) * itemWidth
            return basePosition + dragOffset
        } else {
            // 非拖拽时：根据当前索引计算位置（带动画）
            return -CGFloat(currentIndex) * itemWidth
        }
    }
    
    // MARK: - 手势覆盖层
    private func dragGestureOverlay(itemWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .simultaneousGesture( // 使用simultaneousGesture避免冲突
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        handleDragChanged(value, itemWidth: itemWidth)
                    }
                    .onEnded { value in
                        handleDragEnded(value, itemWidth: itemWidth)
                    }
            )
    }
    
    // MARK: - 修复的手势处理
    private func handleDragChanged(_ value: DragGesture.Value, itemWidth: CGFloat) {
        if !isDragging {
            startDragging()
        }
        
        // 更新拖拽偏移（不使用动画）
        dragOffset = value.translation.width
        
        // 计算目标索引（减少频繁更新）
        let indexChange = -value.translation.width / itemWidth
        let targetIndex = dragStartIndex + Int(round(indexChange))
        let newIndex = max(0, min(photos.count - 1, targetIndex))
        
        // 只在索引真正改变且变化幅度足够大时更新
        let minimumDragDistance: CGFloat = itemWidth * 0.3 // 需要拖拽30%的距离才触发
        if newIndex != currentIndex && abs(value.translation.width) > minimumDragDistance {
            // 使用无动画的方式更新索引
            currentIndex = newIndex
            provideTactileFeedback(for: newIndex)
        }
    }
    
    private func handleDragEnded(_ value: DragGesture.Value, itemWidth: CGFloat) {
        let velocity = value.predictedEndTranslation.width
        
        // 基于速度和距离的最终调整
        let dragDistance = value.translation.width
        let indexChange = -dragDistance / itemWidth
        var targetIndex = dragStartIndex + Int(round(indexChange))
        
        // 速度补偿：高速滑动时额外移动一格
        if abs(velocity) > 500 { // 降低速度阈值避免误触
            let velocityDirection = velocity > 0 ? -1 : 1
            targetIndex += velocityDirection
        }
        
        // 确保索引在有效范围内
        targetIndex = max(0, min(photos.count - 1, targetIndex))
        
        // 更新最终索引
        currentIndex = targetIndex
        
        // 结束拖拽，触发最终动画
        finishDragging()
    }
    
    // MARK: - 状态管理（修复动画）
    private func startDragging() {
        // 准备触觉反馈
        hapticFeedback.prepare()
        lastHapticIndex = currentIndex
        
        // 无动画地进入拖拽状态
        isDragging = true
        dragStartIndex = currentIndex
        dragOffset = 0
    }
    
    private func finishDragging() {
        // 使用单一、平滑的动画回到最终位置
        withAnimation(.easeOut(duration: 0.3)) {
            isDragging = false
            dragOffset = 0
            animationID = UUID() // 更新动画ID，重置动画状态
        }
        
        // 重置触觉反馈状态
        lastHapticIndex = -1
        
        // 延迟预加载，避免动画期间的性能问题
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
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
    
    // MARK: - 预加载 (更新为使用 EnhancedImageCache)
    private func preloadNearbyThumbnails() {
        let range = max(0, currentIndex - 3)...min(photos.count - 1, currentIndex + 3)
        let nearbyPhotos = range.map { photos[$0].fileName }
        
        // 🔄 使用 EnhancedImageCache 替代 ImageCache
        for fileName in nearbyPhotos {
            EnhancedImageCache.shared.getThumbnail(
                for: fileName,
                size: CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)
            ) { _ in
                // 预加载，不需要处理结果
            }
        }
    }
}
