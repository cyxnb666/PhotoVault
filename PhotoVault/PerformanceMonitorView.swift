import SwiftUI

// MARK: - 简化的性能监控视图
struct PerformanceMonitorView: View {
    @State private var stats: [String: Any] = [:]
    
    var body: some View {
        NavigationView {
            List {
                systemSection
                performanceSection
                controlSection
            }
            .navigationTitle("Performance")
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
    
    private var performanceSection: some View {
        Section("Performance") {
            if let successCount = stats["metal_success_count"] as? Int,
               let failureCount = stats["metal_failure_count"] as? Int {
                
                HStack {
                    Label("GPU Accelerated", systemImage: "bolt")
                    Spacer()
                    Text("\(successCount)")
                        .foregroundColor(.green)
                }
                
                HStack {
                    Label("CPU Fallback", systemImage: "cpu")
                    Spacer()
                    Text("\(failureCount)")
                        .foregroundColor(.orange)
                }
                
                if let successRate = stats["metal_success_rate"] as? Double {
                    HStack {
                        Label("GPU Success Rate", systemImage: "percent")
                        Spacer()
                        Text("\(Int(successRate * 100))%")
                            .foregroundColor(successRate > 0.8 ? .green : .orange)
                    }
                }
            }
            
            if let avgTime = stats["avg_metal_time_ms"] as? Double, avgTime > 0 {
                HStack {
                    Label("Avg Processing Time", systemImage: "clock")
                    Spacer()
                    Text("\(Int(avgTime))ms")
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private var controlSection: some View {
        Section("Controls") {
            Button(action: {
                ImageCache.shared.clearCache()
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
        stats = ImageCache.shared.getPerformanceStats()
    }
}

// MARK: - 简化的性能监控按钮
struct PerformanceMonitorButton: View {
    @State private var showingMonitor = false
    
    var body: some View {
        Button {
            showingMonitor = true
        } label: {
            Image(systemName: "speedometer")
                .font(.title2)
        }
        .sheet(isPresented: $showingMonitor) {
            PerformanceMonitorView()
        }
    }
}

// MARK: - 简单的状态指示器
struct StatusBadge: View {
    let isMetalEnabled: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isMetalEnabled ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(isMetalEnabled ? "GPU" : "CPU")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

#Preview {
    PerformanceMonitorView()
}
