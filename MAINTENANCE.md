# ws-tool Maintenance Guide

本文是 `ws-tool` 的维护文档，面向后续继续扩展 fancyss WebSocket 通道能力的开发者。

目标：

- 说明 `ws-tool` 当前替代了 upstream `websocketd` 的哪些能力
- 说明 fancyss 当前真正依赖的兼容面
- 说明后续如果要扩展功能，应优先保证什么不回归

---

## 1. 项目定位

`ws-tool` 不是完整重写 upstream `websocketd` 的全部功能。

它当前的定位是：

- 一个面向 fancyss 使用场景的轻量级 `websocketd` 替代实现
- 重点优化：
  - 二进制体积
  - 路由器弱性能平台启动负担
  - 与 fancyss 现有脚本接口的兼容性

因此，维护时应优先遵守：

1. fancyss 实际用到什么，就优先保证什么
2. 不为了追求 upstream 全兼容，而提前把复杂度做高
3. 二进制名字保持 `websocketd`
4. 命令行兼容面优先保守扩展，不随意改现有参数语义

---

## 2. 当前兼容范围

### 2.1 已支持的 CLI

当前已经支持：

- `websocketd --port=803 /koolshare/ss/websocket`
- `websocketd --port 803 /koolshare/ss/websocket`
- `websocketd --address 0.0.0.0 --port 803 /koolshare/ss/websocket`
- `websocketd --passenv PATH,DYLD_LIBRARY_PATH --port 803 /koolshare/ss/websocket`
- `websocketd --help`
- `websocketd --version`

### 2.2 当前协议行为

当前实现的是：

1. 监听一个 TCP 地址和端口
2. 接收 HTTP/1.1 请求
3. 如果收到 WebSocket Upgrade，则升级连接
4. 为每个 WebSocket 连接启动一个子进程
5. WebSocket 收到的 `text/binary` 消息：
   - 原样写入子进程 `stdin`
   - 末尾自动追加换行
6. 子进程的 `stdout/stderr`：
   - 按行切分
   - 每行作为一个 WebSocket `text` 帧返回

### 2.3 当前已验证的 fancyss 消息场景

已在 GS7 / TUF-AX3000 上用 fancyss 实际脚本验证：

- `echo ws_ok`
- `show_message`
- `cat /tmp/upload/ss_log.txt`
- `. script arg`
- `follow_webtest`

也就是说：

- fancyss 目前前端通过 WebSocket 发送的主要消息模式，当前都已经覆盖

---

## 3. fancyss 侧真实依赖点

维护时首先要理解：

- `ws-tool` 的兼容目标不是 upstream 示例
- 而是 fancyss 页面和 `/koolshare/ss/websocket` 这个脚本

### 3.1 fancyss 前端当前依赖的行为

前端主要依赖：

1. 连接 `ws://<router>:803/`
2. 建连成功后发送一条文本消息
3. 服务端按行回推文本结果

前端当前不会依赖：

- 二进制帧
- 多路 HTTP 路由
- 静态资源分发
- TLS 终止

### 3.2 `/koolshare/ss/websocket` 当前依赖的环境变量

当前已确认脚本会用到或展示：

- `REMOTE_ADDR`
- `REMOTE_PORT`
- `SERVER_NAME`
- `HTTP_USER_AGENT`
- 常见 CGI/HTTP 环境变量

因此后续维护必须保证：

- 这些环境变量继续传递给子进程

### 3.3 `stdin/stdout` 语义

当前 `/koolshare/ss/websocket` 的工作方式是：

- 从 `stdin` 按行读取消息
- 根据消息执行脚本或输出文本
- 从 `stdout` 连续输出结果

所以维护时需要保证：

- 一条 WebSocket 消息会被转换成子进程的一行输入
- 子进程一行输出会被转换成一个 WebSocket 文本帧

这条语义是当前兼容的核心。

---

## 4. 当前未实现的 upstream 能力

以下能力当前明确不做：

- TLS / HTTPS 终止
- 静态文件服务
- `--binary`
- `--devconsole`
- 多脚本/多路由分发
- upstream 全量环境变量和监控能力

如果将来 fancyss 也不需要这些能力，就不建议为了“看起来更像 upstream”而补做。

---

## 5. 当前实现结构

### 5.1 监听层

使用 Zig 标准库：

- `std.net.Address.listen`
- `std.net.Server.accept`

每个 TCP 连接起一个线程处理。

### 5.2 HTTP / WebSocket 升级

当前使用 Zig 标准库：

