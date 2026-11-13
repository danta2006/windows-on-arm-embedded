# 在 Windows on ARM 上做嵌入式实验

> Surface Pro X / 骁龙本上做单片机、嵌入式课的生存指南。
> 老师发的环境包（VMware + x86 Ubuntu + SecureCRT + USB 串口驱动）在这类机器上**一样都用不了**，
> 这个仓库记录了我最后跑通的那条路，以及中间踩过的每一个坑。

## 你会遇到的三堵墙

**第一堵：内核态驱动不能模拟。**
Windows on ARM 用软件模拟 x86 程序，但**只模拟用户态**。CH340、PL2303、CP2102 这些串口芯片的驱动是内核态 `.sys`，厂商只提供 x86/x64 版本，ARM64 内核加载不了。表现：设备管理器里一个带感叹号的未知设备，**永远不会有 COM 口**。

**第二堵：x86 虚拟机跑不了。**
老师给的 Ubuntu 镜像是 `x86_64` 的，ARM 芯片不能执行 x86 指令；VMware 也不做整机指令模拟（它的 ARM 版只能跑 ARM 客户机）。VT-x 这条路在 ARM64 上没有对应物。

**第三堵：所以 SecureCRT 没有口可用。**
它是 x86 程序，靠模拟能启动，但串口下拉框里永远是空的。

结论：**老师那套一步都走不通，但实验室要干的事本身完全能做。**

## 跑通的思路

```
USB 转串口 ──usbipd-win──> WSL2(Linux 内核自带驱动) ──> /dev/ttyUSB0 ──picocom──> 开发板
                                                                      └─ sx/rx（XMODEM 传文件）

写代码 ──> WSL 里交叉编译 ──> ARM 可执行文件 ──> 传到板子上跑
```

关键点：**驱动要在 Linux 那边找，不要在 Windows 这边找。** 把 USB 设备整个交给 WSL2，问题就从"给 Windows 装驱动"变成了"Linux 认不认这颗芯片"——而 Linux 几乎全认。

## 第一步：把串口送进 WSL

```powershell
winget install --exact dorssel.usbipd-win
```

插上 USB 转串口线，然后：

```powershell
cd scripts
.\1-usb-attach.cmd        # 管理员，自动找设备、bind、attach --wsl
```

它做的事：`usbipd bind` → `usbipd attach --wsl --auto-attach` → 在 WSL 里 `modprobe` 几个串口驱动 → 确认 `/dev/ttyUSB0` 出现。

`--auto-attach` 很重要：WSL 重启或线拔插后会自动重新挂上，不用每次手动 attach。

## 第二步：驱动——三个自带，一个要自己编

WSL 内核（`6.18.58.1-microsoft-standard-WSL2`）里：

| 芯片 | 驱动 | 状态 |
| --- | --- | --- |
| CH340 / CH341 | `ch341` | ✅ 自带 |
| CP2102 / CP2104 | `cp210x` | ✅ 自带 |
| FT232 / FTDI | `ftdi_sio` | ✅ 自带 |
| **PL2303（Prolific）** | `pl2303` | ❌ **被微软关掉了** |

```bash
$ zcat /proc/config.gz | grep PL2303
# CONFIG_USB_SERIAL_PL2303 is not set
```

如果你手上是前三根线之一，**到这里就结束了**，插上就能用。

如果是 PL2303（实验室最常见的那种），往下看。

## 第三步：PL2303 —— 为什么不能只补一个模块

这是全程最容易走弯路的地方。

Linux 的内核驱动可以单独编译成 `.ko` 补进去，但 WSL 内核开了 `CONFIG_MODVERSIONS=y`：模块加载时要做符号版本校验，CRC 来自内核编译产物里的 `Module.symvers`。**这个文件只有完整编译一遍内核才会生成，微软不发。**

实测（照 GitHub 上现成的方案做的）：

```bash
make -j8 modules_prepare                    # ✓ 能过
make -j8 M=drivers/usb/serial modules
```
```
WARNING: Module.symvers is missing.
ERROR: modpost: "usb_alloc_urb" [usbserial.ko] undefined!
ERROR: modpost: "dev_set_name" [usbserial.ko] undefined!
... 253 unresolved symbol warnings
```

就算用 `KBUILD_MODPOST_WARN=1` 硬编出来，`insmod` 也会报：

```
pl2303: disagrees about version of symbol module_layout
```

**所以只能整颗内核重编**，把 PL2303 编进去。

