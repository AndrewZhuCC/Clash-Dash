import Foundation

struct ProxyNode: Identifiable {
    let id: String
    let name: String
    let type: String
    let alive: Bool
    let delay: Int
    let history: [ProxyHistory]
}

struct ProxyHistory: Codable {
    let time: String
    let delay: Int
}

struct ProxyGroup: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let now: String
    let all: [String]
    let alive: Bool
    
    init(name: String, type: String, now: String, all: [String], alive: Bool = true) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.alive = alive
    }
}

// 更新数据模型
struct ProxyProvider: Codable {
    let name: String
    let type: String
    let vehicleType: String
    let proxies: [ProxyDetail]
    let testUrl: String?
    let subscriptionInfo: SubscriptionInfo?
    let updatedAt: String?
}

struct ProxyProvidersResponse: Codable {
    let providers: [String: ProxyProvider]
}

// 添加 Provider 模型
struct Provider: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let vehicleType: String
    let nodeCount: Int
    let testUrl: String?
    let subscriptionInfo: SubscriptionInfo?
    let updatedAt: String?
}

struct SubscriptionInfo: Codable {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64
    
    enum CodingKeys: String, CodingKey {
        case upload = "Upload"
        case download = "Download"
        case total = "Total"
        case expire = "Expire"
    }
}

