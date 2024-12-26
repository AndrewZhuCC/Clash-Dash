import SwiftUI

// 添加到文件顶部，在 LoadingView 之前
struct CardShadowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func cardShadow() -> some View {
        modifier(CardShadowModifier())
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("加载中")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProxyView: View {
    let server: ClashServer
    @StateObject private var viewModel: ProxyViewModel
    @State private var selectedGroupId: String?
    @State private var isRefreshing = false
    @State private var showProviderSheet = false
    @Namespace private var animation
    
    // 添加触觉反馈生成器
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    
    init(server: ClashServer) {
        self.server = server
        self._viewModel = StateObject(wrappedValue: ProxyViewModel(server: server))
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if viewModel.groups.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView {
                            Label("加载中", systemImage: "network")
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        LoadingView()
                    }
                } else {
                    // 代理组概览卡片 - 显示所有节点
                    ProxyGroupsOverview(
                        groups: viewModel.getSortedGroups(),
                        viewModel: viewModel
                    )
                    
                    // 代理提供者部分 - 只显示有订阅信息的提供者
                    let subscriptionProviders = viewModel.providers.filter { $0.subscriptionInfo != nil }
                    if !subscriptionProviders.isEmpty {
                        ProxyProvidersSection(
                            providers: subscriptionProviders, // 只传入有订阅信息的提供者
                            nodes: viewModel.providerNodes,
                            viewModel: viewModel
                        )
                    } else {
                        let _ = print("❌ 没有包含订阅信息的代理提供者")
                        EmptyView()
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await refreshData()
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        // 添加触觉反馈
                        impactFeedback.impactOccurred()
                        showProviderSheet = true
                    } label: {
                        Label("添加", systemImage: "square.stack.3d.up")
                    }
                    
                    Button {
                        // 添加触觉反馈
                        impactFeedback.impactOccurred()
                        Task { await refreshData() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, 
                                     value: isRefreshing)
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .sheet(isPresented: $showProviderSheet) {
            ProvidersSheetView(
                providers: viewModel.providers,
                nodes: viewModel.providerNodes,
                viewModel: viewModel
            )
            .presentationDetents([.medium, .large])
        }
        .task {
            await viewModel.fetchProxies()
        }
    }
    
    private func refreshData() async {
        withAnimation { isRefreshing = true }
        await viewModel.fetchProxies()
        withAnimation { isRefreshing = false }
        
        // 添加成功的触觉反馈
        let successFeedback = UINotificationFeedbackGenerator()
        successFeedback.notificationOccurred(.success)
    }
    
    private func sortNodes(_ nodeNames: [String], _ allNodes: [ProxyNode], groupName: String) -> [ProxyNode] {
        let specialNodes = ["DIRECT", "REJECT"]
        var matchedNodes = nodeNames.compactMap { name in
            if specialNodes.contains(name) {
                if let existingNode = allNodes.first(where: { $0.name == name }) {
                    return existingNode
                }
                return ProxyNode(
                    id: UUID().uuidString,
                    name: name,
                    type: "Special",
                    alive: true,
                    delay: 0,
                    history: []
                )
            }
            return allNodes.first { $0.name == name }
        }
        
        // 检查是否需要隐藏不可用代理
        let hideUnavailable = UserDefaults.standard.bool(forKey: "hideUnavailableProxies")
        if hideUnavailable {
            matchedNodes = matchedNodes.filter { node in
                specialNodes.contains(node.name) || node.delay > 0
            }
        }
        
        return matchedNodes.sorted { node1, node2 in
            if node1.name == "DIRECT" { return true }
            if node2.name == "DIRECT" { return false }
            if node1.name == "REJECT" { return true }
            if node2.name == "REJECT" { return false }
            if node1.name == groupName { return true }
            if node2.name == groupName { return false }
            
            if node1.delay == 0 { return false }
            if node2.delay == 0 { return true }
            return node1.delay < node2.delay
        }
    }
}

// 代理组概览卡片
struct ProxyGroupsOverview: View {
    let groups: [ProxyGroup]
    @ObservedObject var viewModel: ProxyViewModel
    
    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(groups, id: \.name) { group in
                GroupCard(
                    group: group,
                    viewModel: viewModel
                )
            }
        }
    }
}