> ⚠️ **重要警告（2026-11-13 实测）**
> 换自定义内核后，`/lib/modules` 里的**发行版模块会全部不可用**，其中就包括 `usbipd` 依赖的 `vhci_hcd`。
> 结果是 `usbipd attach` 直接报 `Loading vhci_hcd failed`，**整条 USB 透传链路会断掉**。
> 只把串口驱动编进内核是不够的。要真正可用，必须连同**完整模块树**一起编译并安装
> （`make modules` + `make modules_install` + `depmod`），再换内核。
> 本仓库的脚本目前**只做了内核**，还没做模块，属于未完成状态——请谨慎使用。
## 第四步：重编内核（本仓库的脚本）

```bash
bash build-kernel.sh          # 约 30~35 分钟，全程本机原生编译
```

它做的事：
1. 按 `uname -r` 推出精确的源码 tag（`linux-msft-wsl-6.18.58.1`）并克隆；
2. **用当前运行内核的 `/proc/config.gz` 当基线**，只改配置里的串口驱动那几行；
3. `make -j$(nproc) Image`；
4. 产物放到 `~/wsl-kernel-out/`。

因为基线就是官方配置，新内核和微软原版**只差这几行**，版本号、WSL 集成（9p / vsock / Hyper-V / dxg）全不变。

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
wsl --shutdown
```

`install.ps1` 会把镜像复制到 `%USERPROFILE%\wsl-kernel\`、备份 `.wslconfig`、在 `[wsl2]` 段写入 `kernel=...`。

重新进 WSL 后：

```bash
bash verify.sh
```
```
CONFIG_USB_SERIAL_CH341=y
CONFIG_USB_SERIAL_CP210X=y
CONFIG_USB_SERIAL_FTDI_SIO=y
CONFIG_USB_SERIAL_PL2303=y
  ch341 ✓ 编进内核且已注册
  cp210x ✓ 编进内核且已注册
  ftdi_sio ✓ 编进内核且已注册
  pl2303 ✓ 编进内核且已注册
```

## 必须知道的两个副作用

**① 自定义内核启动后，发行版自带的 `/lib/modules` 模块用不了。**
WSL 只在官方内核下才提供那套模块，换内核后 `/lib/modules/<版本>/` 是空的。
所以本仓库的脚本**直接把四个串口驱动全部编进内核**（`=y`），谁都不依赖模块。

代价：如果你还需要别的模块（docker 的 netfilter、某些文件系统之类），也得自己编进内核，或者切回官方内核。

**② 版本号会多一个 `+`。**
源码是 git 仓库且工作区有改动时，内核会给版本号加 `+`，变成 `...WSL2+`，那样它就和 `/lib/modules/...WSL2` 对不上。
`build-kernel.sh` 里已处理（把 `.git` 移开再编译），所以 `uname -r` 和原来完全一致。

## 第五步：交叉编译

```bash
arm-linux-gnueabihf-gcc -O2 -static -o app main.c
```

两个要点：

- **静态链接**（`-static`）：开发板上的 glibc 通常是 2.19 那种老版本，动态链接会直接报 `GLIBC_2.xx not found`。静态链接后不依赖板上任何库。
- 想要更保险可以用 **musl** 静态链接（本机就是这么用的），体积从 360 KB 降到 20 KB 左右，对老内核也更友好。

## 第六步：传文件

```powershell
scripts\2-serial-console.cmd
```

板子上先敲 `rx 文件名`，然后在 picocom 里按 `Ctrl+A` 再按 `S`，输入文件路径。
这就是老师文档里 SecureCRT 的「发送 Xmodem」，一模一样的东西。

开发板有网的话更省事：`tftp -g <电脑IP> -r 文件名`。

## 回滚

删掉 `%USERPROFILE%\.wslconfig` 里 `kernel=` 那一行：

```powershell
wsl --shutdown
```

十秒钟回到微软原版内核。原内核文件一个字节都没动。

## 实测记录

| 项目 | 结果 |
| --- | --- |
| 机器 | Surface Pro X（Microsoft SQ2，Windows 11 ARM64） |
| WSL | Ubuntu 22.04，内核 6.18.58.1-microsoft-standard-WSL2 |
| 首次完整编译 | **33 分 25 秒**（`make -j8 Image`，8 核） |
| 改配置后增量编译 | 约 3 分钟 |
| 内核镜像 | 38.9 MB |
| 换内核后验证 | 四个串口驱动已注册；网络 ✓；`/mnt/c` ✓；与 Windows 互操作 ✓；交叉工具链 ✓；`make` ✓ |
| 回滚验证 | 删 `kernel=` 一行即可恢复 |

## 已知限制

- 没有实物串口线时只能验证"驱动已注册"，不能验证真实收发（本仓库的验证到此为止）。
- WSL 执行 `wsl --update` 换内核后，需要重新跑 `build-kernel.sh` + `install.ps1`。
- 只在 ARM64 上实测；脚本对 x86_64 也做了适配（会选 `bzImage`），但没有实机验证。

## License

MIT
