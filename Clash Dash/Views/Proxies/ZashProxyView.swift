import SwiftUI

struct ZashProxyView: View {
    let server: ClashServer
    @StateObject private var viewModel: ProxyViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedGroup: ProxyGroup?
    @AppStorage("allowManualURLTestGroupSwitch") private var allowManualURLTestGroupSwitch = false
    @State private var showURLTestAlert = false
    @State private var cachedColumns: [GridItem] = []
    @State private var lastWidth: CGFloat = 0
    @State private var isLoaded = false
    
    // 添加内存缓存优化
    @State private var cachedGridColumnWidth: CGFloat = 0
    @State private var cachedGridColumns: [GridItem] = []
    @State private var cachedCardWidths: [String: CGFloat] = [:]
    
    @State private var isUpdating = false
    @State private var showingUpdateSuccess = false
    @State private var showingSheet = false
    @State private var cardSize: (width: CGFloat, height: CGFloat) = (width: 160, height: 90)
    @State private var rotation: Double = 0
    
    init(server: ClashServer) {
        self.server = server
        self._viewModel = StateObject(wrappedValue: ProxyViewModel(server: server))
        
    }
    
    var body: some View {
        
        
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.groups.isEmpty {
                        LoadingView()
                            .id("loading-view")
                    } else {
                        // 使用优化的渲染策略
                        VStack(spacing: 8) {
                            // 分开渲染代理组网格和提供者网格，减少一次性渲染的视图数量
                            groupsGridView(width: geometry.size.width)
                                .padding(.bottom, 8)
                                .id("groups-section-\(geometry.size.width)")
                            
                            // 代理提供者部分 - 使用LazyVStack延迟加载
                            if !UserDefaults.standard.bool(forKey: "hideProxyProviders") {
                                LazyVStack {
                                    providersGridView(width: geometry.size.width)
                                }
                                .id("providers-lazy-section-\(geometry.size.width)")
                            }
                        }
                        .id("main-content-\(geometry.size.width)")
                    }
                }
                .padding(.vertical, 12)
                .opacity(1.0)
                .id("root-stack")
            }
            .background(Color(.systemGroupedBackground).edgesIgnoringSafeArea(.all))
            .scrollDismissesKeyboard(.immediately)
            .id("scroll-view")
        }
        .refreshable {
            
            await refreshData()
        }
        .task {
            
            await loadData()
        }
        .sheet(item: $selectedGroup) { group in
            NavigationStack {
                ZashGroupDetailView(
                    group: group,
                    viewModel: viewModel
                )
                .transition(.opacity)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .background(Color(.systemBackground))
        }
        .alert("自动测速选择分组", isPresented: $showURLTestAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("该分组不支持手动切换节点，可在全局设置中启用手动切换")
        }
        // 使用稳定的ID，避免不必要的重新渲染
        .id("proxy-view-\(server.name)")
    }
    
    // 代理组网格视图
    @ViewBuilder
    private func groupsGridView(width: CGFloat) -> some View {
        
        let columns = getColumns(availableWidth: width)
        
        // 使用ID参数提高重用效率
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(viewModel.getSortedGroups(), id: \.self) { group in
                // 判断当前组是否被选中
                let isSelected = selectedGroup?.name == group.name
                
                ZashGroupCard(group: group, viewModel: viewModel, containerWidth: width, isSelected: isSelected)
                    .onTapGesture {
                        HapticManager.shared.impact(.light)
                        selectedGroup = group
                    }
                    // 使用更稳定的ID策略，减少重新渲染
                    .id("\(group.name)-\(group.now)-\(isSelected ? "selected" : "normal")")
            }
        }
        .padding(.horizontal, 12)
        // 添加光栅化以提高滑动性能
        .drawingGroup(opaque: false)
        // 使用稳定的ID，避免不必要的重新渲染
        .id("groups-grid-\(width)-\(viewModel.lastUpdated.timeIntervalSince1970)")
    }
    
    // 代理提供者网格视图
    @ViewBuilder
    private func providersGridView(width: CGFloat) -> some View {
        
        let httpProviders = viewModel.providers
            .filter { ["HTTP", "FILE"].contains($0.vehicleType.uppercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        if !httpProviders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("代理提供者")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .id("providers-title")
                
                let columns = getColumns(availableWidth: width)
                
                // 使用ID参数提高重用效率
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(httpProviders, id: \.name) { provider in
                        let nodes = viewModel.providerNodes[provider.name] ?? []
                        let updatedAt = provider.updatedAt ?? ""
                        ZashProviderCard(
                            provider: provider,
                            nodes: nodes,
                            viewModel: viewModel,
                            containerWidth: width
                        )
                        // 使用更稳定的ID策略，减少重新渲染
                        .id("\(provider.name)-\(updatedAt)-\(nodes.count)")
                    }
                }
                .padding(.horizontal, 12)
                // 添加光栅化以提高滑动性能
                .drawingGroup(opaque: false)
                // 使用稳定的ID，避免不必要的重新渲染
                .id("providers-grid-\(width)")
            }
            // 使用稳定的ID，避免不必要的重新渲染
            .id("providers-section-\(width)")
        }
    }
    
    // 优化列计算逻辑，缓存计算结果
    private func getColumns(availableWidth: CGFloat) -> [GridItem] {
        // 如果宽度没有变化，直接使用缓存的结果
        if abs(availableWidth - lastWidth) < 1 && !cachedColumns.isEmpty {
            return cachedColumns
        }
        
        
        
        // 重新计算列
        let horizontalPadding: CGFloat = 24
        let spacing: CGFloat = 8
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let width = availableWidth - horizontalPadding
        let optimalColumnCount = max(2, Int(width / (minCardWidth + spacing)))
        let cardWidth = min(maxCardWidth, (width - (CGFloat(optimalColumnCount - 1) * spacing)) / CGFloat(optimalColumnCount))
        
        let newColumns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: optimalColumnCount)
        
        // 避免在视图更新过程中直接修改状态
        // 使用异步更新避免在渲染过程中修改状态
        DispatchQueue.main.async {
            self.lastWidth = availableWidth
            self.cachedColumns = newColumns
        }
        
        return newColumns
    }
    
    // 加载数据
    private func loadData() async {
        
        // 重置加载状态但不影响视图显示
        isLoaded = true
        
        // 获取代理数据
        await viewModel.fetchProxies()
    }
    
    // 刷新数据
    private func refreshData() async {
        
        await viewModel.fetchProxies()
    }
    
    // 缓存生成的网格列
    private func calculateGridColumns(for width: CGFloat) -> [GridItem] {
        // 如果宽度未变化且已缓存列，直接返回缓存
        if width == cachedGridColumnWidth && !cachedGridColumns.isEmpty {
            return cachedGridColumns
        }
        
        
        
        let columnWidth: CGFloat = width >= 700 ? 320 : 300
        let columns = max(1, Int(width / columnWidth))
        let calculatedColumns = Array(repeating: GridItem(.flexible(), spacing: 16), count: columns)
        
        // 更新缓存
        cachedGridColumnWidth = width
        cachedGridColumns = calculatedColumns
        
        return calculatedColumns
    }
    
    // 获取或计算卡片宽度
    private func getCardWidth(for id: String, in size: CGSize) -> CGFloat {
        if let cachedWidth = cachedCardWidths[id] {
            return cachedWidth
        }
        
        
        
        let columns = calculateGridColumns(for: size.width)
        let spacing: CGFloat = 16
        let horizontalPadding: CGFloat = 24
        let width = (size.width - (spacing * CGFloat(columns.count - 1)) - (horizontalPadding * 2)) / CGFloat(columns.count)
        
        // 更新缓存
        cachedCardWidths[id] = width
        
        return width
    }
}