class ProxyViewModel: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var groups: [ProxyGroup] = []
    @Published var nodes: [ProxyNode] = []
    @Published var providerNodes: [String: [ProxyNode]] = [:]
    @Published var testingNodes: Set<String> = []
    @Published var lastUpdated = Date()
    @Published var lastDelayTestTime = Date()
    @Published var isSortMode = false  // 添加排序模式状态
    
    private let server: ClashServer
    private var currentTask: Task<Void, Never>?
    private let settingsViewModel = SettingsViewModel()
    private let defaultTestUrl = "http://www.gstatic.com/generate_204"
    
    // 添加用于存储自定义顺序的键
    private var customOrderKey: String {
        "proxyGroups.customOrder.\(server.id)"
    }
    
    init(server: ClashServer) {
        self.server = server
        Task {
            await fetchProxies()
            settingsViewModel.fetchConfig(server: server)
        }
    }
    
    private func makeRequest(path: String) -> URLRequest? {
        let scheme = server.useSSL ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(server.url):\(server.port)/\(path)") else {
            print("无效的 URL")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(server.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    @MainActor
    func fetchProxies() async {
        currentTask?.cancel()
        
        currentTask = Task {
            do {
                // 1. 获取 providers 数据
                guard let providersRequest = makeRequest(path: "providers/proxies") else { return }
                let (providersData, _) = try await URLSession.shared.data(for: providersRequest)
                
                // 解析 providers 数据，获取所有实际的代理节点
                if let providersResponse = try? JSONDecoder().decode(ProxyProvidersResponse.self, from: providersData) {
                    // 更新 providers - 只包含 HTTP 类型或有订阅信息的 provider
                    self.providers = providersResponse.providers.compactMap { name, provider in
                        // 只有当 vehicleType 为 HTTP 或有 subscriptionInfo 时才包含
                        guard provider.vehicleType == "HTTP" || provider.subscriptionInfo != nil else {
                            return nil
                        }
                        
                        return Provider(
                            name: name,
                            type: provider.type,
                            vehicleType: provider.vehicleType,
                            nodeCount: provider.proxies.count,
                            testUrl: provider.testUrl,
                            subscriptionInfo: provider.subscriptionInfo,
                            updatedAt: provider.updatedAt
                        )
                    }
                    
                    // 更新 providerNodes - 同样只包含符合条件的 provider
                    self.providerNodes = Dictionary(uniqueKeysWithValues: providersResponse.providers.compactMap { name, provider -> (String, [ProxyNode])? in
                        // 只有当 vehicleType 为 HTTP 或有 subscriptionInfo 时才包含
                        guard provider.vehicleType == "HTTP" || provider.subscriptionInfo != nil else {
                            return nil
                        }
                        
                        let nodes = provider.proxies.map { proxy in
                            ProxyNode(
                                id: proxy.id ?? UUID().uuidString,
                                name: proxy.name,
                                type: proxy.type,
                                alive: proxy.alive,
                                delay: proxy.history.last?.delay ?? 0,
                                history: proxy.history
                            )
                        }
                        return (name, nodes)
                    })
                    
                    // 收集所有 provider 中的节点
                    var allProviderNodes: [ProxyNode] = []
                    for (_, provider) in providersResponse.providers {
                        let nodes = provider.proxies.map { proxy in
                            ProxyNode(
                                id: proxy.id ?? UUID().uuidString,
                                name: proxy.name,
                                type: proxy.type,
                                alive: proxy.alive,
                                delay: proxy.history.last?.delay ?? 0,
                                history: proxy.history
                            )
                        }
                        allProviderNodes.append(contentsOf: nodes)
                    }
                    
                    // 4. 获取代理组数据
                    guard let proxiesRequest = makeRequest(path: "proxies") else { return }
                    let (proxiesData, _) = try await URLSession.shared.data(for: proxiesRequest)
                    
                    if let proxiesResponse = try? JSONDecoder().decode(ProxyResponse.self, from: proxiesData) {
                        // 5. 更新组数据
                        self.groups = proxiesResponse.proxies.compactMap { name, proxy in
                            guard proxy.all != nil else { return nil }
                            return ProxyGroup(
                                name: name,
                                type: proxy.type,
                                now: proxy.now ?? "",
                                all: proxy.all ?? []
                            )
                        }
                        
                        // 6. 合并所有节点数据
                        var allNodes: [ProxyNode] = []
                        
                        // 添加特殊节点
                        let specialNodes = ["DIRECT", "REJECT"].map { name in
                            // 尝试从现��节点中找到对应的特殊节点
                            if let existingNode = self.nodes.first(where: { $0.name == name }) {
                                return existingNode  // 如果找到，保留现有节点的所有信息（包括延迟）
                            }
                            // 如果是新建的节点，才使用默认值
                            return ProxyNode(
                                id: UUID().uuidString,
                                name: name,
                                type: "Special",
                                alive: true,
                                delay: 0,
                                history: []
                            )
                        }
                        allNodes.append(contentsOf: specialNodes)
                        
                        // 添加代理组节点
                        let groupNodes = proxiesResponse.proxies.compactMap { name, proxy -> ProxyNode? in
                            guard proxy.type == "Selector" || proxy.type == "URLTest" else { return nil }
                            return ProxyNode(
                                id: proxy.id ?? UUID().uuidString,
                                name: name,
                                type: proxy.type,
                                alive: proxy.alive,
                                delay: proxy.history.last?.delay ?? 0,
                                history: proxy.history
                            )
                        }
                        allNodes.append(contentsOf: groupNodes)
                        
                        // 添加所有 provider 中的实际代理节点
                        allNodes.append(contentsOf: allProviderNodes)
                        
                        // 更新 nodes 数组
                        self.nodes = allNodes
                    }
                }
            } catch {
                handleNetworkError(error)
            }
        }
    }
    
    func testGroupDelay(groupName: String, nodes: [ProxyNode]) async {
        for node in nodes {
            if node.name == "REJECT" || node.name == "DIRECT" {
                continue
            }
            
            let encodedGroupName = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName
            let path = "group/\(encodedGroupName)/delay"
            
            guard var request = makeRequest(path: path) else { continue }
            
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)
            components?.queryItems = [
                URLQueryItem(name: "url", value: defaultTestUrl),
                URLQueryItem(name: "timeout", value: "2000")
            ]
            
            guard let finalUrl = components?.url else { continue }
            request.url = finalUrl
            
            _ = await MainActor.run {
                testingNodes.insert(node.name)
            }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                // 检查 HTTPS 响应
                if server.useSSL,
                   let httpsResponse = response as? HTTPURLResponse,
                   httpsResponse.statusCode == 400 {
                    print("SSL 连接失败，服务器可能不支持 HTTPS")
                    continue
                }
                
                if let delays = try? JSONDecoder().decode([String: Int].self, from: data) {
                    _ = await MainActor.run {
                        for (nodeName, delay) in delays {
                            updateNodeDelay(nodeName: nodeName, delay: delay)
                        }
                        testingNodes.remove(node.name)
                    }
                }
            } catch {
                _ = await MainActor.run {
                    testingNodes.remove(node.name)
                }
                handleNetworkError(error)
            }
        }
    }
    
    private func handleNetworkError(_ error: Error) {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed:
                print("SSL 连接失败：服务器 SSL 证书无")
            case .serverCertificateHasBadDate:
                print("SSL 错误：服务器证书已过期")
            case .serverCertificateUntrusted:
                print("SSL 错误：服务器证书不受信任")
            case .serverCertificateNotYetValid:
                print("SSL 错误：服务器证书尚未生效")
            case .cannotConnectToHost:
                print("无法连接到服务器：\(server.useSSL ? "HTTPS" : "HTTP") 连接失败")
            default:
                print("网络错误：\(urlError.localizedDescription)")
            }
        } else {
            print("其他错误：\(error.localizedDescription)")
        }
    }
    
    func selectProxy(groupName: String, proxyName: String) async {
        let encodedGroupName = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName
        guard var request = makeRequest(path: "proxies/\(encodedGroupName)") else { return }
        
        request.httpMethod = "PUT"
        let body = ["name": proxyName]
        request.httpBody = try? JSONEncoder().encode(body)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if server.useSSL,
               let httpsResponse = response as? HTTPURLResponse,
               httpsResponse.statusCode == 400 {
                print("SSL 连接失败，服务器可能不支持 HTTPS")
                return
            }
            
            if proxyName != "REJECT" {
                await testNodeDelay(nodeName: proxyName)
            }
            await fetchProxies()
            
        } catch {
            handleNetworkError(error)
        }
    }
    
    // 添加新方用于测试单个节点延迟
    private func testNodeDelay(nodeName: String) async {
        let encodedNodeName = nodeName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nodeName
        guard var request = makeRequest(path: "proxies/\(encodedNodeName)/delay") else { return }
        
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "url", value: defaultTestUrl),
            URLQueryItem(name: "timeout", value: "2000")
        ]
        
        guard let finalUrl = components?.url else { return }
        request.url = finalUrl
        
        _ = await MainActor.run {
            testingNodes.insert(nodeName)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let delay = try? JSONDecoder().decode([String: Int].self, from: data).values.first {
                _ = await MainActor.run {
                    updateNodeDelay(nodeName: nodeName, delay: delay)
                    testingNodes.remove(nodeName)
                }
            }
        } catch {
            _ = await MainActor.run {
                testingNodes.remove(nodeName)
            }
            handleNetworkError(error)
        }
    }
    
    // 辅助法：更新节点延迟
    private func updateNodeDelay(nodeName: String, delay: Int) {
        // 更新 providerNodes 中的节点
        for (providerName, providerNodes) in self.providerNodes {
            self.providerNodes[providerName] = providerNodes.map { node in
                if node.name == nodeName {
                    return ProxyNode(
                        id: node.id,
                        name: node.name,
                        type: node.type,
                        alive: true,  // 如果有延迟数据，说明节点是活的
                        delay: delay,
                        history: node.history
                    )
                }
                return node
            }
        }
        
        // 更新 nodes 中的节点
        self.nodes = self.nodes.map { node in
            if node.name == nodeName {
                return ProxyNode(
                    id: node.id,
                    name: node.name,
                    type: node.type,
                    alive: true,  // 如果有延迟数据，说明节点是活跃的
                    delay: delay,
                    history: node.history
                )
            }
            return node
        }
        
        // 触发视图更新
        objectWillChange.send()
    }
    
    @MainActor
    func refreshAllData() async {
        do {
            // 1. 获取理数据
            await fetchProxies()
            
            // 2. 测试所有节点延迟
            for group in groups {
                if let nodes = providerNodes[group.name] {
                    await testGroupDelay(groupName: group.name, nodes: nodes)
                }
            }
        } catch {
            print("Error refreshing all data: \(error)")
        }
    }
    
    // 添加一个公开的组测速方法
    @MainActor
    func testGroupSpeed(groupName: String) async {
        let encodedGroupName = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName
        guard var request = makeRequest(path: "group/\(encodedGroupName)/delay") else { return }
        
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "url", value: defaultTestUrl),
            URLQueryItem(name: "timeout", value: "2000")
        ]
        
        guard let finalUrl = components?.url else { return }
        request.url = finalUrl
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // 检查 HTTPS 响应
            if server.useSSL,
               let httpsResponse = response as? HTTPURLResponse,
               httpsResponse.statusCode == 400 {
                print("SSL 连接失败，服务器可能不支持 HTTPS")
                return
            }
            
            if let decodedData = try? JSONDecoder().decode([String: Int].self, from: data) {
                for (nodeName, delay) in decodedData {
                    updateNodeDelay(nodeName: nodeName, delay: delay)
                }
            }
        } catch {
            handleNetworkError(error)
        }
    }
    
    @MainActor
    func updateProxyProvider(providerName: String) async {
        let encodedProviderName = providerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerName
        guard var request = makeRequest(path: "providers/proxies/\(encodedProviderName)") else { return }
        
        request.httpMethod = "PUT"
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if server.useSSL,
               let httpsResponse = response as? HTTPURLResponse,
               httpsResponse.statusCode == 400 {
                print("SSL 连接失败，服务器可能不支持 HTTPS")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                print("代理提供者 \(providerName) 更新成功")
                
                // 等待一小段时间确保服务器处理完成
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
                
                // 在主线程上更新
                await MainActor.run {
                    // 更新时间戳
                    self.lastUpdated = Date()
                    
                    // 刷数据
                    Task {
                        await self.fetchProxies()
                    }
                }
            } else {
                print("代理提供者 \(providerName) 更新失败")
            }
        } catch {
            handleNetworkError(error)
        }
    }
    
    // 代理提供者整体健康检查
    @MainActor
    func healthCheckProvider(providerName: String) async {
        let encodedProviderName = providerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerName
        guard let request = makeRequest(path: "providers/proxies/\(encodedProviderName)/healthcheck") else { return }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if server.useSSL,
               let httpsResponse = response as? HTTPURLResponse,
               httpsResponse.statusCode == 400 {
                print("SSL 连接失败，服务器可能不支持 HTTPS")
                return
            }
            
            // 等待一小段时间确保服务器处理完成
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            
            // 在主线程上刷新数据
            await MainActor.run {
                Task {
                    await self.fetchProxies()
                    self.lastDelayTestTime = Date()
                    objectWillChange.send()
                }
            }
            
        } catch {
            handleNetworkError(error)
        }
    }
    
    // 代理提供��中单个节点的健康检查
    @MainActor
    func healthCheckProviderProxy(providerName: String, proxyName: String) async {
        let encodedProviderName = providerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerName
        let encodedProxyName = proxyName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proxyName
        
        guard var request = makeRequest(path: "providers/proxies/\(encodedProviderName)/\(encodedProxyName)/healthcheck") else { return }
        
        // 添加查询参数，使用默认测试 URL
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "url", value: defaultTestUrl),
            URLQueryItem(name: "timeout", value: "5000")
        ]
        
        guard let finalUrl = components?.url else { return }
        request.url = finalUrl
        
        // 设置测试状态
        await MainActor.run {
            testingNodes.insert(proxyName)
            objectWillChange.send()
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if server.useSSL,
               let httpsResponse = response as? HTTPURLResponse,
               httpsResponse.statusCode == 400 {
                print("SSL 连接失败，服务器可能不支持 HTTPS")
                _ = await MainActor.run {
                    testingNodes.remove(proxyName)
                    objectWillChange.send()
                }
                return
            }
            
            // 解析返回的延迟数据
            struct DelayResponse: Codable {
                let delay: Int
            }
            
            if let delayResponse = try? JSONDecoder().decode(DelayResponse.self, from: data) {
                await MainActor.run {
                    // 更新节点延迟
                    updateNodeDelay(nodeName: proxyName, delay: delayResponse.delay)
                    testingNodes.remove(proxyName)
                    self.lastDelayTestTime = Date()  // 触发视图更新
                    objectWillChange.send()
                    
                    // 刷新数据
                    Task {
                        await self.fetchProxies()
                    }
                }
            } else {
                // 如果解析失败，确保移除节点名称
                await MainActor.run {
                    testingNodes.remove(proxyName)
                    objectWillChange.send()
                }
            }
            
        } catch {
            _ = await MainActor.run {
                testingNodes.remove(proxyName)
                objectWillChange.send()
            }
            handleNetworkError(error)
        }
    }
    
    // 添加保存自定义顺序的方法
    func saveCustomOrder() {
        let orderDict = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.name, $0.offset) })
        UserDefaults.standard.set(orderDict, forKey: customOrderKey)
    }
    
    // 添加获取排序后的组的方法
    func getSortedGroups() -> [ProxyGroup] {
        if isSortMode {
            // 在排序模式下使用保存的自定义顺序
            if let savedOrder = UserDefaults.standard.dictionary(forKey: customOrderKey) as? [String: Int] {
                let allGroupsPresent = groups.allSatisfy { savedOrder[$0.name] != nil }
                
                if allGroupsPresent {
                    return groups.sorted { 
                        savedOrder[$0.name] ?? 0 < savedOrder[$1.name] ?? 0 
                    }
                }
            }
        }
        
        // 获取 GLOBAL 组的排序索引
        if let globalGroup = groups.first(where: { $0.name == "GLOBAL" }) {
            var sortIndex = globalGroup.all
            sortIndex.append("GLOBAL") // 将 GLOBAL 添加到末尾
            
            return groups.sorted { group1, group2 in
                let index1 = sortIndex.firstIndex(of: group1.name) ?? Int.max
                let index2 = sortIndex.firstIndex(of: group2.name) ?? Int.max
                return index1 < index2
            }
        }
        
        // 如果找不到 GLOBAL 组或其他情况，使用字母顺序
        return groups.sorted { $0.name < $1.name }
    }
}