// 单个代理组卡片
struct GroupCard: View {
    let group: ProxyGroup
    @ObservedObject var viewModel: ProxyViewModel
    @State private var showingProxySelector = false
    
    private var delayStats: (green: Int, yellow: Int, red: Int, timeout: Int) {
        var green = 0   // 低延迟 (0-150ms)
        var yellow = 0  // 中等延迟 (151-300ms)
        var red = 0     // 高延迟 (>300ms)
        var timeout = 0 // 未连接 (0ms)
        
        for nodeName in group.all {
            // 获取节点的实际延迟
            let delay = getNodeDelay(nodeName: nodeName)
            
            switch delay {
            case 0:
                timeout += 1
            case DelayColor.lowRange:
                green += 1
            case DelayColor.mediumRange:
                yellow += 1
            default:
                red += 1
            }
        }
        
        return (green, yellow, red, timeout)
    }
    
    private var totalNodes: Int {
        group.all.count
    }
    
    // 添加获取代理链的方法
    private func getProxyChain(nodeName: String, visitedGroups: Set<String> = []) -> [String] {
        // 防止循环依赖
        if visitedGroups.contains(nodeName) {
            return [nodeName]
        }
        
        // 如果是代理组
        if let group = viewModel.groups.first(where: { $0.name == nodeName }) {
            var visited = visitedGroups
            visited.insert(nodeName)
            
            // 递归获取代理链
            var chain = [nodeName]
            chain.append(contentsOf: getProxyChain(nodeName: group.now, visitedGroups: visited))
            return chain
        }
        
        // 如果是实际节点或特殊节点
        return [nodeName]
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 标题行
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(group.name)
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        if group.type == "URLTest" {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption2)
                        }
                    }
                    
                    Text(group.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // 节点数量标签
                Text("\(totalNodes) 个节点")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
            }
            
            Divider()
                .padding(.horizontal, -12)
            
            // 当前节点信息
            HStack(spacing: 6) {
                Image(systemName: getNodeIcon(for: group.now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                
                if viewModel.testingGroups.contains(group.name) {
                    DelayTestingView()
                        .foregroundStyle(.blue)
                        .scaleEffect(0.7)
                } else {
                    // 获取实际节点的延迟
                    let (finalNode, finalDelay) = getActualNodeAndDelay(nodeName: group.now)
                    
                    // 显示直接选中的节点名称
                    Text(group.now)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    // 显示实际节点的延迟
                    if finalDelay > 0 {
                        Text("\(finalDelay) ms")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(DelayColor.color(for: finalDelay).opacity(0.1))
                            .foregroundStyle(DelayColor.color(for: finalDelay))
                            .clipShape(Capsule())
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            // 使用新的延迟统计条
            DelayBar(
                green: delayStats.green,
                yellow: delayStats.yellow,
                red: delayStats.red,
                timeout: delayStats.timeout,
                total: totalNodes
            )
            .padding(.horizontal, 2)
            
            // // 延迟统计数据
            // HStack {
            //     HStack(spacing: 8) {
            //         ForEach([
            //             (count: delayStats.green, color: DelayColor.low, label: "低延迟"),
            //             (count: delayStats.yellow, color: DelayColor.medium, label: "等"),
            //             (count: delayStats.red, color: DelayColor.high, label: "高延迟"),
            //             (count: delayStats.timeout, color: DelayColor.disconnected, label: "超时")
            //         ], id: \.label) { stat in
            //             if stat.count > 0 {
            //                 HStack(spacing: 2) {
            //                     Circle()
            //                         .fill(stat.color.opacity(0.85))
            //                         .frame(width: 4, height: 4)
            //                     Text("\(stat.count)")
            //                         .font(.caption2)
            //                         .foregroundStyle(.secondary)
            //                 }
            //             }
            //         }
            //     }
            // }
            // .padding(.top, 2)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .onTapGesture {
            // 添加触觉反馈
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            
            // 显示选择器
            showingProxySelector = true
        }
        .sheet(isPresented: $showingProxySelector) {
            ProxySelectorSheet(
                group: group,
                viewModel: viewModel
            )
        }
    }
    
    private func getStatusColor(for nodeName: String) -> Color {
        switch nodeName {
        case "DIRECT":
            return .green
        case "REJECT":
            return .red
        default:
            return .blue
        }
    }
    
    private func getNodeIcon(for nodeName: String) -> String {
        switch nodeName {
        case "DIRECT":
            return "arrow.up.forward"
        case "REJECT":
            return "xmark.circle"
        default:
            if let node = viewModel.nodes.first(where: { $0.name == nodeName }) {
                switch node.type.lowercased() {
                case "ss", "shadowsocks":
                    return "bolt.shield"
                case "vmess":
                    return "v.circle"
                case "trojan":
                    return "shield.lefthalf.filled"
                case "http", "https":
                    return "globe"
                case "socks", "socks5":
                    return "network"
                default:
                    return "antenna.radiowaves.left.and.right"
                }
            }
            return "antenna.radiowaves.left.and.right"
        }
    }
    
    // 添加递归获取实际节点和延迟的方法
    private func getActualNodeAndDelay(nodeName: String, visitedGroups: Set<String> = []) -> (String, Int) {
        // 防止循环依赖
        if visitedGroups.contains(nodeName) {
            return (nodeName, 0)
        }
        
        // 如果是代理组
        if let group = viewModel.groups.first(where: { $0.name == nodeName }) {
            var visited = visitedGroups
            visited.insert(nodeName)
            
            // 递归获取当前选中节点的实际节点和延迟
            return getActualNodeAndDelay(nodeName: group.now, visitedGroups: visited)
        }
        
        // 如果是实际节点
        if let node = viewModel.nodes.first(where: { $0.name == nodeName }) {
            return (node.name, node.delay)
        }
        
        // 如果是特殊节点 (DIRECT/REJECT)
        return (nodeName, 0)
    }
    
    // 修改递归获取节点延迟的方法
    private func getNodeDelay(nodeName: String, visitedGroups: Set<String> = []) -> Int {
        // 防止循环依赖
        if visitedGroups.contains(nodeName) {
            return 0
        }
        
        // 如果是 REJECT，直接计入超时
        if nodeName == "REJECT" {
            return 0
        }
        
        // 如果是代理组，递归获取当前选中节点的延迟
        if let group = viewModel.groups.first(where: { $0.name == nodeName }) {
            var visited = visitedGroups
            visited.insert(nodeName)
            return getNodeDelay(nodeName: group.now, visitedGroups: visited)
        }
        
        // 如果是实际节点（包括 DIRECT），返回节点延迟
        if let node = viewModel.nodes.first(where: { $0.name == nodeName }) {
            return node.delay
        }
        
        return 0
    }
}

// 代理提供者部分
struct ProxyProvidersSection: View {
    let providers: [Provider] // 这里已经是过滤后的提供者
    let nodes: [String: [ProxyNode]]
    @ObservedObject var viewModel: ProxyViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("代理提供者")
                .font(.title2.bold())
            
            ForEach(providers.sorted(by: { $0.name < $1.name })) { provider in
                let _ = print("📦 显示订阅提供者: \(provider.name)")
                ProxyProviderCard(
                    provider: provider, 
                    nodes: nodes[provider.name] ?? [], 
                    viewModel: viewModel
                )
            }
        }
    }
}