// Zash 样式的代理组卡片 - 简化版本
struct ZashGroupCard: View {
    let group: ProxyGroup
    @ObservedObject var viewModel: ProxyViewModel
    let containerWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("lowDelayThreshold") private var lowDelayThreshold = 240
    @AppStorage("mediumDelayThreshold") private var mediumDelayThreshold = 500
    // 添加选中状态属性
    var isSelected: Bool = false
    
    // 添加固定卡片高度 - 预渲染优化
    private let cardHeight: CGFloat = 90
    
    // 优化计算，减少频繁计算
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground)
    }
    
    // 使用计算属性替代状态变量和onAppear更新
    private var groupTypeText: String {
        let result = getGroupTypeText(group.type)
        
        return result
    }
    
    // 添加辅助函数来获取代理组类型的显示文本
    private func getGroupTypeText(_ type: String) -> String {
        switch type.lowercased() {
        case "relay":
            return "链式代理"
        case "load-balance", "loadbalance":
            return "负载均衡"
        case "fallback":
            return "自动回退"
        case "select", "selector":
            return "手动选择"
        case "url-test", "urltest":
            return "自动选择"
        default:
            return type
        }
    }
    
    var body: some View {
        // 计算卡片尺寸（只在初始化和宽度变化时计算）
        let dimensions = calculateCardDimensions(containerWidth: containerWidth)
        
        
        HStack(spacing: 12) {
            // 左侧内容区域
            VStack(alignment: .leading, spacing: 4) {
                // 主标题
                Text(group.name)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .id("title-\(group.name)")
                
                // 副标题（当前选中的节点）
                if group.type == "LoadBalance" {
                    Text("负载均衡")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .id("subtitle-loadbalance-\(group.name)")
                } else {
                    Text(group.now)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .id("subtitle-node-\(group.name)-\(group.now)")
                }
                
                // 类型 - 使用计算属性替代缓存的类型文本
                Text(groupTypeText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .id("type-\(group.name)-\(groupTypeText)")
            }
            .id("content-\(group.name)")
            
            Spacer()
                .id("spacer-\(group.name)")
            
            // 右侧图标
            if let iconUrl = group.icon, !iconUrl.isEmpty {
                CachedAsyncImage(url: iconUrl)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .id("icon-\(group.name)-\(iconUrl)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: dimensions.width, height: dimensions.height)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray4).opacity(colorScheme == .dark ? 0.4 : 0.2), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
                .id("border-\(group.name)")
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.1 : 0.03),
            radius: 2,
            x: 0,
            y: 1
        )
        .frame(height: cardHeight) // 设置固定高度
        // 添加光栅化以提高滑动性能
        .drawingGroup(opaque: false)
        // 使用更稳定的ID策略，确保当选中的节点变化时视图会更新
        .id("\(group.name)-\(group.now)-\(isSelected ? "selected" : "normal")")
    }
    
    // 优化尺寸计算，减少不必要的计算
    private func calculateCardDimensions(containerWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let horizontalPadding: CGFloat = 24
        let spacing: CGFloat = 8
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let width = containerWidth - horizontalPadding
        let optimalColumnCount = max(2, Int(width / (minCardWidth + spacing)))
        let cardWidth = min(maxCardWidth, (width - (CGFloat(optimalColumnCount - 1) * spacing)) / CGFloat(optimalColumnCount))
        
        return (width: cardWidth, height: 90)
    }
}

// 添加一个新的视图组件来处理提供者详情
private struct ProviderDetailView: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 详细信息卡片
                InfoCard(provider: provider)
                
                // 节点列表
                NodesGrid(provider: provider, nodes: nodes, viewModel: viewModel)
            }
            .padding()
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await viewModel.healthCheckProvider(providerName: provider.name)
                    }
                } label: {
                    Label("测速", systemImage: "bolt.horizontal")
                }
            }
            
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }
}

