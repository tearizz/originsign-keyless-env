# OriginSign Sigstore 最小环境

从 0 到 1 重建 OriginSign keyless 所需的 Sigstore v1 后端：TUF / Fulcio / CTLog /
Rekor v1 / TSA / gettoken。用于独立机器，不依赖现网 `sigstore-env` 的任何密钥。

## 组件与版本

| 组件 | 版本 / 镜像 |
|---|---|
| KinD / K8s | kind v0.30+ / K8s 1.32.8 |
| Knative / Kourier | 1.18.0 |
| scaffolding | v0.7.33 release 资产 |
| Fulcio | v1.8.3 |
| Rekor | v1.4.3（**v1 API**，`/api/v1/*`） |
| Trillian / MySQL / Redis | release 固定 digest / redis:6.2 |
| TSA | timestamp-server v2.0.3 |
| gettoken | scaffolding getoidctoken（projected SA token） |

全部 YAML 在 `manifests/`，校验和 `manifests/SHA256SUMS`；镜像 digest 直接来自
`sigstore/scaffolding v0.7.33` 和 Knative 1.18.0 release。不装 MetalLB、不装本地
registry、不需要 Go/ko 构建。

## 前置条件

- Linux x86_64，Docker 可用，`kind` / `kubectl` / `curl` / `jq` / `base64`，建议 `yq`。
- 端口可用。**本机 8080 和 18080 已被现网占用，使用 18081 或其它空闲端口。**
- 资源建议：4 vCPU / 8 GiB RAM / 20 GiB 磁盘；需访问 github.com、gcr.io、ghcr.io、
  registry.k8s.io、docker.io。

## 一键部署

```bash
cd /data/originsign-boot-lab/sigstore-env
export ACCESS_PORT=18081          # 8080/18080 已被占用时
./install.sh
```

`install.sh` 会：创建 KinD 集群 → 装 Knative/Kourier → 按依赖顺序部署
Trillian/Rekor/Fulcio/CTLog/TSA/TUF/gettoken → 启动 kourier 端口转发 → 导出
`root.json` / `endpoints.env` → 自动跑 `smoke-test.sh`。

安装完成后，把 install 输出的 hosts 条目加到**客户端所在机器**（同机用 127.0.0.1）：

```text
127.0.0.1 tuf.tuf-system.svc
127.0.0.1 fulcio.fulcio-system.svc
127.0.0.1 rekor.rekor-system.svc
127.0.0.1 ctlog.ctlog-system.svc
127.0.0.1 tsa.tsa-system.svc
127.0.0.1 gettoken.default.svc
```

远程访问：

```bash
ACCESS_ADDR=0.0.0.0 ACCESS_PORT=18081 ./install.sh
# 客户端 hosts 里的 IP 改成这台服务器的可达 IP
```

## 端点

安装后生成 `endpoints.env`：

```bash
source endpoints.env
echo "$TUF_MIRROR $FULCIO_URL $REKOR_URL $ISSUER_URL"
```

默认值（`ACCESS_PORT=18081`）：

```text
TUF_MIRROR  http://tuf.tuf-system.svc:18081
FULCIO_URL  http://fulcio.fulcio-system.svc:18081
REKOR_URL   http://rekor.rekor-system.svc:18081
CTLOG_URL   http://ctlog.ctlog-system.svc:18081
TSA_URL     http://tsa.tsa-system.svc:18081
ISSUER_URL  http://gettoken.default.svc:18081
```

## 验证

```bash
./smoke-test.sh              # 纯 curl：TUF/Fulcio/Rekor/CTLog/TSA/gettoken
./smoke-test.sh --e2e        # 需要 originsign 二进制，且 hosts 已配置
```

E2E 需要设置：

```bash
export ORIGINSIGN_BIN=/path/to/originsign
```

脚本会跑 `init -> gettoken -> sign(Fulcio+Rekor) -> verify(链+SCT+Rekor 包含性证明)`。

## 与 sbenv / originsign-image 集成

