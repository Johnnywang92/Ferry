# libssh2 安全补丁系列

libssh2 最新的**已发布**版本就是 1.11.1（2024-10-16），而针对它的 10 条 CVE 修复
全部只进了 master——master 的 `RELEASE-NOTES` 自报 `1.11.2_DEV`，
`git tag --contains <修复commit>` 对每一条都是空集（2026-10-15 在
`ThirdParty/build/patchcheck/libssh2` 里逐个核实过）。
也就是说：**打 tag 的 1.11.1 不带任何一个已知修复**。本系列 10 条全搬，已知 CVE 清零。

本目录保存把这些修复搬到 1.11.1 上的补丁，构建脚本在 `git checkout` 之后、
配置之前按编号顺序 `git am` 上去。

## 清单

文件名里的 sha 是**上游 commit** 的前 12 位，不是本地 commit。
等级取各条 advisory 页面的标注；CVSS 分数没逐个抄进来，要核就到页面看。

| # | 上游 commit | GHSA | CVE | 等级 | 改动文件 | 搬到 1.11.1 |
|---|---|---|---|---|---|---|
| 0001 | `97acf3dfda80` | r8mh-x5qv-7gg2 | 2026-55200 | Critical | src/transport.c | 手工：`ssh2_ntohu32` → `_libssh2_ntohu32` |
| 0002 | `5e4776146552` | 83r8-6c29-8gwr | 2026-66032 | High | src/sftp.c | 手工：`SSH2_FREE` → `LIBSSH2_FREE` |
| 0003 | `256d04b60d80` | jhp3-h4hp-2c3p | 2026-7598 | Medium | src/userauth.c | 干净 |
| 0004 | `17626857d20b` | 3cfq-4xx4-rmpg | 2026-55199 | High | src/packet.c | 干净 |
| 0005 | `a13bb6c773f0` | 6h6q-9mwg-r6x7 | 2026-66034 | High | src/publickey.c | 手工：`ssh2_err` 是 master 的助手名，1.11.1 还叫 `_libssh2_error` |
| 0006 | `a2ed82d40964` | 2g8c-wcg8-r65c | 2026-66033 | High | src/openssl.c | 干净 |
| 0007 | `42e33d81577e` | v6rf-8q4r-r495 | 2026-66035 | High | src/transport.c | 手工：1.11.1 没有 `SSH2_SAFEFREE`，改成 FREE 后置空；master 此处多一句 `first_block[0] = 0`，不搬 |
| 0008 | `2dae3024897e` | 3wqh-87fg-ffgg | 2025-15661 | High | src/sftp.c | 手工：`LIBSSH2_UNCONST` 是 master 才有的宏；`packet_len` 在 master 已重构成 `uint32_t` 后置赋值，保留 1.11.1 的 `ssize_t` 就地初始化 |
| 0009 | `34497525929b` | mf77-5hj2-98w9 | 2026-58050 | High | src/publickey.c | 手工：又一个 `ssh2_err` → `_libssh2_error`（和 0005 同一个坑） |
| 0010 | `a9758da45a52` | c5f3-hwj2-xp5p | 2026-58051 | High | src/publickey.c | 干净：一行 `memset` |

GHSA → commit 的对应关系取自各条 advisory 页面（`github.com/advisories/<GHSA>`）。
坑记在这里，四条都是踩过或核实过的：

- 0001 的 advisory 页面上把 commit 显示成 `7acf3df`，**这个 sha 在仓库里不存在**
  （`git cat-file -e` 失败），页面实际链接指向 `97acf3dfda80…`。
- 0005、0006、0009、0010 在 GitHub 结构化字段 `patches` 里全是**空的**，
  只有 advisory 正文写了 commit。所以别只信 API。