// 提供者信息卡片
private struct InfoCard: View {
    let provider: Provider
    
    var body: some View {
        // 使用ZashInfoCard替代旧的实现
        ZashInfoCard(provider: provider)
    }
}

// 流量信息组件 - 删除，已内联到ZashInfoCard
private struct TrafficInfo: View {
    let info: SubscriptionInfo
    
    var body: some View {
        HStack {
            Text("流量剩余")
                .font(.headline)
            Spacer()
            let usedBytes = formatBytes(Int64(info.upload + info.download))
            let totalBytes = formatBytes(info.total)
            Text("\(usedBytes) / \(totalBytes)")
                .foregroundStyle(.secondary)
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        
        if gb >= 1 {
            return String(format: "%.0fGB", gb)
        } else if mb >= 1 {
            return String(format: "%.0fMB", mb)
        } else if kb >= 1 {
            return String(format: "%.0fKB", kb)
        } else {
            return "\(bytes)B"
        }
    }
}

// 到期时间组件 - 删除，已内联到ZashInfoCard
private struct ExpirationInfo: View {
    let timestamp: Int64
    
    var body: some View {
        HStack {
            Text("到期时间")
                .font(.headline)
            Spacer()
            Text(formatExpireDate(timestamp))
                .foregroundStyle(.secondary)
        }
    }
    
    private func formatExpireDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// 更新时间组件 - 删除，已内联到ZashInfoCard
private struct UpdateTimeInfo: View {
    let updatedAt: String
    
    var body: some View {
        HStack {
            Text("更新时间")
                .font(.headline)
            Spacer()
            if let updateDate = parseDate(updatedAt) {
                Text(formatRelativeTime(updateDate))
                    .foregroundStyle(.secondary)
            } else {
                Text("未知")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString)
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// 节点网格组件
private struct NodesGrid: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedColumns: [GridItem] = []
    @State private var lastScreenWidth: CGFloat = 0
    
    var body: some View {
        if nodes.isEmpty {
            Text("没有找到节点")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            LazyVGrid(columns: getColumns(), spacing: 12) {
                ForEach(nodes) { node in
                    ZashNodeCardOptimized(
                        nodeName: node.name,
                        node: node,
                        isSelected: false,
                        isTesting: viewModel.testingNodes.contains(node.name),
                        viewModel: viewModel,
                        onTap: {
                            handleNodeTap(nodeName: node.name)
                        }
                    )
                    .id("\(node.name)-\(viewModel.testingNodes.contains(node.name))")
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func getColumns() -> [GridItem] {
        let screenWidth = UIScreen.main.bounds.width
        
        // 如果屏幕宽度没有变化，使用缓存的结果
        if abs(screenWidth - lastScreenWidth) < 1 && !cachedColumns.isEmpty {
            return cachedColumns
        }
        
        
        
        let spacing: CGFloat = 12
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let columnsCount = max(2, Int(screenWidth / (minCardWidth + spacing * 2)))
        let newColumns = Array(repeating: GridItem(.flexible(minimum: minCardWidth, maximum: maxCardWidth), spacing: spacing), count: columnsCount)
        
        // 避免在视图更新过程中直接修改状态
        DispatchQueue.main.async {
            self.lastScreenWidth = screenWidth
            self.cachedColumns = newColumns
        }
        
        return newColumns
    }
    
    // 处理节点点击
    private func handleNodeTap(nodeName: String) {
        
        HapticManager.shared.impact(.light)
        
        Task {
            await viewModel.healthCheckProviderProxy(
                providerName: provider.name,
                proxyName: nodeName
            )
        }
    }
}

// Zash 样式的代理提供者卡片 - 简化版本
struct ZashProviderCard: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    let containerWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var isUpdating = false
    @State private var showingUpdateSuccess = false
    @State private var showingSheet = false
    @State private var rotation: Double = 0
    
    // 添加计算属性获取最新的提供者数据
    private var currentProvider: Provider {
        viewModel.providers.first { $0.name == provider.name } ?? provider
    }
    
    // 使用计算属性替代状态变量
    private var usageInfo: String? {
        if let info = currentProvider.subscriptionInfo,
           info.total > 0 || info.upload > 0 || info.download > 0 {
            let remaining = max(0, info.total - info.upload - info.download)
            let remainingFormatted = formatBytes(Int64(remaining))
            let totalFormatted = formatBytes(info.total)
            let result = "\(remainingFormatted) / \(totalFormatted)"
            
            return result
        }
        
        return nil
    }
    
    private var remainingPercentage: Double {
        if let info = currentProvider.subscriptionInfo,
           info.total > 0 {
            let result = max(0, min(1.0, 1.0 - Double(info.upload + info.download) / Double(info.total)))
            
            return result
        }
        
        return 1.0
    }
    
    private var updateTimeText: String {
        if let updatedAt = currentProvider.updatedAt,
           let updateDate = parseDate(updatedAt) {
            let result = formatRelativeTime(updateDate) + "更新"
            
            return result
        }
        
        return ""
    }
    
    // 添加固定卡片高度 - 预渲染优化
    private let cardHeight: CGFloat = 90
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground)
    }
    
    // 格式化字节
    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        
        if gb >= 1 {
            return String(format: "%.0fGB", gb)
        } else if mb >= 1 {
            return String(format: "%.0fMB", mb)
        } else if kb >= 1 {
            return String(format: "%.0fKB", kb)
        } else {
            return "\(bytes)B"
        }
    }
    
    var body: some View {
        // 计算卡片尺寸
        let dimensions = calculateCardDimensions(containerWidth: containerWidth)
        
        
        // 使用相对定位替代ZStack嵌套
        HStack(spacing: 12) {
            // 左侧内容区域
            VStack(alignment: .leading, spacing: 4) {
                // 提供者名称
                Text(provider.name)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .id("title-\(provider.name)")
                
                // 流量信息
                if let usage = usageInfo {
                    // 合并为单个VStack，减少嵌套
                    Text(usage)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("usage-\(provider.name)-\(usage)")
                    
                    // 添加流量进度条
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // 背景
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(.systemGray5))
                                .frame(height: 4)
                            
                            // 进度 - 剩余流量
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * remainingPercentage, height: 4)
                        }
                    }
                    .frame(height: 4)
                } else {
                    Text("无流量信息")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .id("no-usage-\(provider.name)")
                }
                
                // 更新时间 - 使用计算属性替代缓存的更新时间文本
                if !updateTimeText.isEmpty {
                    Text(updateTimeText)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .id("update-time-\(provider.name)")
                }
            }
            .id("content-\(provider.name)")
            
