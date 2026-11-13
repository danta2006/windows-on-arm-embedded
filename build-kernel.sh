# 在 WSL 里编译一个"内置 PL2303"的 WSL2 内核
#
#   用法： bash build-kernel.sh
#   说明： 用本机 CPU 原生编译（ARM64 / x86_64 都行），约 30~50 分钟
#
set -euo pipefail

KVER="$(uname -r)"                    # 例：6.18.58.1-microsoft-standard-WSL2
TAG="linux-msft-wsl-${KVER%%-*}"      # 例：linux-msft-wsl-6.18.58.1
ARCH="$(uname -m)"                    # aarch64 / x86_64
SRC="${SRC:-$HOME/wsl-kernel}"        # 内核源码目录
OUT="${OUT:-$HOME/wsl-kernel-out}"    # 产物输出目录

if [ "$ARCH" = "aarch64" ]; then
    IMG_PATH="arch/arm64/boot/Image"
else
    IMG_PATH="arch/x86/boot/bzImage"
fi

echo "=================================================="
echo " 当前 WSL 内核 : $KVER"
echo " 对应源码 tag  : $TAG"
echo " 主机架构      : $ARCH"
echo " 产物          : $IMG_PATH"
echo "=================================================="

if [ ! -d "$SRC/.git" ]; then
    echo "[1/4] 克隆内核源码（约 2 GB，只取这一个 tag）…"
    git clone --depth 1 --branch "$TAG" \
        https://github.com/microsoft/WSL2-Linux-Kernel.git "$SRC"
else
    echo "[1/4] 已有源码目录，跳过克隆"
fi

cd "$SRC"

echo "[2/4] 用当前运行内核的配置作为基线（保证和原版只差 PL2303 一项）"
cp -f /proc/config.gz config.gz
gunzip -f config.gz
mv -f config .config

sed -i 's/^# CONFIG_USB_SERIAL_PL2303 is not set/CONFIG_USB_SERIAL_PL2303=y/' .config
sed -i 's/^CONFIG_USB_SERIAL_PL2303=m/CONFIG_USB_SERIAL_PL2303=y/' .config
make olddefconfig >/dev/null

if ! grep -q '^CONFIG_USB_SERIAL_PL2303=y' .config; then
    echo "!! 配置没有生效，请检查 .config"
    exit 1
fi
echo "     CONFIG_USB_SERIAL_PL2303=y  ✓"

echo "[3/4] 编译内核（-j$(nproc)），这一步最慢"
time make -j"$(nproc)" Image 2>/dev/null || time make -j"$(nproc)" bzImage

echo "[4/4] 导出产物"
mkdir -p "$OUT"
cp -v "$IMG_PATH" "$OUT/$(basename "$IMG_PATH")"
du -h "$OUT/$(basename "$IMG_PATH")"

echo
echo "完成，产物在： $OUT/$(basename "$IMG_PATH")"
echo "接下来在 Windows 侧执行： powershell -ExecutionPolicy Bypass -File install.ps1"