// 修改 ProxyProviderCard
struct ProxyProviderCard: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    @State private var isUpdating = false
    @State private var updateStatus: UpdateStatus = .none
    @State private var selectedProvider: Provider?
    
    // 添加更新状态枚举
    private enum UpdateStatus {
        case none
        case updating
        case success
        case failure
    }
    
    // 添加触觉反馈生成器
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    
    private var trafficInfo: (used: String, total: String, percentage: Double)? {
        guard let info = provider.subscriptionInfo else { return nil }
        let used = Double(info.upload + info.download)
        let total = Double(info.total)
        let percentage = (used / total) * 100
        return (formatBytes(Int64(used)), formatBytes(info.total), percentage)
    }
    
    private var relativeUpdateTime: String {
        guard let updatedAt = provider.updatedAt else { 
            // print("Provider \(provider.name) updatedAt is nil")
            return "从未更新" 
        }
        
        // print("Provider \(provider.name) updatedAt: \(updatedAt)")
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = formatter.date(from: updatedAt) else {
            // print("Failed to parse date: \(updatedAt)")
            return "未知"
        }
        
        let interval = Date().timeIntervalSince(date)
        
        switch interval {
        case 0..<60:
            return "刚刚"
        case 60..<3600:
            let minutes = Int(interval / 60)
            return "\(minutes) 分钟前"
        case 3600..<86400:
            let hours = Int(interval / 3600)
            return "\(hours) 小时前"
        case 86400..<604800:
            let days = Int(interval / 86400)
            return "\(days) 天前"
        case 604800..<2592000:
            let weeks = Int(interval / 604800)
            return "\(weeks) 周前"
        default:
            let months = Int(interval / 2592000)
            return "\(months) 个月前"
        }
    }
    
    private var expirationDate: String? {
        guard let info = provider.subscriptionInfo else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题栏
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.name)
                            .font(.headline)
                        
                        Text(provider.vehicleType)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    
                    // 更新时间
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("更新时间：\(relativeUpdateTime)")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 操作按钮
                HStack(spacing: 12) {
                    Button {
                        Task {
                            // 添加触觉反馈
                            impactFeedback.impactOccurred()
                            
                            // print("Updating provider: \(provider.name)")
                            updateStatus = .updating
                            
                            do {
                                await viewModel.updateProxyProvider(providerName: provider.name)
                                updateStatus = .success
                                // 成功时的触觉反馈
                                let successFeedback = UINotificationFeedbackGenerator()
                                successFeedback.notificationOccurred(.success)
                                
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                                updateStatus = .none
                            } catch {
                                // print("Provider update failed: \(error)")
                                updateStatus = .failure
                                // 失败时的触觉反馈
                                let errorFeedback = UINotificationFeedbackGenerator()
                                errorFeedback.notificationOccurred(.error)
                                
                                try await Task.sleep(nanoseconds: 2_000_000_000)
                                updateStatus = .none
                            }
                            
                            await viewModel.fetchProxies()
                        }
                    } label: {
                        Group {
                            switch updateStatus {
                            case .none:
                                Image(systemName: "arrow.clockwise")
                            case .updating:
                                ProgressView()
                                    .scaleEffect(0.7)
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failure:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(width: 20, height: 20) // 固定大小避免图标切换时的跳动
                    }
                    .disabled(updateStatus != .none)
                    .animation(.spring(), value: updateStatus)
                    
                    Button {
                        // 添加触觉反馈
                        impactFeedback.impactOccurred()
                        
                        // print("Opening node selector for provider: \(provider.name)")
                        selectedProvider = provider
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            
            
            
            // 到期时间
            if let expireDate = expirationDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text("到期时间：\(expireDate)")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            // 流量信息
            if let (used, total, percentage) = trafficInfo {
                VStack(alignment: .leading, spacing: 8) {
                    // 流量度条
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(.systemGray5))
                                .frame(height: 4)
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(getTrafficColor(percentage: percentage))
                                .frame(width: geometry.size.width * CGFloat(min(percentage, 100)) / 100, height: 4)
                        }
                    }
                    .frame(height: 4)
                    
                    // 流量���情
                    HStack {
                        Text("\(used) / \(total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(String(format: "%.1f%%", percentage))
                            .font(.caption)
                            .foregroundColor(getTrafficColor(percentage: percentage))
                    }
                }
            }
        }
        .padding()
        .cardShadow()
        .onTapGesture {
            // 添加触觉反馈
            impactFeedback.impactOccurred()
            
            // print("Opening node selector for provider: \(provider.name)")
            selectedProvider = provider
        }
        .sheet(item: $selectedProvider) { provider in
            ProviderNodeSelector(
                provider: provider,
                nodes: nodes,
                viewModel: viewModel
            )
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    private func getTrafficColor(percentage: Double) -> Color {
        if percentage < 50 {
            return .green
        } else if percentage < 80 {
            return .yellow
        } else {
            return .red
        }
    }
}

// 添加节点选择 Sheet
struct ProviderNodeSelector: View {
    let provider: Provider
    let nodes: [ProxyNode]
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isTestingAll = false
    @State private var testingNodes = Set<String>()
    
    // 添加触觉反馈生成器
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(nodes) { node in
                        ProxyNodeCard(
                            nodeName: node.name,
                            node: node,
                            isSelected: false,
                            isTesting: testingNodes.contains(node.name) || isTestingAll,
                            viewModel: viewModel
                        )
                        .onTapGesture {
                            // 添加触觉反馈
                            impactFeedback.impactOccurred()
                            
                            Task {
                                // print("Testing node: \(node.name) in provider: \(provider.name)")
                                testingNodes.insert(node.name)
                                
                                do {
                                    try await withTaskCancellationHandler {
                                        await viewModel.healthCheckProviderProxy(
                                            providerName: provider.name,
                                            proxyName: node.name

                                        )
                                        await viewModel.fetchProxies()
                                        // 添加成功的触觉反馈
                                        let successFeedback = UINotificationFeedbackGenerator()
                                        successFeedback.notificationOccurred(.success)

                                    } onCancel: {
                                        // print("Node test cancelled: \(node.name)")
                                        testingNodes.remove(node.name)
                                        // 添加失败的触觉反馈
                                        let errorFeedback = UINotificationFeedbackGenerator()
                                        errorFeedback.notificationOccurred(.error)
                                    }
                                } catch {
                                    print("Node test error: \(error)")
                                    // 添加失败的触觉反馈
                                    let errorFeedback = UINotificationFeedbackGenerator()
                                    errorFeedback.notificationOccurred(.error)
                                }
                                
                                testingNodes.remove(node.name)
                                // print("Node test completed: \(node.name)")
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(provider.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 添加触觉反馈
                        impactFeedback.impactOccurred()
                        
                        Task {
                            // print("Testing all nodes in provider: \(provider.name)")
                            isTestingAll = true
                            
                            do {
                                try await withTaskCancellationHandler {
                                    await viewModel.healthCheckProvider(providerName: provider.name)
                                    await viewModel.fetchProxies()
                                    // 添加成功的触觉反馈
                                    let successFeedback = UINotificationFeedbackGenerator()
                                    successFeedback.notificationOccurred(.success)
                                } onCancel: {
                                    // print("Provider test cancelled")
                                    isTestingAll = false
                                    // 添加失败的触觉反馈
                                    let errorFeedback = UINotificationFeedbackGenerator()
                                    errorFeedback.notificationOccurred(.error)
                                }
                            } catch {
                                // print("Provider test error: \(error)")
                                // 添加失败的触觉反馈
                                let errorFeedback = UINotificationFeedbackGenerator()
                                errorFeedback.notificationOccurred(.error)
                            }
                            
                            isTestingAll = false
                            // print("Provider test completed: \(provider.name)")
                        }
                    } label: {
                        if isTestingAll {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Label("测速", systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(isTestingAll)
                }
                
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        // 添加触觉反馈
                        impactFeedback.impactOccurred()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// 其他辅助视图和法保持不变...

struct ProvidersSheetView: View {
    let providers: [Provider]
    let nodes: [String: [ProxyNode]]
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(providers.sorted(by: { $0.name < $1.name })) { provider in
                    Section(provider.name) {
                        if let nodes = nodes[provider.name] {
                            ForEach(nodes) { node in
                                HStack {
                                    Text(node.name)
                                    Spacer()
                                    if node.delay > 0 {
                                        Text("\(node.delay) ms")
                                            .foregroundStyle(getDelayColor(node.delay))
                                    } else {
                                        Text("超时")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("代理提供者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func getDelayColor(_ delay: Int) -> Color {
        DelayColor.color(for: delay)
    }
}

struct ScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

// 修改 ProxySelectorSheet 使用网格布局
struct ProxySelectorSheet: View {
    let group: ProxyGroup
    @ObservedObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showURLTestAlert = false
    @AppStorage("proxyGroupSortOrder") private var proxyGroupSortOrder = ProxyGroupSortOrder.default
    
    // 添加计算属性来获取可用节点
    private var availableNodes: [String] {
        // 获取所有代理组名称
        let groupNames = Set(viewModel.groups.map { $0.name })
        
        // 过滤节点列表，保留实际节点和特殊节点
        return group.all.filter { nodeName in
            // 保留特殊节点
            if ["DIRECT", "REJECT"].contains(nodeName) {
                return true
            }
            
            // 如果是代理组，检查是否有实际节点
            if groupNames.contains(nodeName),
               let proxyGroup = viewModel.groups.first(where: { $0.name == nodeName }) {
                // 递归检查代理组是否包含实际节点
                return hasActualNodes(in: proxyGroup, visitedGroups: [])
            }
            
            // 其他情况认为是实际节点
            return true
        }
    }
    
    // 递归检查代理组是否包含实际节点
    private func hasActualNodes(in group: ProxyGroup, visitedGroups: Set<String>) -> Bool {
        var visited = visitedGroups
        visited.insert(group.name)
        
        for nodeName in group.all {
            // 如果是特殊节点，返回 true
            if ["DIRECT", "REJECT"].contains(nodeName) {
                return true
            }
            
            // 如果是已访问过的代理组，跳过以避免循环
            if visited.contains(nodeName) {
                continue
            }
            
            // 如果是代理组，递归检查
            if let subGroup = viewModel.groups.first(where: { $0.name == nodeName }) {
                if hasActualNodes(in: subGroup, visitedGroups: visited) {
                    return true
                }
            } else {
                // 不是代理组，认为是实际节点
                return true
            }
        }
        
        return false
    }
    
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    // 节点统计
                    HStack {
                        Text("节点列表")
                            .font(.headline)
                        Spacer()
                        Text("\(availableNodes.count) 个节点")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // 节点网格
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(availableNodes, id: \.self) { nodeName in
                            let node = viewModel.nodes.first { $0.name == nodeName }
                            ProxyNodeCard(
                                nodeName: nodeName,
                                node: node,
                                isSelected: group.now == nodeName,
                                isTesting: node.map { viewModel.testingNodes.contains($0.id) } ?? false,
                                viewModel: viewModel
                            )
                            .onTapGesture {
                                // 添加触觉反馈
                                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                impactFeedback.impactOccurred()
                                
                                if group.type == "URLTest" {
                                    showURLTestAlert = true
                                } else {
                                    Task {
                                        // 先切换节点
                                        await viewModel.selectProxy(groupName: group.name, proxyName: nodeName)
                                        // 如果不是 REJECT，则测试延迟
                                        if nodeName != "REJECT" {
                                            await viewModel.testNodeDelay(nodeName: nodeName)
                                        }

                                        // 添加成功的触觉反馈
                                        let successFeedback = UINotificationFeedbackGenerator()
                                        successFeedback.notificationOccurred(.success)

                                        // 移除自动关闭
                                        // dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .onAppear {
                // 在显示时保存当前节点顺序
                let sortedNodes = viewModel.getSortedNodes(group.all, in: group)
                viewModel.saveNodeOrder(for: group.name, nodes: sortedNodes)
            }
            .onDisappear {
                // 在关闭时清除保存的顺序
                viewModel.clearSavedNodeOrder(for: group.name)
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(group.name)
                            .font(.headline)
                        
                        if viewModel.testingGroups.contains(group.name) {
                            DelayTestingView()
                                .foregroundStyle(.blue)
                                .scaleEffect(0.8)
                        }
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 添加触觉反馈
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()
                        
                        Task {
                            await viewModel.testGroupSpeed(groupName: group.name)
                            // 添加成功的触觉反馈
                            let successFeedback = UINotificationFeedbackGenerator()
                            successFeedback.notificationOccurred(.success)
                        }
                    } label: {
                        Label("测速", systemImage: "bolt.horizontal")
                    }
                    .disabled(viewModel.testingGroups.contains(group.name))
                }
                
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        // 添加触觉反馈
                        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                        impactFeedback.impactOccurred()
                        
                        dismiss()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.testingGroups.contains(group.name))
            .alert("自动测速选择分组", isPresented: $showURLTestAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text("该分组不支持手动切换节点")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// 添加节点卡片视图
struct ProxyNodeCard: View {
    let nodeName: String
    let node: ProxyNode?
    let isSelected: Bool
    let isTesting: Bool
    @ObservedObject var viewModel: ProxyViewModel  // 添加 viewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 节点名称和选中状态
            HStack {
                Text(nodeName)
                    .font(.system(.subheadline, design: .rounded))
                    .bold()
                    .lineLimit(1)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }
            }
            
            // 节点类型和延迟
            HStack {
                // 如果是代理组，显示 "代理组"，否则显示节点类型
                if let group = viewModel.groups.first(where: { $0.name == nodeName }) {
                    Text("代理组")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                } else {
                    Text(node?.type ?? "Special")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                if nodeName == "REJECT" {
                    Text("阻断")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.1))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                } else if isTesting {
                    DelayTestingView()
                        .foregroundStyle(.blue)
                        .scaleEffect(0.8)
                        .transition(.opacity)
                } else {
                    // 获取延迟
                    let delay = getNodeDelay(nodeName: nodeName)
                    if delay > 0 {
                        Text("\(delay) ms")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(getDelayColor(delay).opacity(0.1))
                            .foregroundStyle(getDelayColor(delay))
                            .clipShape(Capsule())
                            .transition(.opacity)
                    } else {
                        Text("超时")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.1))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? .blue : .clear, lineWidth: 2)
        }
    }
    
    // 获取节点延迟的辅助方法
    private func getNodeDelay(nodeName: String, visitedGroups: Set<String> = []) -> Int {
        // 防止循环依赖
        if visitedGroups.contains(nodeName) {
            return 0
        }
        
        // 如果是代理组，递归获取当前选中节点的延迟
        if let group = viewModel.groups.first(where: { $0.name == nodeName }) {
            var visited = visitedGroups
            visited.insert(nodeName)
            
            // 获取当前选中的节点
            let currentNodeName = group.now
            // 递归获取实际节点的延迟，传递已访问的组列表
            return getNodeDelay(nodeName: currentNodeName, visitedGroups: visited)
        }
        
        // 如果是实际节点，返回节点延迟
        if let actualNode = viewModel.nodes.first(where: { $0.name == nodeName }) {
            return actualNode.delay
        }
        
        return 0
    }
    
    private func getDelayColor(_ delay: Int) -> Color {
        DelayColor.color(for: delay)
    }
}

// 更新 DelayColor 构造，增加颜色饱和度
struct DelayColor {
    // 延迟范围常量
    static let lowRange = 0...150
    static let mediumRange = 151...300
    static let highThreshold = 300
    
    static func color(for delay: Int) -> Color {
        switch delay {
        case 0:
            return Color(red: 1.0, green: 0.2, blue: 0.2) // 更艳的红色
        case lowRange:
            return Color(red: 0.2, green: 0.8, blue: 0.2) // 鲜艳的绿色
        case mediumRange:
            return Color(red: 1.0, green: 0.75, blue: 0.0) // 明亮的黄色
        default:
            return Color(red: 1.0, green: 0.5, blue: 0.0) // 鲜艳的橙色
        }
    }
    
    static let disconnected = Color(red: 1.0, green: 0.2, blue: 0.2) // 更鲜艳的红色
    static let low = Color(red: 0.2, green: 0.8, blue: 0.2) // 鲜艳的绿色
    static let medium = Color(red: 1.0, green: 0.75, blue: 0.0) // 明亮的黄色
    static let high = Color(red: 1.0, green: 0.5, blue: 0.0) // 鲜艳的橙色
}

// 修改延迟测试动画组件
struct DelayTestingView: View {
    @State private var isAnimating = false
    
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .foregroundStyle(.blue)
            .onAppear {
                withAnimation(
                    .linear(duration: 1)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
            .onDisappear {
                isAnimating = false
            }
    }
}

//  GroupCard 中替换原来的延迟统计条部分
struct DelayBar: View {
    let green: Int
    let yellow: Int
    let red: Int
    let timeout: Int
    let total: Int
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                // 低延迟部分
                if green > 0 {
                    DelaySegment(
                        width: CGFloat(green) / CGFloat(total) * geometry.size.width,
                        color: DelayColor.low,
                        isFirst: true,
                        isLast: yellow == 0 && red == 0 && timeout == 0
                    )
                }
                
                // 中等延迟部分
                if yellow > 0 {
                    DelaySegment(
                        width: CGFloat(yellow) / CGFloat(total) * geometry.size.width,
                        color: DelayColor.medium,
                        isFirst: green == 0,
                        isLast: red == 0 && timeout == 0
                    )
                }
                
                // 高延迟部分
                if red > 0 {
                    DelaySegment(
                        width: CGFloat(red) / CGFloat(total) * geometry.size.width,
                        color: DelayColor.high,
                        isFirst: green == 0 && yellow == 0,
                        isLast: timeout == 0
                    )
                }
                
                // 超时部分
                if timeout > 0 {
                    DelaySegment(
                        width: CGFloat(timeout) / CGFloat(total) * geometry.size.width,
                        color: DelayColor.disconnected,
                        isFirst: green == 0 && yellow == 0 && red == 0,
                        isLast: true
                    )
                }
            }
        }
        .frame(height: 6)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray6))
        )
    }
}

// 延迟条段组件
struct DelaySegment: View {
    let width: CGFloat
    let color: Color
    let isFirst: Bool
    let isLast: Bool
    
    var body: some View {
        color
            .frame(width: max(width, 0))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 3,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .cornerRadius(isFirst ? 3 : 0, corners: .topLeft)
            .cornerRadius(isFirst ? 3 : 0, corners: .bottomLeft)
            .cornerRadius(isLast ? 3 : 0, corners: .topRight)
            .cornerRadius(isLast ? 3 : 0, corners: .bottomRight)
    }
}

// 添加圆角辅助扩展
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    NavigationStack {
        ProxyView(server: ClashServer(name: "测试服务器", url: "10.1.1.2", port: "9090", secret: "123456"))
    }
} 