            Spacer()
                .id("spacer-\(provider.name)")
            
            // 右侧更新按钮
            Button {
                Task {
                    HapticManager.shared.impact(.light)
                    isUpdating = true
                    
                    await withTaskCancellationHandler {
                        await viewModel.updateProxyProvider(providerName: provider.name)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await viewModel.fetchProxies()
                        
                        await MainActor.run {
                            HapticManager.shared.notification(.success)
                            isUpdating = false
                            withAnimation {
                                showingUpdateSuccess = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    showingUpdateSuccess = false
                                }
                            }
                        }
                    } onCancel: {
                        Task { @MainActor in
                            isUpdating = false
                            HapticManager.shared.notification(.error)
                        }
                    }
                }
            } label: {
                Group {
                    if isUpdating {
                        // 替换为更简单的加载指示器实现
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(Color.blue, lineWidth: 2)
                            .frame(width: 16, height: 16)
                            .rotationEffect(Angle(degrees: rotation))
                            .onAppear {
                                withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
                                    rotation = 360
                                }
                            }
                            .id("updating-indicator-\(provider.name)")
                    } else if showingUpdateSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 16, weight: .medium))
                            .id("success-icon-\(provider.name)")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.blue)
                            .font(.system(size: 16, weight: .medium))
                            .id("update-icon-\(provider.name)")
                    }
                }
                .frame(width: 24, height: 24)
                .background(
                    Color(.systemBackground)
                        .clipShape(Circle())
                )
                .id("button-container-\(provider.name)")
            }
            .disabled(isUpdating)
            .zIndex(1)
            .id("update-button-\(provider.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: dimensions.width, height: dimensions.height)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray4).opacity(colorScheme == .dark ? 0.4 : 0.2), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
                .id("border-\(provider.name)")
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.1 : 0.03),
            radius: 2,
            x: 0,
            y: 1
        )
        .scaleEffect(isUpdating ? 0.98 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isUpdating)
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.shared.impact(.light)
            showingSheet = true
        }
        .sheet(isPresented: $showingSheet) {
            NavigationStack {
                ZashProviderDetailView(
                    provider: provider,
                    nodes: nodes,
                    viewModel: viewModel
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .frame(height: cardHeight) // 设置固定高度
        // 添加光栅化以提高滑动性能
        .drawingGroup(opaque: false)
        // 使用更稳定的ID策略，减少重新渲染
        .id("\(provider.name)-\(isUpdating ? "updating" : (showingUpdateSuccess ? "success" : "normal"))")
    }
    
    // 解析日期
    private func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString)
    }
    
    // 格式化相对时间
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    // 优化尺寸计算，减少不必要的计算
    private func calculateCardDimensions(containerWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let horizontalPadding: CGFloat = 24
        let spacing: CGFloat = 8
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let width = containerWidth - horizontalPadding
        let optimalColumnCount = max(2, Int(width / (minCardWidth + spacing)))
        let cardWidth = min(maxCardWidth, (width - (CGFloat(optimalColumnCount - 1) * spacing)) / CGFloat(optimalColumnCount))
        
        return (width: cardWidth, height: 90)
    }
}

// 添加 Zash 风格的节点卡片 - 简化版本
struct ZashNodeCard: View {
    let node: ProxyNode
    @ObservedObject var viewModel: ProxyViewModel
    let containerWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("lowDelayThreshold") private var lowDelayThreshold = 240
    @AppStorage("mediumDelayThreshold") private var mediumDelayThreshold = 500
    
    // 添加固定卡片高度 - 预渲染优化
    private let cardHeight: CGFloat = 90
    
