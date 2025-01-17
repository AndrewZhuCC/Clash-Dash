import SwiftUI
import Charts

struct SpeedChartView: View {
    let speedHistory: [SpeedRecord]
    @AppStorage("speedChartStyle") private var speedChartStyle = SpeedChartStyle.line
    
    var body: some View {
        Group {
            switch speedChartStyle {
            case .line:
                LineChartView(speedHistory: speedHistory)
            case .bar:
                SpeedBarChartView(speedHistory: speedHistory)
            }
        }
    }
}

// 将原来的实现移到新的 LineChartView 中
private struct LineChartView: View {
    let speedHistory: [SpeedRecord]
    @State private var now = Date()
    
    // 固定显示最近的30条数据，并反转顺序
    private var displayData: [SpeedRecord] {
        Array(speedHistory.suffix(30)).reversed()
    }
    
    // 使用时间戳进行插值
    private var interpolatedData: [(index: Double, record: SpeedRecord)] {
        guard displayData.count >= 2 else { return [] }
        
        var result: [(index: Double, record: SpeedRecord)] = []
        let totalDuration: TimeInterval = 30 // 总显示时间范围（秒）
        
        // 计算当前时间到最早记录的时间差
        if let firstTime = displayData.last?.timestamp {
            let elapsedTime = now.timeIntervalSince(firstTime)
            
            // 对每个数据点计算其相对位置
            for i in 0..<displayData.count {
                let record = displayData[i]
                let timeOffset = now.timeIntervalSince(record.timestamp)
                let position = 60.0 * (1 - timeOffset / totalDuration)  // 扩大范围到60
                
                if position >= 0 && position <= 60 {  // 扩大判断范围
                    result.append((position, record))
                }
            }
        }
        
        return result
    }
    
    private var maxValue: Double {
        let maxUpload = speedHistory.map { $0.upload }.max() ?? 0
        let maxDownload = speedHistory.map { $0.download }.max() ?? 0
        let currentMax = max(maxUpload, maxDownload)
        
        if currentMax < 2_000 {
            return 2_000
        }
        
        let magnitude = pow(10, floor(log10(currentMax)))
        let normalized = currentMax / magnitude
        
        let scale: Double
        if normalized <= 1 {
            scale = 1
        } else if normalized <= 2 {
            scale = 2
        } else if normalized <= 5 {
            scale = 5
        } else {
            scale = 10
        }
        
        return magnitude * scale * 1.2
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        if speed >= 1_000_000 {
            return String(format: "%.1f MB/s", speed / 1_000_000)
        } else if speed >= 1_000 {
            return String(format: "%.1f KB/s", speed / 1_000)
        } else {
            return String(format: "%.0f B/s", speed)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                Text("速率图表")
                    .font(.headline)
            }
            
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // 图表区域
                    Chart {
                        // 网格线
                        ForEach(Array(stride(from: 0, to: maxValue, by: maxValue/4)), id: \.self) { value in
                            RuleMark(
                                y: .value("Speed", value)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(.gray.opacity(0.1))
                        }
                        
                        // 上传数据
                        ForEach(interpolatedData, id: \.index) { item in
                            LineMark(
                                x: .value("Index", item.index),
                                y: .value("Speed", item.record.upload),
                                series: .value("Type", "上传")
                            )
                            .foregroundStyle(.green)
                            .interpolationMethod(.cardinal)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            
                            AreaMark(
                                x: .value("Index", item.index),
                                yStart: .value("Speed", 0),
                                yEnd: .value("Speed", item.record.upload),
                                series: .value("Type", "上传")
                            )
                            .foregroundStyle(.green.opacity(0.1))
                            .interpolationMethod(.cardinal)
                        }
                        
                        // 下载数据
                        ForEach(interpolatedData, id: \.index) { item in
                            LineMark(
                                x: .value("Index", item.index),
                                y: .value("Speed", item.record.download),
                                series: .value("Type", "下载")
                            )
                            .foregroundStyle(.blue)
                            .interpolationMethod(.cardinal)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            
                            AreaMark(
                                x: .value("Index", item.index),
                                yStart: .value("Speed", 0),
                                yEnd: .value("Speed", item.record.download),
                                series: .value("Type", "下载")
                            )
                            .foregroundStyle(.blue.opacity(0.1))
                            .interpolationMethod(.cardinal)
                        }
                    }
                    .frame(width: geometry.size.width * 2)  // 图表宽度是容器的两倍
                    .offset(x: -geometry.size.width * 0.5)  // 向左偏移半个容器宽度
                    .chartYScale(domain: 0...maxValue)
                    .chartXAxis {
                        // 隐藏X轴标签，因为索引数字对用户没有意义
                        AxisMarks { _ in
                            AxisGridLine()
                                .foregroundStyle(.clear)
                            AxisTick()
                                .foregroundStyle(.clear)
                            AxisValueLabel("")
                        }
                    }
                    .chartXScale(domain: 0...60)  // 扩大X轴范围
                }
                .clipped()  // 裁剪超出部分
                
                // Y轴标签（叠加在图表上）
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stride(from: maxValue, through: 0, by: -maxValue/4)), id: \.self) { value in
                        Text(formatSpeed(value))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxHeight: .infinity)  // 让每个标签平均分配空间
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)  // 使用完整高度
                .padding(.leading, 8)
            }
            .frame(height: 200)
            
            // 图例
            HStack {
                Label("下载", systemImage: "circle.fill")
                    .foregroundColor(.blue)
                Label("上传", systemImage: "circle.fill")
                    .foregroundColor(.green)
            }
            .font(.caption)
        }
        .onAppear {
            // 启动定时器以更新当前时间
            let timer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { _ in
                now = Date()
            }
            timer.tolerance = 1/60
        }
    }
} 