```bash
export SIGSTORE_ENV=/data/originsign-boot-lab/sigstore-env
export ORIGINSIGN_BIN=/path/to/originsign
source "$SIGSTORE_ENV/deploy-env.sh"
source "$SIGSTORE_ENV/endpoints.env"

# 首次/重新部署后，初始化 OriginSign Server 要用的 TUF 缓存
rm -rf "$TUF_ROOT"
"$ORIGINSIGN_BIN" init --mirror "$TUF_MIRROR" --root "$ROOT_JSON" \
  --root-cache-dir "$TUF_ROOT"
```

然后按 sbenv / originsign-image 的脚本启动 OriginSign Server 或签名镜像即可；
它们读取的 `FULCIO_URL` / `REKOR_URL` / `TUF_ROOT` 都来自本目录的 `endpoints.env`。

## 注意

- **每次重新部署都会生成新的 Fulcio CA、CTLog/Rekor key 和 TUF root**。客户端必须清掉
  旧 `TUF_ROOT` 并重新 `init`；旧 `certificate.json` 不能直接对新环境验签。
- Fulcio CA 有效期 1 年（`createcerts` 硬编码）；到期后最稳的是 `./down.sh --purge`
  再重装。
- 本环境是本地实验环境：全链路 HTTP、无 TLS，私钥存在 Kubernetes Secret 中；
  不要暴露到不可信网络，不要签发生产制品。
- 不安装 MetalLB，所以没有对外 LoadBalancer/sslip URL；统一走 kourier-internal 端口
  转发 + `*.svc` hosts。ksvc 的 Service 是 `ExternalName`，不能单独 port-forward。
- 客户端必须锁定 Rekor v1；rekor-tiles v2 会让 `/api/v1/*` 返回 404。
- 未包含 `originsign` 二进制、OriginSign Server、固件/镜像构建脚本。

## 故障排查

| 现象 | 处理 |
|---|---|
| `createdb` 失败/卡住 | 等 MySQL；`kubectl -n trillian-system logs job/createdb`；删 Job 后重新 apply `release-trillian.yaml` |
| Trillian `Table 'Trees' doesn't exist` | `createdb` 未成功；删 `createdb` Job 重新 apply `release-trillian.yaml` |
| Rekor 404 | 装成了 v2；确认镜像是 `rekor-server:v1.4.3`，`/api/v1/log/publicKey` 返回 PEM |
| Fulcio 发证 401/500 | token `iss` 不对、缺 `oidc-reviewer`、或 audience 不含 `sigstore` |
| Fulcio `Error entering certificate in CTL` | CTLog 仍信任旧 Fulcio 根；重建 `ctlog-secret`/CTLog |
| keyless PoP 失败 | 客户端临时 key 是 P-521 但用 SHA-256；改 P-256（`pkg/signtool/cryptoalgos/ecdsa.go`） |
| `init` 失败 | `TUF_MIRROR` 不可达或 `root.json` 不是本次部署；先 `./smoke-test.sh` |
| 端口占用 | 换 `ACCESS_PORT`；不要用 8080/18080（本机现网占用） |

## 清理

```bash
./down.sh            # 删集群/端口转发，保留 root.json/endpoints.env
./down.sh --purge    # 额外删 .state/root.json/endpoints.env/out/tuf-cache
```

脚本只按 `CLUSTER_NAME` 删除本实验室集群，并拒绝 `CLUSTER_NAME=kind`，避免误删现网。

## 来源与验证

- 上游清单：[sigstore/scaffolding v0.7.33](https://github.com/sigstore/scaffolding/releases/tag/v0.7.33)、
  [Knative 1.18.0](https://github.com/knative/serving/releases/tag/knative-v1.18.0)，Apache-2.0。
- 已在独立 Docker 网络的临时集群验证：9 个 ksvc 全部 Ready；TUF targets 完整；
  Fulcio 发证 201（SAN 正确、CTLog SCT 正常）；Rekor v1 `hashedrekord` 写入 201
  （logIndex=0）；`smoke-test.sh` 通过。验证后集群和测试网络已删除，现网未受影响。

## 文件

```text
install.sh       # 一键部署 + 导出信任根/端点 + 自动冒烟
smoke-test.sh    # 环境自检；--e2e 跑 keyless
down.sh          # 清理
deploy-env.sh    # sbenv 兼容入口（SIGSTORE_ENV/KUBECONFIG）
endpoints.env    # install 生成
root.json        # install 生成
manifests/       # kind / Knative / release YAML + SHA256SUMS
```
