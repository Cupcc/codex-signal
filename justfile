# 查看可用命令
default:
    @just --list

# 编译最新代码并重启应用
dev:
    ./script/build_and_run.sh

# 重启现有应用，不重新编译
restart:
    @test -d dist/CodexSignal.app || { echo '应用尚未构建，请先运行 just dev' >&2; exit 1; }
    @pkill -x CodexSignal 2>/dev/null || true
    open -n dist/CodexSignal.app

# 停止应用
stop:
    @pkill -x CodexSignal 2>/dev/null || true

# 仅编译并打包
build:
    ./script/build_and_run.sh --build

# 构建通用 Release 应用、DMG、ZIP 和校验文件
release:
    ./script/release.sh

# 运行全量测试；最小回归使用 script/test.sh --filter REGEX
test:
    ./script/test.sh

# 编译并启动演示模式
demo:
    ./script/build_and_run.sh --demo

# 编译并重启，查看日志
logs:
    ./script/build_and_run.sh --logs
