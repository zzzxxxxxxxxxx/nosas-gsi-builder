# nosas-gsi-builder

在 GitHub Actions 上跑 [phhusson/sas-creator](https://github.com/phhusson/sas-creator) 的 `run.sh`，
把一份 **system-as-root（sas）** 的 system.img 转换成
**非 sas + 老设备兼容补丁** 的镜像，用于 Unisoc SC9832E/SL8541E 这类
Android 8.1（VNDK-lite）vendor 的设备（DW99 手表就是这么刷的）。

## 背景

phh 的树（`device/phh/treble`）编出来的 `out/target/product/phhgsi_arm64_ab/system.img`
是 **sas 布局**：根目录下是 `init`、`init.environ.rc`、`res/`、空挂载点，
真正的系统内容在 `system/` 子目录里。

但这类设备的 boot ramdisk 是 Android 8.1 那套（`root=/dev/ram0 rw`，
system 分区挂到 `/system`），只认 **非 sas** 镜像。直接刷 sas 镜像会卡 logo。

`run.sh` 做的事：

1. 布局转换：删掉根目录除 `system/` 外的所有条目 → `mv system/* .` → `rmdir system`
2. 老设备兼容补丁：
   - VNDK 27 复制成 **26**，并用 `vendor_vndk` 里的 `vndk-sp-26` / `vndk-{26,27,28}` 库替换
   - `lib{,64}/vndk-26`、`vndk-sp-26` 符号链接
   - seccomp policy（`getdents64`、`rt_sigprocmask`、`rt_sigaction`、`MREMAP_MAYMOVE`）
   - init rc 修补（lmkd / credstore / llkd / bpfloader / zygote / `+passcred` / `reserved_disk`）
   - 新增 `etc/init/apex-setup.rc`、`etc/init/init-environ.rc`
   - `plat_property_contexts` 清理、`plat_sepolicy.cil` 里 adbd functionfs ioctl 号、关掉 iorapd

## 用法

两种输入方式，二选一。

### 1. 直链（推荐）

Actions → `nosas` → Run workflow，填 `image_url`：

```
https://github.com/<you>/<build-repo>/releases/download/<tag>/system.img.xz
```

支持 `.img` / `.img.xz` / `.img.gz` / `.zip` / `.tar.*`，脚本会自动解压取最大那个文件。
仓库是私有的话，URL 需要带 token，或者改用下面的 artifact 方式。

### 2. 从另一个仓库的构建产物拉

填 `src_repo`（`owner/repo`）、`src_workflow`（如 `build-lineage.yml`）、`src_artifact`（artifact 名）。
跨仓库下载 artifact 需要 token：在本仓库加一个 secret `SRC_REPO_TOKEN`（有 `actions:read` 权限的 PAT）。

## 输入要求

- **必须是编译产出的原始 `out/target/product/phhgsi_arm64_ab/system.img`**（sas 布局），
  不要喂已经处理过布局的镜像——`run.sh` 自己会做 `mv system/* .`。
- sparse 或 raw 都行（脚本里是 `simg2img || cp`）。
- 只处理 system 分区；**boot.img 不要动**（ramdisk 里有 `/lib/modules/sprdwl_ng.ko` 等，WiFi 靠它）。

## 产物

`s.img` → 上传为 artifact `system-nosas`（默认名 `lineage-18.1-arm64_bvN-nosas-raw.img`）。
大小约 3GB 以下的 **raw ext4**，直接写进 system 分区即可（比分区小没关系）。

## 自检

workflow 会跑 `scripts/verify-image.sh`，任何一项不过就 fail，判据是：

- `e2fsck -fn` 干净
- 根目录是非 sas（有 `bin etc build.prop framework lib64 system_ext xbin`，且**没有**顶层 `system/`）
- `/lib` 里有 `vndk-26`、`vndk-sp-26`
- `/etc/init/` 里有 `apex-setup.rc`、`init-environ.rc`
- `/system_ext/apex/com.android.vndk.v26` 存在
- `/bin/sh` 带有 `security.selinux` 上下文（xattr 没丢）

## pinned 版本

- sas-creator `41bdf25142be8aa02019423816ab0c13c96acd56`
- vendor_vndk（android-10.0）`f67d0d575dd044f9cd929b198a72c86fda8454ff`

升级时改 workflow 里那两个 sha 即可。
