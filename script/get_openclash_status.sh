#!/bin/bash
# 打印带有表情符号的日志函数
log() {
    local level="$1"
    local message="$2"
    case "$level" in
        "info")
            echo "🔍 $message"
            ;;
        "error")
            echo "❌ $message"
            ;;
        "success")
            echo "✅ $message"
            ;;
        "send")
            echo "📤 $message"
            ;;
        "receive")
            echo "📥 $message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# 打印请求信息函数
print_request() {
    local method="$1"
    local url="$2"
    local headers="$3"
    local data="$4"

    echo "========================= 请求信息 ========================="
    echo "Method: $method"
    echo "URL: $url"
    echo "Headers:"
    echo "$headers" | while IFS= read -r line; do
        echo "  $line"
    done
    if [ ! -z "$data" ]; then
        echo "Request Body:"
        echo "$data" | python3 -m json.tool 2>/dev/null || echo "$data"
    fi
    echo "========================================================="
}

# 提示用户输入信息
read -p "请输入IP地址: " ip
read -p "请输入端口(默认80): " port
port=${port:-80}
read -p "请输入用户名: " username
read -p "请输入密码: " password

# 构建基础URL
base_url="http://$ip:$port"
log "info" "开始验证 OpenWRT 服务器: $base_url"

# 1. 使用 JSON-RPC 登录
login_url="$base_url/cgi-bin/luci/rpc/auth"
log "info" "登录 URL: $login_url"

# 构建 JSON-RPC 请求体
json_data="{\"id\":1,\"method\":\"login\",\"params\":[\"$username\",\"$password\"]}"

log "send" "发送 JSON-RPC 登录请求"
# 构建登录请求头
login_headers="Content-Type: application/json
Accept: application/json
Connection: keep-alive
User-Agent: curl"

# 打印登录请求信息
print_request "POST" "$login_url" "$login_headers" "$json_data"

# 发送登录请求
response=$(curl -s --max-redirs 0 -w "\n%{http_code}" \
    -X POST "$login_url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Connection: keep-alive" \
    -H "User-Agent: curl" \
    -d "$json_data")

# 提取响应体和状态码
response_body=$(echo "$response" | head -n 1)
status_code=$(echo "$response" | tail -n 1)

log "receive" "登录响应状态码: $status_code"
log "receive" "JSON-RPC 登录响应: $response_body"

# 处理响应状态码
case $status_code in
    200)
        # 从 JSON 响应中提取 token
        token=$(echo "$response_body" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        
        if [ -z "$token" ]; then
            error_message=$(echo "$response_body" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)
            if [ ! -z "$error_message" ]; then
                log "error" "JSON-RPC 错误: $error_message"
                exit 1
            fi
            log "error" "无效的响应结果"
            log "receive" "原始响应内容: $response_body"
            exit 1
        fi
        
        log "success" "获取到认证令牌: $token"
        
        # 2. 获取 OpenClash 状态
        timestamp=$(date +%s%3N)
        status_url="$base_url/cgi-bin/luci/admin/services/openclash/status?$timestamp"
        log "send" "发送状态请求: $status_url"
        
        # 构建状态请求头
        status_headers="Cookie: sysauth_http=$token
Accept: */*
Connection: keep-alive
User-Agent: curl
Cache-Control: no-cache
Pragma: no-cache"

        # 打印状态请求信息
        print_request "GET" "$status_url" "$status_headers"
        
        status_response=$(curl -s --max-redirs 0 -w "\n%{http_code}" \
            -H "Cookie: sysauth_http=$token" \
            -H "Accept: */*" \
            -H "Connection: keep-alive" \
            -H "User-Agent: curl" \
            -H "Cache-Control: no-cache" \
            -H "Pragma: no-cache" \
            "$status_url")
        
        status_body=$(echo "$status_response" | head -n 1)
        status_code=$(echo "$status_response" | tail -n 1)
        
        log "receive" "状态响应状态码: $status_code"
        log "receive" "OpenClash 状态响应: $status_body"
        
        case $status_code in
            200)
                log "success" "获取状态成功"
                ;;
            403)
                log "error" "认证令牌已过期"
                exit 1
                ;;
            *)
                log "error" "状态请求失败: $status_code"
                exit 1
                ;;
        esac
        ;;
        
    404)
        log "error" "OpenWRT 缺少必要的依赖"
        cat << EOF
请确保已经安装以下软件包：
1. luci-mod-rpc
2. luci-lib-ipkg
3. luci-compat

可以通过以下命令安装：
opkg update
opkg install luci-mod-rpc luci-lib-ipkg luci-compat

并重启 uhttpd：
/etc/init.d/uhttpd restart
EOF
        exit 1
        ;;
        
    *)
        log "error" "登录失败：状态码 $status_code"
        exit 1
        ;;
esac