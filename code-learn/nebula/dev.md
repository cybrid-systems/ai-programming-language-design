已经把整条链路跑通了，两件事都有现成答案。

1. 集群已经在跑

进程都在（工作目录 /tmp/nb，用 --flagfile 启动）：

• metad — pid 601697，9559（HTTP 19559）
• storaged — pid 601833，9779（HTTP 19779）
• graphd — pid 602313，9669（HTTP 19669）

2. 怎么拉起

二进制在 ~/code/nebula-graph/build/bin/，配置模板在 ~/code/nebula-graph/conf/*.conf.default；运行目录 /tmp/nb/conf/ 里是实际生效的三份 flagfile（默认端口、127.0.0.1、enable_authorize=false，所以认证其实不强制）。顺序必须是 metad → storaged → graphd，每个之间等 3 秒左右。

我顺手写了个封装：

~/bin/nbctl start     # 按顺序拉起三个服务
~/bin/nbctl status    # 进程 + 端口状态（已验证）
~/bin/nbctl stop仓库自带的 scripts/services.sh 是官方 install 布局（/usr/local/nebula）用的，你这个是 build 目录手搓的，用不上。另外仓库支持编 standalone 单进程版（-DENABLE_STANDALONE_VERSION=ON，meta+storage+graphd 合体），当前 build 没开这个选项，需要的话我可以重新配一个。

3. nGQL client 怎么进去

官方 CLI 是 nebula-console。我已经把 v3.8.0 linux-arm64 下载到 ~/bin/nebula-console（从 GitHub release 拉的）：

~/bin/nebula-console -addr 127.0.0.1 -port 9669 -u root -p nebula          # 交互
~/bin/nebula-console -addr 127.0.0.1 -port 9669 -u root -p nebula -e "SHOW SPACES;"  # 单条已实测通过，输出：

| Name        |
| "copurchase" |Python 侧也有 nebula3-python 3.8.3，但两个坑：一是 py3.14 删了 ssl.PROTOCOL_TLSv1，import 就炸；二是这版 API 和网上文档不一致（pool.get_connection() 不带参数、结果要通过 Session 取）。我封装成了 ~/bin/ngql：

~/bin/ngql "SHOW SPACES;"          # 单条
~/bin/ngql                          # 交互 REPL
~/bin/ngql -f script.ngql          # 跑脚本地址/账号走环境变量 NEBULA_ADDR / NEBULA_PORT / NEBULA_USER / NEBULA_PASS。

当前库状态：space copurchase 存在，storaged ONLINE，3 个 partition，leader 都在 127.0.0.1:9779。

验证完了，命令可用。

核心命令

git clone --branch operator-opt --single-branch --shallow-since="14 days ago" --no-tags \
  https://gitcode.com/guoshaohong1/nebula.git实测结果（我跑了一遍，存在 /tmp/nb-opt）

• HEAD = 116b6a4 perf(storage): push multi-source distinct limit into storaged
• 提交数 11 个，日期区间 2026-11-02 → 2026-11-06
• 体积 25M（.git 3M），shallow 边界 1 个
• 11 个提交全是 guosh 在 operator-opt 上的 query-opt / aggregate / storage 优化

--shallow-since 的边界落在窗口内最老的那个提交上，所以 14 天窗口（10-27 往回）实际被分支本身的历史密度截到了 11-02，不是漏拉。

几个要注意的点

• 不需要 --recurse-submodules：这个仓库没有 .gitmodules。你 09:23 起的那条 git clone --recurse-submodules https://gitcode.com/guoshaohong1/nebula.git 其实多余，而且 ~/code/nebula 那个目录现在已经不在了，等于那次 clone 没留下东西。
• --no-tags 可选，加上能少拉一批 tag ref。
• 后面想补历史：git fetch --deepen=200（我试过，能往下拉到 2023-01-17 的上游提交，说明 operator-opt 是从上游 fork 出来的）。
• 如果后续要跟上游 master 算 merge-base 或者 rebase，shallow 克隆不够用，得 git fetch --unshallow（仓库不大，完整拉也不慢）。

另外提醒一句：~/code/nebula-graph（你正在跑集群的那个）是上游 vesoft-inc/nebula，和 gitcode 上这个 fork 是两份独立仓库，别混。

## bench

```sh
python3 gen_vertices.py load --users 10000 --products 50000
```

### q1

```sql
GO FROM 2 OVER buy YIELD dst(edge) AS pid, rank(edge) AS ts | YIELD $-.pid AS pid, $-.ts AS ts WHERE $-.ts >= 1761436800 - 1800 OR $-.pid != $-.pid | ORDER BY $-.ts DESC | LIMIT 10;
```

opt
```sql
GO FROM 2 OVER buy WHERE buy._rank >= 1761436800 - 1800 YIELD buy._dst AS pid, buy._rank AS ts | ORDER BY $-.ts DESC | LIMIT 10;
```

### q2

```sql
GO FROM 2 OVER expose YIELD DISTINCT dst(edge) AS pid MINUS GO FROM 2 OVER buy YIELD DISTINCT dst(edge) AS pid;
```

opt
```sql
GO FROM 2 OVER expose YIELD DISTINCT expose._dst AS pid MINUS GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS pid;
```

### q3

```sql
LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid | GO FROM $-.pid OVER buy REVERSELY YIELD src(edge) AS uid, rank(edge) AS ts | YIELD $-.uid AS uid, $-.ts AS ts WHERE $-.ts >= 1761436800 - 7776000 OR $-.uid != $-.uid | YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000;
```

opt
```sql
LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid | GO FROM $-.pid OVER buy REVERSELY WHERE buy._rank >= 1761436800 - 7776000 YIELD buy._dst AS uid | YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000;
```

### q4

```sql
UNWIND range(1, 10000) AS uid | GO FROM $-.uid OVER buy YIELD dst(edge) AS pid, $$.product.type AS t | GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy | ORDER BY $-.co_buy DESC | LIMIT 100 | GO FROM $-.pid OVER buy REVERSELY YIELD DISTINCT src(edge) AS ext_user | LIMIT 100000;
```

opt
```sql
UNWIND range(1, 10000) AS uid | GO FROM $-.uid OVER buy YIELD buy._dst AS pid | ORDER BY $-.pid | GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy | ORDER BY $-.co_buy DESC | LIMIT 100 | GO FROM $-.pid OVER buy REVERSELY YIELD DISTINCT buy._dst AS ext_user | LIMIT 100000;
```

### q5

```sql
GO FROM 2 OVER buy YIELD DISTINCT dst(edge) AS x | GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT src(edge) AS u2 | GO FROM $-.u2 OVER buy YIELD dst(edge) AS y | ORDER BY $-.y | GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20;
```

opt
```sql
GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS x | GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT buy._dst AS u2 | GO FROM $-.u2 OVER buy YIELD buy._dst AS y | ORDER BY $-.y | GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20;
```

### q6

```sql
GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT src(edge) AS uid | GO FROM $-.uid OVER buy YIELD dst(edge) AS item | YIELD $-.item AS item WHERE $-.item != 10000031733 | ORDER BY $-.item | GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20;
```

opt
```sql
GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT buy._dst AS uid | GO FROM $-.uid OVER buy WHERE buy._dst != 10000031733 YIELD buy._dst AS item | ORDER BY $-.item | GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20;
```

六条 opt 各自替换上面的同名基线，彼此没有依赖。下推前计划、下推后计划和 loopback 时延在 [47-reco-ngql-pushdown.md](47-reco-ngql-pushdown.md)。可单独执行的文件在 `bench/reco/pushdown/q1-opt.ngql` 到 `q6-opt.ngql`，重跑脚本是 `bench/reco/measure_pushdown.py`。

补丁和六条场景的对照在 [51-reco-patch-index.md](51-reco-patch-index.md)。[48](48-reco-operator-patches.md) 是小夹具 01–11 的时延，[49](49-reco-patch-map.md) 是当时的边界说明，[50](50-reco-partial-count.md) 是局部 COUNT 的开关对比。编号和结论以 51 为准。补丁在 `patches/reco-q/`，测量 JSON 在 `bench/reco/patch-measure/`，换二进制用 `bench/reco/swap_bins.sh`，重跑脚本是 `bench/reco/measure_patches.py`。语句以本节的 opt 为准。

生成器的 `--edge-scale` 默认 1。50 和 51 里 scale 8 的数字用的是 `bench/reco/out-scale8/`。那一组微秒和 48 的 80082 条 `buy` 不是同一张表。
