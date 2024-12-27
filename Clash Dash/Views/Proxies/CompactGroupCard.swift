import SwiftUI

struct CompactGroupCard: View {
    let group: ProxyGroup
    @ObservedObject var viewModel: ProxyViewModel
    @State private var showProxySelector = false
    
    var body: some View {
        Button {
            if group.type != "URLTest" {
                showProxySelector = true
            }
        } label: {
            HStack(spacing: 16) {
                // 左侧图标和名称
                HStack(spacing: 12) {
                    // 图标部分
                    Group {
                        if let iconUrl = group.icon, !iconUrl.isEmpty {
                            CachedAsyncImage(url: iconUrl)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            let firstLetter = String(group.name.prefix(1)).uppercased()
                            Text(firstLetter)
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 36, height: 36)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.system(.body, design: .default))
                            .fontWeight(.semibold)
                        
                        Text(group.now)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fontWeight(.medium)
                    }
                }
                
                Spacer()
                
                // 右侧状态
                HStack(alignment: .center, spacing: 0) {
                    Spacer()
                        .frame(width: 50)
                    
                    // 竖条分隔符
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 3, height: 30)
                        .opacity(0.3)
                        .padding(.trailing, 10)
                    
                    // 节点数量和箭头容器
                    HStack(spacing: 10) {
                        Text("\(group.all.count)")
//                            .font(.system(.body, design: .rounded))
                            .fontWeight(.medium)
                            .font(.system(size: 16, design: .rounded))
                            .foregroundStyle(.secondary)
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(.tertiaryLabel))
                            .fontWeight(.bold)
                    }
                    .frame(width: 55, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(height: 64)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.03), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showProxySelector) {
            ProxySelectorSheet(group: group, viewModel: viewModel)
        }
        // .onAppear {
        //     print("📱 CompactGroupCard 已加载, 组名: \(group.name), 是否有图标: \(group.icon != nil)")
        // }
    }
}

#Preview {
    CompactGroupCard(
        group: ProxyGroup(
            name: "测试组",
            type: "Selector",
            now: "测试节点",
            all: ["节点1", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2", "节点2"],
            alive: true,
            icon: nil
        ),
        viewModel: ProxyViewModel(
            server: ClashServer(
                name: "测试服务器",
                url: "localhost",
                port: "9090",
                secret: "123456"
            )
        )
    )
    .padding()
} 
