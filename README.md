# ws-tool

`ws-tool` 是一个使用 Zig 编写的轻量级 `websocketd` 替代实现。

项目目标不是完整复刻 upstream `websocketd` 的全部功能，而是优先覆盖 fancyss 当前真实使用到的兼容面：

- `--port`
- `--address`
- `--passenv`
- 执行一个命令作为每个 WebSocket 连接的后端进程
- 将 WebSocket 文本消息按行写入子进程 `stdin`
- 将子进程 `stdout/stderr` 按行回推为 WebSocket 文本帧
- 传递常用 CGI / HTTP 环境变量给子进程

运行时二进制名字仍然叫：

- `websocketd`

这样 fancyss 侧脚本可以最小改动，甚至不改动。

## 当前版本

`0.1.0`

当前代码按 Zig `0.15.2` 编写并验证。

## 当前支持的命令形式

```bash
websocketd --port=803 /koolshare/ss/websocket
websocketd --port 803 /koolshare/ss/websocket
websocketd --address 0.0.0.0 --port 803 /koolshare/ss/websocket
websocketd --passenv PATH,DYLD_LIBRARY_PATH --port 803 /koolshare/ss/websocket
websocketd --help
websocketd --version
```

## 当前未实现的 upstream 能力

以下能力当前不在第一阶段范围内：

- SSL/TLS 终止
- 静态文件服务
- `--binary`
- `--devconsole`
- 复杂的 HTTP 路由与多命令分发

如果传入 fancyss 当前未使用的复杂参数，程序会直接报错退出，而不是静默忽略。

## 构建

直接构建：

```bash
zig build
```

构建后可执行文件位于：

```bash
./zig-out/bin/websocketd
```

生成多平台发布产物：

```bash
bash ./scripts/build-release.sh
```

默认目标：

- `x86_64`
- `armv7a`
- `armv7hf`
- `aarch64`

默认启用 `UPX` 压缩：

- `armv5te` 如未来启用，使用 `UPX 4.2.4`
- 其它目标使用 `UPX 5.0.2`

## 与 fancyss 的关系

fancyss 当前 `websocketd` 使用方式非常固定：

- 固件启动后拉起 `websocketd --port=803 /koolshare/ss/websocket`
- 前端连接 `ws://<router>:803/`
- 建连后发一条文本消息
- 后端脚本按行输出日志 / 状态流

`ws-tool` 的第一阶段就是围绕这条链做到可替换。
