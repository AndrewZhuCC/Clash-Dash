import SwiftUI
import UIKit
import SafariServices
import Network
import NetworkExtension

struct ContentView: View {
    @StateObject private var viewModel: ServerViewModel
    @StateObject private var settingsViewModel = SettingsViewModel()
    @State private var showingAddSheet = false
    @State private var editingServer: ClashServer?
    @State private var selectedQuickLaunchServer: ClashServer?
    @State private var showQuickLaunchDestination = false
    @State private var showingAddOpenWRTSheet = false
    @State private var showingModeChangeSuccess = false
    @State private var lastChangedMode = ""
    @State private var showingSourceCode = false
    @State private var currentWiFiSSID: String = ""
    @State private var forceRefresh: Bool = false  // 添加强制刷新标志
    @AppStorage("appThemeMode") private var appThemeMode = AppThemeMode.system
    @AppStorage("hideDisconnectedServers") private var hideDisconnectedServers = false
    @AppStorage("enableWiFiBinding") private var enableWiFiBinding = false
    @Environment(\.scenePhase) private var scenePhase
    
    // 使用 EnvironmentObject 来共享 WiFiBindingManager
    @EnvironmentObject private var bindingManager: WiFiBindingManager

    private let logger = LogManager.shared

    init() {
        _viewModel = StateObject(wrappedValue: ServerViewModel())
    }

    // 添加触觉反馈生成器
    
    
    // 添加过滤后的服务器列表计算属性
    private var filteredServers: [ClashServer] {
        // 使用 forceRefresh 来强制重新计算，但不使用它的值
        _ = forceRefresh
        
        // 使用 isServerHidden 方法来过滤服务器
        return viewModel.servers.filter { server in
            !viewModel.isServerHidden(server, currentWiFiSSID: currentWiFiSSID)
        }
    }
    
    // 添加隐藏的服务器列表计算属性
    private var hiddenServers: [ClashServer] {
        return viewModel.servers.filter { server in
            viewModel.isServerHidden(server, currentWiFiSSID: currentWiFiSSID)
        }
    }
    