    // 使用计算属性替代状态变量
    private var delayColor: Color {
        if node.history.isEmpty {
            return .gray
        }
        
        let delay = node.history.last?.delay ?? 0
        if delay == 0 {
            return .gray
        } else if delay <= lowDelayThreshold {
            return .green
        } else if delay <= mediumDelayThreshold {
            return .orange
        } else {
            return .red
        }
    }
    
    private var delayText: String {
        if node.history.isEmpty {
            return "N/A"
        }
        
        let delay = node.history.last?.delay ?? 0
        if delay == 0 {
            return "超时"
        } else {
            return "\(delay)ms"
        }
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground)
    }
    
    var body: some View {
        // 计算卡片尺寸
        let dimensions = calculateCardDimensions(containerWidth: containerWidth)
        
        VStack(alignment: .leading, spacing: 4) {
            // 节点名称
            Text(node.name)
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
            
            // 节点类型
            Text(node.type)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            // 延迟信息 - 使用计算属性替代缓存的延迟文本和颜色
            HStack(spacing: 4) {
                Circle()
                    .fill(delayColor)
                    .frame(width: 8, height: 8)
                
                Text(delayText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: dimensions.width, height: dimensions.height)
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray4).opacity(colorScheme == .dark ? 0.4 : 0.2), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.1 : 0.03),
            radius: 2,
            x: 0,
            y: 1
        )
        .frame(height: cardHeight) // 设置固定高度
        // 添加光栅化以提高滑动性能
        .drawingGroup(opaque: false)
    }
    
    // 优化尺寸计算，减少不必要的计算
    private func calculateCardDimensions(containerWidth: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let horizontalPadding: CGFloat = 24
        let spacing: CGFloat = 8
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let width = containerWidth - horizontalPadding
        let optimalColumnCount = max(2, Int(width / (minCardWidth + spacing)))
        let cardWidth = min(maxCardWidth, (width - (CGFloat(optimalColumnCount - 1) * spacing)) / CGFloat(optimalColumnCount))
        
        return (width: cardWidth, height: 90)
    }
}

// 添加 Zash 风格的延迟测试动画 - 简化版本
struct ZashDelayTestingView: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
            
            Text("测速中")
                .font(.system(.caption, design: .rounded))
                .fontWeight(.medium)
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .clipShape(Capsule())
        // 使用较低成本的透明度动画
        .opacity(isAnimating ? 0.7 : 1.0)
        .onAppear {
            // 使用较低频率的动画更新
            withAnimation(
                .easeInOut(duration: 1.0)
                .repeatForever(autoreverses: true)
            ) {
                isAnimating = true
            }
        }
        // 添加drawingGroup以获得更好的渲染性能
        .drawingGroup(opaque: false)
    }
}

// 添加 Zash 风格的提供者详情视图
struct ZashProviderDetailView: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var isLoaded = false
    
    private var filteredNodes: [ProxyNode] {
        if searchText.isEmpty {
            return nodes
        } else {
            return nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 提供者信息卡片
                ZashInfoCard(provider: provider)
                
                // 搜索栏 - 修改样式使其更加明显
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("搜索节点", text: $searchText)
                        .font(.system(.body, design: .rounded))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 3, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(colorScheme == .dark ? Color.gray.opacity(0.5) : Color.blue.opacity(0.2), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
                )
                .padding(.horizontal)
                
                // 节点统计信息
                HStack {
                    Text("共 \(nodes.count) 个节点")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    // 延迟统计
                    let stats = getDelayStats()
                    HStack(spacing: 8) {
                        DelayStatBadge(count: stats.green, color: .green, label: "低延迟")
                        DelayStatBadge(count: stats.yellow, color: .yellow, label: "中延迟")
                        DelayStatBadge(count: stats.orange, color: .orange, label: "高延迟")
                        DelayStatBadge(count: stats.gray, color: .gray, label: "超时")
                    }
                }
                .padding(.horizontal)
                
                // 节点列表
                ZashNodesGrid(
                    provider: provider,
                    nodes: filteredNodes,
                    viewModel: viewModel
                )
            }
            .padding(.vertical)
            // 设置为始终可见
            .opacity(1.0)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await viewModel.healthCheckProvider(providerName: provider.name)
                    }
                } label: {
                    Label("测速", systemImage: "bolt.horizontal")
                }
            }
            
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .onAppear {
            // 直接设置为已加载状态，不使用延迟
            isLoaded = true
        }
    }
    
    // 获取延迟统计
    private func getDelayStats() -> (green: Int, yellow: Int, orange: Int, gray: Int) {
        let lowThreshold = UserDefaults.standard.integer(forKey: "lowDelayThreshold")
        let mediumThreshold = UserDefaults.standard.integer(forKey: "mediumDelayThreshold")
        
        let lowDelay = lowThreshold == 0 ? 240 : lowThreshold
        let mediumDelay = mediumThreshold == 0 ? 500 : mediumThreshold
        
        var green = 0
        var yellow = 0
        var orange = 0
        var gray = 0
        
        for node in nodes {
            if node.delay == 0 {
                gray += 1
            } else if node.delay < lowDelay {
                green += 1
            } else if node.delay < mediumDelay {
                yellow += 1
            } else {
                orange += 1
            }
        }
        
        return (green, yellow, orange, gray)
    }
}

// 延迟统计徽章
struct DelayStatBadge: View {
    let count: Int
    let color: Color
    let label: String
    