- **0009/0010 差点被漏掉**：本 README 早期版本写的是"这两条 advisory 没给修复 commit，
  无法搬运"，依据就是上面那条空的 `patches` 字段。实际 `34497525929b` 和 `a9758da45a52`
  都存在且能搬。是拿 Homebrew 的 `libssh2-1.11.1_7` formula 对账时发现的——它给这两条
  分别备了 backport patch 并标了 `resolves`。
  教训：**"API 查不到 commit" ≠ "没有 commit"**，跨一个独立供应商的补丁清单就能证伪。
- 0008 上游 commit 的搬运方式有第三方背书：Homebrew 同样剥掉了 `LIBSSH2_UNCONST`
  （"which doesn't exist in 1.11.1"），并注明该改法在
  `github.com/libssh2/libssh2/issues/2125` 通过审核。和本文的手工适配是同一个改法。

## 打补丁改变了什么行为

补丁只动 `src/*.c`，不碰 `include/`（10 个补丁的 diff 文件清单里没有头文件），
所以编译期可见的 API 表面与原版 1.11.1 相同；`Spike/Scripts/api-probe.sh`
在打完补丁的产物上仍是**声明 23/25、定义 23/25**，与 M0a 在 Homebrew 上的结果一致，
缺的还是 `libssh2_session_set_abort_fn` 与 `libssh2_transport_set_sendsize` 那两个。
但**返回值语义有一处实测翻转**，M0b-01/M0b-03 记着：

- `libssh2_sftp_symlink_ex()`：未打补丁的 1.11.1 建链成功回 `rc=0`；
  打上 0008（CVE-2025-15661，改的正是 `sftp_symlink()`）之后恒回 `rc=-31`，
  `sftp_last_error` 是 71–134 这种越界值（合法上界 21），而链**实际建成了**。
  三台服务器（2201/2202/2203）上 16 条用例表现一致，可复现。
  → 后端建链不能信返回码，必须 `lstat`+`readlink` 回读判定。
  这不是回归：越界读被修掉之后，原来"碰巧读到 0"的路径改成报错，属预期副作用。
  Homebrew 那份 1.11.1_7 同样带这个补丁，行为与本文一致。

## 重新生成

上游发新版或我们要增删补丁时，在干净的 1.11.1 上重做：

```
git clone https://github.com/libssh2/libssh2.git
cd libssh2
git checkout -b ferry-patches <LIBSSH2_COMMIT>
git cherry-pick -x <sha>…        # 冲突按上表"搬到 1.11.1"一列手工解决
git format-patch <LIBSSH2_COMMIT>..HEAD -o /tmp/p   # 逐个改名成 00NN-<上游sha前12位>.patch
(cd ThirdParty/patches && shasum -a 256 0*.patch > SHA256SUMS)
```

改名要手工做：`format-patch` 给的文件名用的是**本地 commit** 主题，而本目录约定用
**上游 commit** 的 sha 前 12 位（见本节开头）。
`git am` 不认文件名，只认内容，所以改名不影响构建，只影响人来对账。

"干净搬运"要看两件事，别只看 cherry-pick 的退出码：
`cherry-pick` 成功只说明上下文能对上，**不说明编得过**——0005 和 0009 都是这么翻车的，
master 把报错助手从 `_libssh2_error` 改名成 `ssh2_err`，补丁落地后要靠编译才暴露。
每次增删补丁后跑一遍：

```
git diff <LIBSSH2_COMMIT>..HEAD -- src/ | grep '^+' | grep -oE '\bssh2_[a-z_]+\(|\bSSH2_[A-Z_]+'
```

有输出就是新增了 1.11.1 里不存在的标识符，得手工替换（`_libssh2_error` / `LIBSSH2_FREE` 等）。
注意 BSD grep 的 `\b` 在 `_` 前后不成立，`_libssh2_error(` 不会被这条命令误报。

补丁内容变了必须同步 `ThirdParty/patches/SHA256SUMS`——构建脚本先校验这份清单，
再按它的集束哈希判断 libssh2 产物能不能复用，不一致会重编。