- `std.http.Server`
- `request.upgradeRequested()`
- `request.respondWebSocket()`

因此：

- 不需要自己手写 `Sec-WebSocket-Accept`
- 可以减少握手错误面

### 5.3 子进程模型

每个 WebSocket 连接启动一个 `std.process.Child`：

- `stdin = Pipe`
- `stdout = Pipe`
- `stderr = Pipe`

当前是“一连接一子进程”模型，这与 upstream `websocketd` 和 fancyss 当前预期一致。

### 5.4 流式线程模型

当前实现大致是：

- 主读循环：
  - 从 WebSocket 读取消息
  - 写入子进程 stdin
- `stdout` 线程：
  - 逐行读 stdout
  - 推送 text frame
- `stderr` 线程：
  - 逐行读 stderr
  - 推送 text frame
- `wait` 线程：
  - 等待子进程退出
  - 关闭连接

维护时要注意：

- 对 `ws.writeMessage` 的写入有互斥保护
- 避免多个线程同时写同一个 WebSocket

---

## 6. 当前限制与风险点

### 6.1 每行最大长度

当前按行读取子进程输出时有固定缓冲上限。

如果输出行过长：

- 会丢弃该超长行
- 并发出一条提示文本帧

如果未来 fancyss 有更长的单行 JSON / 日志输出，需要调整：

- `max_line_len`

### 6.2 一条消息自动补换行

当前 WebSocket 收到的消息会：

- 原样写入
- 再自动写入 `\n`

这符合当前 `/koolshare/ss/websocket` 的按行读取模型。

如果未来要兼容“精确字节流”语义，这一行为需要单独加开关，而不是直接修改默认行为。

### 6.3 默认只处理一个请求生命周期

当前连接线程按 fancyss 的使用方式设计：

- 一个 WebSocket 连接升级后就进入 WebSocket 服务流程
- 不考虑同连接上继续复用其它 HTTP 请求

这对 fancyss 当前场景是合理的。

---

## 7. 回归测试清单

每次修改后，至少应回归以下场景。

### 7.1 本地功能测试

最小后端脚本：

```sh
#!/bin/sh
while IFS= read -r line; do
  echo "echo:$line"
done
```

验证：

- 握手成功
- 发送 `hello`
- 返回 `echo:hello`

### 7.2 fancyss 场景测试

至少验证：

- `echo ws_ok`
- `show_message`
- `cat /tmp/upload/ss_log.txt`
- `. script arg`
- `follow_webtest`

### 7.3 路由器实机测试

建议至少验证：

- GS7 `aarch64`
- TUF-AX3000 `armv7hf`

如有打包改动，还应验证：

- `qca/ipq32` 的 `armv7a`

---

## 8. 发布与打包约定

### 8.1 版本

当前版本记录在：

- `VERSION`

发布产物命名：

- `websocketd-v<ver>-linux-armv7a`
- `websocketd-v<ver>-linux-armv7hf`
- `websocketd-v<ver>-linux-aarch64`
- `websocketd-v<ver>-linux-x86_64`

### 8.2 压缩

当前策略：

- `x86_64`：不使用 UPX
- 其它目标：使用 `UPX 5.0.2`

### 8.3 fancyss 分发链路

当前 fancyss 侧映射为：

- `hnd` -> `armv7hf`
- `qca/ipq32` -> `armv7a`
- `hnd_v8/mtk/ipq64` -> `aarch64`

如果未来验证某个平台需要调整架构映射：

- 先改 `tool/ws-tool`
- 再改 `binaries/Makefile`
- 再改 `build.sh`

---

## 9. 后续建议

### 9.1 短期建议

短期不建议急着扩功能。

优先做：

- 更完整的错误日志
- 连接关闭 / 子进程退出原因统计
- 若需要，再补一个 `--max-line-len`

### 9.2 中期建议

如果未来 fancyss WebSocket 场景增加，可以考虑补：

- `--binary`
- 更严格的 `--passenv`
- 更完整的 upstream CLI 兼容

### 9.3 长期建议

如果以后 fancyss 希望统一“WebSocket 通道 + HTTP API 辅助”，可以考虑：

- 在 `ws-tool` 内补最小 HTTP 调试页或健康检查

但这不是当前阶段重点。

---

## 10. 一句话总结

`ws-tool` 当前最重要的维护原则不是“向 upstream `websocketd` 靠齐全部功能”，而是：

- 保持 fancyss 现有 WebSocket 使用场景稳定
- 控制体积
- 控制弱性能路由器上的运行负担
- 在此基础上再逐步扩展兼容面