    var body: some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                
                Text("\(count)")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Zash 风格的提供者信息卡片
struct ZashInfoCard: View {
    let provider: Provider
    @Environment(\.colorScheme) private var colorScheme
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // 流量信息部分
            if let info = provider.subscriptionInfo,
               info.total > 0 || info.upload > 0 || info.download > 0 {
                
                // 流量使用进度条 - 合并标题和值到一个HStack
                HStack {
                    Text("流量剩余")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    let totalBytes = formatBytes(info.total)
                    let remainingBytes = formatBytes(max(0, info.total - info.upload - info.download))
                    Text("\(remainingBytes) / \(totalBytes)")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                // 流量进度条 - 显示剩余流量百分比
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // 背景
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(height: 8)
                        
                        // 进度 - 剩余流量
                        let remainingPercentage = max(0, min(1.0, 1.0 - Double(info.upload + info.download) / Double(info.total)))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * remainingPercentage, height: 8)
                    }
                }
                .frame(height: 8)
                
                // 上传下载详情 - 使用单个HStack包含两个VStack
                HStack {
                    // 上传信息
                    VStack(alignment: .leading, spacing: 4) {
                        Text("上传")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                        
                        Text(formatBytes(Int64(info.upload)))
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                    }
                    
                    Spacer()
                    
                    // 下载信息
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("下载")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                        
                        Text(formatBytes(Int64(info.download)))
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                    }
                }
                
                Divider()
                
                // 到期时间和更新时间 - 使用单个HStack
                HStack {
                    // 到期时间
                    if info.expire > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("到期时间")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                            
                            Text(formatExpireDate(info.expire))
                                .font(.system(.subheadline, design: .rounded))
                        }
                    }
                    
                    Spacer()
                    
                    // 更新时间
                    if let updatedAt = provider.updatedAt,
                       let updateDate = parseDate(updatedAt) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("更新时间")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                            
                            Text(formatRelativeTime(updateDate))
                                .font(.system(.subheadline, design: .rounded))
                        }
                    }
                }
            } else {
                // 无流量信息时显示 - 使用单个HStack
                HStack {
                    Text("无订阅信息")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    // 更新时间
                    if let updatedAt = provider.updatedAt,
                       let updateDate = parseDate(updatedAt) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("更新时间")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                            
                            Text(formatRelativeTime(updateDate))
                                .font(.system(.subheadline, design: .rounded))
                        }
                    }
                }
            }
        }
        .padding()
        .background(cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(colorScheme == .dark ? 0.4 : 0.1), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
        )
        // 简化阴影效果
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.05),
            radius: 4,
            x: 0,
            y: 2
        )
        .padding(.horizontal)
        // 添加光栅化以提高滑动性能
        .drawingGroup(opaque: false)
    }
    
    // 格式化字节
    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        
        if gb >= 1 {
            return String(format: "%.1fGB", gb)
        } else if mb >= 1 {
            return String(format: "%.1fMB", mb)
        } else if kb >= 1 {
            return String(format: "%.1fKB", kb)
        } else {
            return "\(bytes)B"
        }
    }
    
    // 格式化到期日期
    private func formatExpireDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    // 解析日期
    private func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString)
    }
    
    // 格式化相对时间
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// Zash 风格的节点网格 - 优化版本
struct ZashNodesGrid: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedColumns: [GridItem] = []
    @State private var lastScreenWidth: CGFloat = 0
    
    var body: some View {
        if nodes.isEmpty {
            Text("没有找到节点")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            LazyVGrid(columns: getColumns(), spacing: 12) {
                ForEach(nodes) { node in
                    ZashNodeCardOptimized(
                        nodeName: node.name,
                        node: node,
                        isSelected: false,
                        isTesting: viewModel.testingNodes.contains(node.name),
                        viewModel: viewModel,
                        onTap: {
                            handleNodeTap(nodeName: node.name)
                        }
                    )
                    .id("\(node.name)-\(viewModel.testingNodes.contains(node.name))")
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func getColumns() -> [GridItem] {
        let screenWidth = UIScreen.main.bounds.width
        
        // 如果屏幕宽度没有变化，使用缓存的结果
        if abs(screenWidth - lastScreenWidth) < 1 && !cachedColumns.isEmpty {
            return cachedColumns
        }
        
        
        
        let spacing: CGFloat = 12
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let columnsCount = max(2, Int(screenWidth / (minCardWidth + spacing * 2)))
        let newColumns = Array(repeating: GridItem(.flexible(minimum: minCardWidth, maximum: maxCardWidth), spacing: spacing), count: columnsCount)
        
        // 避免在视图更新过程中直接修改状态
        DispatchQueue.main.async {
            self.lastScreenWidth = screenWidth
            self.cachedColumns = newColumns
        }
        
        return newColumns
    }
    
    // 处理节点点击
    private func handleNodeTap(nodeName: String) {
        
        HapticManager.shared.impact(.light)
        
        Task {
            await viewModel.healthCheckProviderProxy(
                providerName: provider.name,
                proxyName: nodeName
            )
        }
    }
}

// 添加 Zash 风格的代理组详情视图 - 优化版本
struct ZashGroupDetailView: View {
    let group: ProxyGroup
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @AppStorage("allowManualURLTestGroupSwitch") private var allowManualURLTestGroupSwitch = false
    @State private var showURLTestAlert = false
    @State private var cachedColumns: [GridItem] = []
    @State private var lastScreenWidth: CGFloat = 0
    @State private var isInitialAppear = true
    @State private var isLoaded = false
    @State private var delayStats: (green: Int, yellow: Int, orange: Int, gray: Int) = (0, 0, 0, 0)
    
    private var filteredNodes: [String] {
        if searchText.isEmpty {
            return group.all
        } else {
            return group.all.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        
        
        ScrollView {
            VStack(spacing: 16) {
                // 搜索栏 - 修改样式使其更加明显
                searchBarView
                
                // 节点统计信息
                statsView
                
                // 节点列表
                if filteredNodes.isEmpty {
                    Text("没有找到节点")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                } else {
                    // 使用懒加载方式优化列表渲染
                    nodeListView
                }
            }
            .padding(.vertical)
            // 设置为始终可见
            .opacity(1.0)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await viewModel.testGroupSpeed(groupName: group.name)
                    }
                } label: {
                    Label("测速", systemImage: "bolt.horizontal")
                }
            }
            
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .onAppear {
            
            // 直接设置为已加载状态，不使用延迟
            isLoaded = true
            
            // 计算延迟统计
            calculateDelayStats()
            
        }
    }
    
    // 搜索栏视图
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("搜索节点", text: $searchText)
                .font(.system(.body, design: .rounded))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(colorScheme == .dark ? Color.gray.opacity(0.5) : Color.blue.opacity(0.2), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
        )
        .padding(.horizontal)
    }
    
    // 统计信息视图
    private var statsView: some View {
        HStack {
            Text("共 \(group.all.count) 个节点")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            // 延迟统计 - 使用缓存的统计数据
            HStack(spacing: 8) {
                DelayStatBadge(count: delayStats.green, color: .green, label: "低延迟")
                DelayStatBadge(count: delayStats.yellow, color: .yellow, label: "中延迟")
                DelayStatBadge(count: delayStats.orange, color: .orange, label: "高延迟")
                DelayStatBadge(count: delayStats.gray, color: .gray, label: "超时")
            }
        }
        .padding(.horizontal)
    }
    
    // 节点列表视图 - 使用优化的列表渲染
    private var nodeListView: some View {
        LazyVGrid(columns: getColumns(), spacing: 12) {
            ForEach(filteredNodes.indices, id: \.self) { index in
                let nodeName = filteredNodes[index]
                let isNodeSelected = viewModel.groups.first(where: { $0.name == group.name })?.now == nodeName
                let isNodeTesting = viewModel.testingNodes.contains(nodeName)
                // 使用ID优化ForEach
                ZashNodeCardOptimized(
                    nodeName: nodeName,
                    node: viewModel.nodes.first { $0.name == nodeName },
                    isSelected: isNodeSelected,
                    isTesting: isNodeTesting,
                    viewModel: viewModel,
                    onTap: {
                        handleNodeTap(nodeName: nodeName)
                    }
                )
                .id("\(nodeName)-\(isNodeSelected)-\(isNodeTesting)")
            }
        }
        .padding(.horizontal)
    }
    
    // 处理节点点击
    private func handleNodeTap(nodeName: String) {
        
        HapticManager.shared.impact(.light)
        
        if group.type == "URLTest" && !allowManualURLTestGroupSwitch {
            // 显示不支持手动切换的提示
            showURLTestAlert = true
            HapticManager.shared.notification(.error)
            return
        }
        
        Task {
            await viewModel.selectProxy(groupName: group.name, proxyName: nodeName)
            
            // 重新获取代理数据以确保UI更新
            await viewModel.fetchProxies()
            
            await MainActor.run {
                // 添加成功的触觉反馈
                HapticManager.shared.notification(.success)
                
                // 关闭详情视图，返回到主视图
                // dismiss()
            }
        }
    }
    
    // 优化列计算以使用缓存
    private func getColumns() -> [GridItem] {
        let screenWidth = UIScreen.main.bounds.width
        
        // 如果屏幕宽度没有变化，使用缓存的结果
        if abs(screenWidth - lastScreenWidth) < 1 && !cachedColumns.isEmpty {
            return cachedColumns
        }
        
        
        
        let spacing: CGFloat = 12
        let minCardWidth: CGFloat = 160
        let maxCardWidth: CGFloat = 200
        
        let columnsCount = max(2, Int(screenWidth / (minCardWidth + spacing * 2)))
        let newColumns = Array(repeating: GridItem(.flexible(minimum: minCardWidth, maximum: maxCardWidth), spacing: spacing), count: columnsCount)
        
        // 避免在视图更新过程中直接修改状态
        DispatchQueue.main.async {
            self.lastScreenWidth = screenWidth
            self.cachedColumns = newColumns
        }
        
        return newColumns
    }
    
    // 计算延迟统计并缓存结果
    private func calculateDelayStats() {
        let lowThreshold = UserDefaults.standard.integer(forKey: "lowDelayThreshold")
        let mediumThreshold = UserDefaults.standard.integer(forKey: "mediumDelayThreshold")
        
        let lowDelay = lowThreshold == 0 ? 240 : lowThreshold
        let mediumDelay = mediumThreshold == 0 ? 500 : mediumThreshold
        
        var green = 0
        var yellow = 0
        var orange = 0
        var gray = 0
        
        for nodeName in group.all {
            if let node = viewModel.nodes.first(where: { $0.name == nodeName }) {
                if node.delay == 0 {
                    gray += 1
                } else if node.delay < lowDelay {
                    green += 1
                } else if node.delay < mediumDelay {
                    yellow += 1
                } else {
                    orange += 1
                }
            } else {
                gray += 1
            }
        }
        
        self.delayStats = (green, yellow, orange, gray)
    }
}

// 优化版节点卡片 - 减少不必要的重绘
struct ZashNodeCardOptimized: View {
    let nodeName: String
    let node: ProxyNode?
    let isSelected: Bool
    let isTesting: Bool
    @ObservedObject var viewModel: ProxyViewModel
    let onTap: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("lowDelayThreshold") private var lowDelayThreshold = 240
    @AppStorage("mediumDelayThreshold") private var mediumDelayThreshold = 500
    
    // 添加缓存属性，减少重复计算
    @State private var cachedNodeDelay: Int = 0
    @State private var cachedDelayColor: Color = .gray
    @State private var cachedNodeTypeLabel: String = ""
    @State private var cachedNodeTypeLabelColor: Color = .blue
    @State private var cachedDelayText: String = ""
    
    // 添加固定卡片高度 - 预渲染优化
    private let cardHeight: CGFloat = 90
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground)
    }
    
    var body: some View {
        
        
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // 顶部：节点名称和选中状态
                HStack(alignment: .top, spacing: 8) {
                    // 节点名称
                    Text(nodeName)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .id("title-\(nodeName)")
                    
                    Spacer()
                        .id("spacer-top-\(nodeName)")
                    
                    // 选中状态指示器
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.system(size: 18))
                            .id("selected-icon-\(nodeName)")
                    }
                }
                .id("top-row-\(nodeName)")
                
                Spacer()
                    .id("spacer-middle-\(nodeName)")
                
                // 底部：节点类型和延迟
                HStack(alignment: .center) {
                    // 节点类型标签 - 使用缓存的类型标签
                    Text(cachedNodeTypeLabel)
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundStyle(cachedNodeTypeLabelColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(cachedNodeTypeLabelColor.opacity(0.1))
                        .clipShape(Capsule())
                        .id("type-label-\(nodeName)-\(cachedNodeTypeLabel)")
                    
                    Spacer()
                        .id("spacer-bottom-\(nodeName)")
                    
                    // 延迟指示器
                    HStack(spacing: 4) {
                        if isTesting {
                            // 测速动画
                            ZashDelayTestingView()
                                .id("testing-\(nodeName)")
                        } else {
                            // 延迟文本 - 使用缓存的延迟文本
                            Text(cachedDelayText)
                                .font(.system(.caption, design: .rounded))
                                .fontWeight(.medium)
                                .foregroundStyle(cachedDelayColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(cachedDelayColor.opacity(0.1))
                                .clipShape(Capsule())
                                .id("delay-\(nodeName)-\(cachedDelayText)")
                        }
                    }
                    .id("delay-container-\(nodeName)")
                }
                .id("bottom-row-\(nodeName)")
            }
            .padding(12)
            .frame(height: cardHeight) // 直接使用固定高度
            .background(cardBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(.systemGray4).opacity(colorScheme == .dark ? 0.4 : 0.2), lineWidth: colorScheme == .dark ? 1.0 : 0.5)
                    .id("border-\(nodeName)")
            )
            .id("content-\(nodeName)")
        }
        .buttonStyle(PlainButtonStyle()) // 使用PlainButtonStyle避免按钮动画
        .frame(height: cardHeight) // 设置固定高度
        // 添加光栅化以提高滑动性能
        .drawingGroup(opaque: false)
        // 使用更稳定的ID策略，确保当选中的节点变化时视图会更新
        .id("\(nodeName)-\(isSelected ? "selected" : "normal")-\(isTesting ? "testing" : "idle")-\(cachedNodeDelay)")
        .onAppear {
            
            
            // 计算并缓存节点延迟
            if let node = node {
                
                self.cachedNodeDelay = node.delay
            } else {
                
                self.cachedNodeDelay = 0
            }
            
            // 计算并缓存延迟颜色
            let delay = self.cachedNodeDelay
            if delay == 0 {
                
                self.cachedDelayColor = .gray
            } else if delay < lowDelayThreshold {
                
                self.cachedDelayColor = .green
            } else if delay < mediumDelayThreshold {
                
                self.cachedDelayColor = .yellow
            } else {
                
                self.cachedDelayColor = .orange
            }
            
            // 计算并缓存节点类型标签
            if viewModel.groups.contains(where: { $0.name == nodeName }) {
                
                self.cachedNodeTypeLabel = "代理组"
                self.cachedNodeTypeLabelColor = .blue
            } else if nodeName == "DIRECT" {
                
                self.cachedNodeTypeLabel = "直连"
                self.cachedNodeTypeLabelColor = .green
            } else if nodeName == "REJECT" {
                
                self.cachedNodeTypeLabel = "拒绝"
                self.cachedNodeTypeLabelColor = .red
            } else {
                let typeText = node?.type ?? "未知"
                
                self.cachedNodeTypeLabel = typeText
                self.cachedNodeTypeLabelColor = .purple
            }
            
            // 计算并缓存延迟显示文本
            if isTesting {
                
                self.cachedDelayText = "测速中"
            } else if cachedNodeDelay > 0 {
                
                self.cachedDelayText = "\(cachedNodeDelay) ms"
            } else {
                
                self.cachedDelayText = "超时"
            }
        }
    }
}

#Preview {
    ZashProxyView(server: ClashServer(name: "测试服务器", url: "192.168.1.1", port: "9090", secret: "123456"))
} 
