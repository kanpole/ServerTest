# 游戏服务器压测脚本

这是一个用于评估 Ubuntu 服务器是否适合运行游戏服务器的压测脚本。它可以连续运行多天，断开 SSH 后仍会继续执行，并输出日志和汇总报告。

## 安装依赖

```bash
sudo ./game-server-bench.sh install
```

## 开始压测

默认测试 72 小时：

```bash
sudo ./game-server-bench.sh start
```

指定测试时长和 CPU 目标负载：

```bash
sudo ./game-server-bench.sh start --hours 72 --cpu 80
```

使用另一台服务器作为网络测试目标：

```bash
sudo ./game-server-bench.sh start --hours 72 --iperf-host 目标服务器IP --iperf-mode both --iperf-mbps 100
```

## 目标服务器准备

在作为网络测试目标的另一台服务器上运行：

```bash
sudo apt update
sudo apt install -y iperf3
iperf3 -s -p 5201
```

如果开启了防火墙，建议只允许被测服务器的公网 IP 访问 TCP/UDP `5201` 端口。

## 查看状态、日志和报告

```bash
./game-server-bench.sh status
./game-server-bench.sh logs
./game-server-bench.sh report
```

停止后台压测：

```bash
sudo ./game-server-bench.sh stop
```

## 参数说明

```text
--hours N           测试时长，单位小时。默认: 72。
--cpu PERCENT      CPU 目标负载，范围 1 到 100。不填则进行全核心压力测试。
--download-mbps N  下载吞吐观察目标，单位 Mbps。
--streams N        并行下载 worker 数量。默认: 2。
--url URL          添加下载测试地址，可重复传入。
--iperf-host HOST  启用你自己控制的 iperf3 目标服务器测试。
--iperf-port PORT  iperf3 目标服务器端口。默认: 5201。
--iperf-mode MODE  tcp、udp、both、tcp-up、tcp-down、udp-up 或 udp-down。默认: both。
--iperf-mbps N     UDP 目标带宽，单位 Mbps。默认: 50。
--iperf-duration N 每次 iperf3 采样秒数。默认: 30。
--iperf-interval N 每轮 iperf3 测试间隔秒数。默认: 300。
```

完整帮助：

```bash
./game-server-bench.sh --help
```