    // 添加展开/收起状态
    @State private var showHiddenServers = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.servers.isEmpty {
                        // 真正的空状态（没有任何服务器）
                        VStack(spacing: 20) {
                            Spacer()
                                .frame(height: 60)
                            
                            Image(systemName: "server.rack")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary.opacity(0.7))
                                .padding(.bottom, 10)
                            
                            Text("没有控制器")
                                .font(.title2)
                                .fontWeight(.medium)
                            
                            Text("点击添加按钮来添加一个新的控制器")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            
                            Menu {
                                Button(action: {
                                    HapticManager.shared.impact(.light)
                                    showingAddSheet = true
                                }) {
                                    Label("添加控制器", systemImage: "plus.circle")
                                }
                            } label: {
                                Text("添加控制器")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 160, height: 44)
                                    .background(Color.blue)
                                    .cornerRadius(22)
                                    .onTapGesture {
                                        HapticManager.shared.impact(.light)
                                    }
                            }
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                        }
                    } else if filteredServers.isEmpty && !viewModel.servers.isEmpty {
                        // 所有服务器都被过滤掉的状态
                        VStack(spacing: 20) {
                            Spacer()
                                .frame(height: 60)
                            
                            Image(systemName: "server.rack")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary.opacity(0.7))
                                .padding(.bottom, 10)
                            
                            if hideDisconnectedServers {
                                Text("所有控制器已被自动隐藏")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                Text("请在外观设置中关闭隐藏无法连接的控制器来显示全部控制器")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                    .padding(.bottom, 40)
                            } else {
                                Text("当前 Wi-Fi 下没有绑定的控制器")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                Text("您可以在 Wi-Fi 绑定设置中添加控制器")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                    .padding(.bottom, 40)
                            }
                        }
                    } else {
                        // 显示过滤后的服务器列表
                        ForEach(filteredServers) { server in
                            NavigationLink {
                                ServerDetailView(server: server)
                                    .onAppear {
                                        // 添加触觉反馈
                                        HapticManager.shared.impact(.light)
                                    }
                            } label: {
                                ServerRowView(server: server)
                                    .serverContextMenu(
                                        viewModel: viewModel,
                                        settingsViewModel: settingsViewModel,
                                        server: server,
                                        onEdit: { editingServer = server },
                                        onModeChange: { mode in showModeChangeSuccess(mode: mode) },
                                        onShowConfigSubscription: { showConfigSubscriptionView(for: server) },
                                        onShowSwitchConfig: { showSwitchConfigView(for: server) },
                                        onShowCustomRules: { showCustomRulesView(for: server) },
                                        onShowRestartService: { showRestartServiceView(for: server) }
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .onTapGesture {
                                HapticManager.shared.impact(.light)
                            }
                        }
                        
                        // 添加隐藏控制器展开/收起部分
                        if !hiddenServers.isEmpty {
                            Button(action: {
                                withAnimation {
                                    showHiddenServers.toggle()
                                    HapticManager.shared.impact(.light)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: showHiddenServers ? "chevron.up" : "chevron.down")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(showHiddenServers ? "收起隐藏的 \(hiddenServers.count) 个控制器" : "展开隐藏的 \(hiddenServers.count) 个控制器")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                            .padding(.top, 4)
                            
                            if showHiddenServers {
                                VStack(spacing: 12) {
                                    ForEach(hiddenServers) { server in
                                        NavigationLink {
                                            ServerDetailView(server: server)
                                                .onAppear {
                                                    HapticManager.shared.impact(.light)
                                                }
                                        } label: {
                                            ServerRowView(server: server)
                                                .serverContextMenu(
                                                    viewModel: viewModel,
                                                    settingsViewModel: settingsViewModel,
                                                    server: server,
                                                    showMoveOptions: false,  // 禁用移动选项
                                                    onEdit: { editingServer = server },
                                                    onModeChange: { mode in showModeChangeSuccess(mode: mode) },
                                                    onShowConfigSubscription: { showConfigSubscriptionView(for: server) },
                                                    onShowSwitchConfig: { showSwitchConfigView(for: server) },
                                                    onShowCustomRules: { showCustomRulesView(for: server) },
                                                    onShowRestartService: { showRestartServiceView(for: server) }
                                                )
                                                .opacity(0.6)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .onTapGesture {
                                            HapticManager.shared.impact(.light)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // 设置卡片
                    VStack(spacing: 16) {
                        SettingsLinkRow(
                            title: "全局配置",
                            icon: "gearshape.fill",
                            iconColor: .gray,
                            destination: GlobalSettingsView()
                        )
                        
                        SettingsLinkRow(
                            title: "外观设置",
                            icon: "paintbrush.fill",
                            iconColor: .cyan,
                            destination: AppearanceSettingsView()
                        )
                        
                        SettingsLinkRow(
                            title: "运行日志",
                            icon: "doc.text.fill",
                            iconColor: .orange,
                            destination: LogsView()
                        )
                        
                        SettingsLinkRow(
                            title: "如何使用",
                            icon: "questionmark.circle.fill",
                            iconColor: .blue,
                            destination: HelpView()
                        )
                        
                        Button {
                            HapticManager.shared.impact(.light)
                            showingSourceCode = true
                        } label: {
                            HStack {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .font(.body)
                                    .foregroundColor(.purple)
                                    .frame(width: 32)
                                
                                Text("源码查看")
                                    .font(.body)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    
                    // 版本信息
                    Text("Ver: 1.3.2 Build 5")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                        .padding(.top, 8)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Clash Dash")
            .navigationDestination(isPresented: $showQuickLaunchDestination) {
                if let server = selectedQuickLaunchServer ?? viewModel.servers.first {
                    ServerDetailView(server: server)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        HapticManager.shared.impact(.light)
                        showingAddSheet = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddServerView(viewModel: viewModel)
            }
            .sheet(item: $editingServer) { server in
                EditServerView(viewModel: viewModel, server: server)
            }
            .sheet(isPresented: $showingSourceCode) {
                if let url = URL(string: "https://github.com/bin64/Clash-Dash") {
                    SafariWebView(url: url)
                        .ignoresSafeArea()
                }
            }
            .refreshable {
                await viewModel.checkAllServersStatus()
            }
            .alert("连接错误", isPresented: $viewModel.showError) {
                Button("确定", role: .cancel) {}
            } message: {
                if let details = viewModel.errorDetails {
                    Text("\(viewModel.errorMessage ?? "")\n\n\(details)")
                } else {
                    Text(viewModel.errorMessage ?? "")
                }
            }
            .overlay(alignment: .bottom) {
                if showingModeChangeSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                        Text("已切换至\(ModeUtils.getModeText(lastChangedMode))")
                            .foregroundColor(.primary)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground))
                    .cornerRadius(25)
                    .shadow(radius: 10, x: 0, y: 5)
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            // print("🎬 ContentView 出现")
            // 获取当前 Wi-Fi SSID
            if enableWiFiBinding {
                NEHotspotNetwork.fetchCurrent { network in
                    if let network = network {
                        logger.debug("检测到 Wi-Fi: \(network.ssid)")
                        currentWiFiSSID = network.ssid
                    } else {
                        logger.debug("未检测到 Wi-Fi 连接")
                        currentWiFiSSID = ""
                    }
                }
            } else {
                logger.debug("Wi-Fi 绑定功能未启用，跳过获取 Wi-Fi 信息")
                currentWiFiSSID = ""
            }
            
            // 首次打开时刷新服务器列表
            Task {
                await viewModel.checkAllServersStatus()
            }
            
            if let quickLaunchServer = viewModel.servers.first(where: { $0.isQuickLaunch }) {
                selectedQuickLaunchServer = quickLaunchServer
                showQuickLaunchDestination = true
            }
            
            viewModel.setBingingManager(bindingManager)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // print("🔄 应用进入活动状态")
                // 从后台返回前台时刷新服务器列表和 Wi-Fi 状态
                Task {
                    await viewModel.checkAllServersStatus()
                }
                
                // 更新当前 Wi-Fi SSID
                if enableWiFiBinding {
                    NEHotspotNetwork.fetchCurrent { network in
                        if let network = network {
                            // print("📡 检测到 Wi-Fi (后台恢复): \(network.ssid)")
                            currentWiFiSSID = network.ssid
                        } else {
                            // print("❌ 未检测到 Wi-Fi 连接 (后台恢复)")
                            currentWiFiSSID = ""
                        }
                    }
                } else {
                    // print("⚠️ Wi-Fi 绑定功能未启用，跳过获取 Wi-Fi 信息")
                    currentWiFiSSID = ""
                }
            }
        }
        // 添加对 enableWiFiBinding 变化的监听
        .onChange(of: enableWiFiBinding) { newValue in
            if newValue {
                // 功能启用时获取 Wi-Fi 信息
                NEHotspotNetwork.fetchCurrent { network in
                    if let network = network {
                        // print("📡 检测到 Wi-Fi (功能启用): \(network.ssid)")
                        currentWiFiSSID = network.ssid
                    } else {
                        // print("❌ 未检测到 Wi-Fi 连接 (功能启用)")
                        currentWiFiSSID = ""
                    }
                }
            } else {
                print("⚠️ Wi-Fi 绑定功能已禁用，清空 Wi-Fi 信息")
                currentWiFiSSID = ""
            }
        }
        // 添加对 WiFiBindingManager 变化的监听
        .onChange(of: bindingManager.bindings) { newBindings in
            print("📝 Wi-Fi 绑定发生变化，新的绑定数量: \(newBindings.count)")
            logger.debug("Wi-Fi 绑定发生变化，新的绑定数量: \(newBindings.count)")
            // 强制刷新 filteredServers
            withAnimation {
                // print("🔄 触发强制刷新")
                forceRefresh.toggle()  // 切换强制刷新标志
            }
            // 刷新服务器状态
            Task {
                // print("🔄 开始刷新服务器状态")
                await viewModel.checkAllServersStatus()
                // print("✅ 服务器状态刷新完成")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ControllersUpdated"))) { _ in
            Task { @MainActor in
                await viewModel.loadServers()
                // 添加触觉反馈
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
            }
        }
    }
    
    private func showSwitchConfigView(for server: ClashServer) {
        editingServer = nil  // 清除编辑状态
        let configView = OpenClashConfigView(viewModel: viewModel, server: server)
        let sheet = UIHostingController(rootView: configView)
        
        // 设置 sheet 的首选样式
        sheet.modalPresentationStyle = .formSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        
        // 获取当前的 window scene
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(sheet, animated: true)
        }
    }
    
    private func showConfigSubscriptionView(for server: ClashServer) {
        editingServer = nil  // 清除编辑状态
        let configView = ConfigSubscriptionView(server: server)
        let sheet = UIHostingController(rootView: configView)
        
        // 设置 sheet 的首选样式
        sheet.modalPresentationStyle = .formSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        
        // 获取当前的 window scene
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(sheet, animated: true)
        }
    }
    
    private func showCustomRulesView(for server: ClashServer) {
        editingServer = nil  // 清除编辑状态
        let rulesView = OpenClashRulesView(server: server)
        let sheet = UIHostingController(rootView: rulesView)
        
        sheet.modalPresentationStyle = .formSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        sheet.sheetPresentationController?.selectedDetentIdentifier = .medium
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(sheet, animated: true)
        }
    }
    
    private func showRestartServiceView(for server: ClashServer) {
        editingServer = nil  // 清除编辑状态
        let restartView = RestartServiceView(viewModel: viewModel, server: server)
        let sheet = UIHostingController(rootView: restartView)
        
        sheet.modalPresentationStyle = .formSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(sheet, animated: true)
        }
    }
    
    private func showModeChangeSuccess(mode: String) {
        lastChangedMode = mode
        withAnimation {
            showingModeChangeSuccess = true
        }
        // 2 秒后隐藏提示
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showingModeChangeSuccess = false
            }
        }
    }
    
    private var colorScheme: ColorScheme? {
        switch appThemeMode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil
        }
    }
}

struct SettingsLinkRow<Destination: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    let destination: Destination
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(iconColor)
                    .frame(width: 32)
                
                Text(title)
                    .font(.body)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WiFiBindingManager())  // 为预览提供一个环境对象
}