// API 响应模型
struct ProxyResponse: Codable {
    let proxies: [String: ProxyDetail]
}

struct ProxyDetail: Codable {
    let name: String
    let type: String
    let alive: Bool
    let now: String?
    let all: [String]?
    let history: [ProxyHistory]
    let id: String?
}

// 添加 ProviderResponse 结构体
struct ProviderResponse: Codable {
    let type: String
    let vehicleType: String
    let proxies: [ProxyInfo]?
    let testUrl: String?
    let subscriptionInfo: SubscriptionInfo?
    let updatedAt: String?
}

// 添加 Extra 结构体定义
struct Extra: Codable {
    let alpn: [String]?
    let tls: Bool?
    let skip_cert_verify: Bool?
    let servername: String?
}

struct ProxyInfo: Codable {
    let name: String
    let type: String
    let alive: Bool
    let history: [ProxyHistory]
    let extra: Extra?
    let id: String?
    let tfo: Bool?
    let xudp: Bool?
    
    private enum CodingKeys: String, CodingKey {
        case name, type, alive, history, extra, id, tfo, xudp
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        alive = try container.decode(Bool.self, forKey: .alive)
        history = try container.decode([ProxyHistory].self, forKey: .history)
        
        // Meta 服务器特有的字段设为可选
        extra = try container.decodeIfPresent(Extra.self, forKey: .extra)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        tfo = try container.decodeIfPresent(Bool.self, forKey: .tfo)
        xudp = try container.decodeIfPresent(Bool.self, forKey: .xudp)
    }
    
    // 添加编码方法
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(alive, forKey: .alive)
        try container.encode(history, forKey: .history)
        try container.encodeIfPresent(extra, forKey: .extra)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(tfo, forKey: .tfo)
        try container.encodeIfPresent(xudp, forKey: .xudp)
    }
} 
