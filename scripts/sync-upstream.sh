#!/usr/bin/env bash
#
# sync-upstream.sh —— 上游同步（双轨制 / 幂等可重试）
#
# 属定制轨文件：上游无此文件，新增不修改任何上游文件，零冲突。
#
# 默认只做检查并报告，不修改任何东西；加 --apply 才执行同步。
#
# 阶段：
#   0. 可达性预检（分协议：上游 HTTPS / origin SSH）
#   1. fetch 上游
#   2. 报告落后提交数与改动面
#   3. main 仅 --ff-only 前进（main 上零定制，必定成功）
#   4. 把 main 合并进 custom/main，冲突则报告分派建议
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM="${UPSTREAM:-upstream-https}"
BRANCH_UPSTREAM="${BRANCH_UPSTREAM:-main}"
BRANCH_CUSTOM="${BRANCH_CUSTOM:-custom/main}"
PUSH_REMOTE="${PUSH_REMOTE:-origin}"

APPLY=0
DO_PUSH=0
ASSUME_YES=0
NET_TIMEOUT="${NET_TIMEOUT:-25}"

# 上游「接线点」——真正需要三向合并的上游文件（方案文档 4.3）。
# 只用于冲突分派时的提示，留空亦可。
HOTSPOTS=(
  "byclaw-fe/config/route.config.ts"
  "byclaw-fe/src/locales/zh-CN.ts"
  "byclaw-fe/src/locales/en-US.ts"
)

usage() {
  cat <<'EOF'
Usage:
  ./scripts/sync-upstream.sh [options]

默认（无 --apply）：只检查并报告，不修改仓库。

Options:
  --apply             执行同步（fetch → main --ff-only → 合并进 custom/main）。
  --push              在 --apply 基础上，把 main 与 custom/main 推到 origin。
  --upstream <name>   上游 remote 名（默认: upstream-https）。
  --yes               非交互：不等待回车确认。
  --timeout <sec>     单项网络操作超时秒数（默认: 25）。
  --help              显示本说明。

Environment:
  UPSTREAM, BRANCH_UPSTREAM, BRANCH_CUSTOM, PUSH_REMOTE, NET_TIMEOUT

Exit codes:
  0  已是最新，或同步成功
  1  环境/网络/前置条件不满足（无副作用，可重试）
  2  仓库状态不允许同步（有未提交改动 / main 无法 fast-forward）
  3  合并存在冲突（需人工处理，工作区已保留冲突现场）

Examples:
  ./scripts/sync-upstream.sh              # 先看看落后多少
  ./scripts/sync-upstream.sh --apply      # 执行同步
  ./scripts/sync-upstream.sh --apply --push --yes
EOF
}

log()  { printf '[sync] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[fail] %s\n' "$*" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------- 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)          APPLY=1; shift ;;
    --push)           DO_PUSH=1; APPLY=1; shift ;;
    --upstream)       UPSTREAM="${2:?--upstream 需要参数}"; shift 2 ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --timeout)        NET_TIMEOUT="${2:?--timeout 需要参数}"; shift 2 ;;
    --help|-h)        usage; exit 0 ;;
    *)                warn "未知参数: $1"; usage; exit 1 ;;
  esac
done

confirm() {
  [[ $ASSUME_YES -eq 1 || ! -t 0 ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ------------------------------------------------- 阶段 0：可达性预检（分协议）
reachable() { timeout "$NET_TIMEOUT" git ls-remote --heads "$1" "$BRANCH_UPSTREAM" >/dev/null 2>&1; }

log "阶段 0/4：可达性预检（超时 ${NET_TIMEOUT}s）"

# 先区分「remote 不存在」与「网络不可达」——否则会误导成 VPN 问题
if ! git remote get-url "$UPSTREAM" >/dev/null 2>&1; then
  warn "remote 不存在：$UPSTREAM"
  warn "现有 remote：$(git remote | tr '\n' ' ')"
  die "请先创建上游 remote，例如：git remote add upstream-https https://github.com/<owner>/<repo>.git" 1
fi
if ! git remote get-url "$PUSH_REMOTE" >/dev/null 2>&1; then
  warn "remote 不存在：$PUSH_REMOTE（推送目标）"
  die "请先创建推送 remote，或改用 PUSH_REMOTE=<name> 指定。" 1
fi

if ! reachable "$UPSTREAM"; then
  warn "上游不可达：$UPSTREAM（通常走 HTTPS）"
  warn "→ 国内网络下这多半是【VPN 未开】，请先打开 VPN，再重跑本脚本。"
  if [[ $ASSUME_YES -eq 0 && -t 0 ]]; then
    read -r -p "      已打开 VPN 后按回车重试，或 Ctrl+C 退出... " _ || true
    reachable "$UPSTREAM" \
      || die "仍不可达，请检查 VPN / 代理设置（无副作用，可随时重试）。"
  else
    die "上游不可达（无副作用，可随时重试）。"
  fi
fi
log "上游可达：$UPSTREAM"

# origin 走 SSH，失败原因常与 VPN 无关（HOME 为空 → SSH 读不到密钥/known_hosts）
if ! timeout "$NET_TIMEOUT" git ls-remote --heads "$PUSH_REMOTE" "$BRANCH_UPSTREAM" >/dev/null 2>&1; then
  warn "$PUSH_REMOTE 不可达（通常走 SSH）。若上游已通，这多半【不是 VPN 问题】："
  warn "  · 检查 HOME 是否为空、\$HOME/.ssh 是否可读"
  warn "  · 可固化：git config core.sshCommand \\"
  warn "      \"ssh -o UserKnownHostsFile=\$HOME/.ssh/known_hosts -i \$HOME/.ssh/id_rsa\""
  if [[ $DO_PUSH -eq 1 ]]; then
    die "$PUSH_REMOTE 不可达，无法推送。去掉 --push 可先只做本地同步。"
  fi
  log "（仅 fetch/merge 的话可继续，不影响本阶段）"
else
  log "推送远端可达：$PUSH_REMOTE"
fi

# ------------------------------------------------------- 阶段 1：fetch 上游
log "阶段 1/4：fetch $UPSTREAM $BRANCH_UPSTREAM"
git fetch "$UPSTREAM" "$BRANCH_UPSTREAM" \
  || die "fetch 失败（网络/代理）。无副作用，可直接重跑。"

BEHIND="$(git rev-list --count "$BRANCH_UPSTREAM..$UPSTREAM/$BRANCH_UPSTREAM")"
UP_HEAD="$(git rev-parse --short "$UPSTREAM/$BRANCH_UPSTREAM")"

# --------------------------------------------------- 阶段 2：报告落后与改动面
log "阶段 2/4：落后报告"
printf '        本地 %-12s : %s\n' "$BRANCH_UPSTREAM" "$(git rev-parse --short "$BRANCH_UPSTREAM")"
printf '        上游 %-12s : %s\n' "$UPSTREAM/$BRANCH_UPSTREAM" "$UP_HEAD"
printf '        落后提交数        : %s\n' "$BEHIND"

if [[ "$BEHIND" -eq 0 ]]; then
  log "已是最新，无需同步。"
  log "当前基线: $(git rev-parse --short "$BRANCH_UPSTREAM")"
  if [[ $DO_PUSH -eq 1 ]]; then
    log "检查 $PUSH_REMOTE 上两个分支是否需要推送..."
    for b in "$BRANCH_UPSTREAM" "$BRANCH_CUSTOM"; do
      if git ls-remote --exit-code --heads "$PUSH_REMOTE" "$b" >/dev/null 2>&1; then
        local_head="$(git rev-parse "$b")"
        remote_head="$(git rev-parse "$PUSH_REMOTE/$b" 2>/dev/null || true)"
        [[ "$local_head" != "$remote_head" ]] && log "  待推送: $b"
      else
        log "  远端尚无分支: $b"
      fi
    done
  fi
  exit 0
fi

echo
log "上游新增提交（最近 20 条）："
git --no-pager log -n 20 --oneline --no-decorate \
  "$BRANCH_UPSTREAM..$UPSTREAM/$BRANCH_UPSTREAM" | sed 's/^/        /'
echo
log "改动面（上游改了哪些文件，Top 30）："
git --no-pager diff --stat "$BRANCH_UPSTREAM" "$UPSTREAM/$BRANCH_UPSTREAM" | tail -30 | sed 's/^/        /'

if [[ $APPLY -eq 0 ]]; then
  echo
  log "以上为检查结果。【未修改任何东西】"
  log "确认无误后执行：  ./scripts/sync-upstream.sh --apply"
  exit 0
fi

# --------------------------------------------- 阶段 3 前置：仓库状态必须干净
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  warn "存在未提交的已跟踪文件改动，拒绝同步（避免把定制改动混进上游合并）："
  git status --short --untracked-files=no | sed 's/^/        /' >&2
  die "请先提交或 stash 你的改动，再重跑。" 2
fi

# 记录原分支，任何情况下都恢复，避免失败后卡在中间分支
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
restore_branch() {
  local cur
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [[ "$cur" != "$ORIG_BRANCH" && -n "$ORIG_BRANCH" ]]; then
    # 合并冲突时不要自动切走，保留现场给用户处理
    if [[ -z "$(git diff --name-only --diff-filter=U)" ]]; then
      git checkout "$ORIG_BRANCH" >/dev/null 2>&1 || true
      log "已恢复分支：$ORIG_BRANCH"
    else
      warn "存在未解决的冲突，保留当前分支（$cur）以便处理。"
    fi
  fi
}
trap restore_branch EXIT

confirm "将执行：main 前进到 $UP_HEAD，然后合并进 $BRANCH_CUSTOM。继续？" || die "已取消。" 1

# ------------------------------------------- 阶段 3：main 仅 fast-forward 前进
log "阶段 3/4：$BRANCH_UPSTREAM 仅 fast-forward 前进"
git checkout "$BRANCH_UPSTREAM" >/dev/null
git merge --ff-only "$UPSTREAM/$BRANCH_UPSTREAM" \
  || die "$BRANCH_UPSTREAM 无法 fast-forward —— 说明它上面出现了定制提交（违反双轨制铁律）。请检查后手动处理。" 2
log "$BRANCH_UPSTREAM 已前进至 $(git rev-parse --short "$BRANCH_UPSTREAM")"

# -------------------------------------- 阶段 4：合并进定制轨 + 冲突分派提示
log "阶段 4/4：合并进 $BRANCH_CUSTOM"
git checkout "$BRANCH_CUSTOM" >/dev/null

if git merge --no-edit "$BRANCH_UPSTREAM"; then
  log "合并成功，无冲突。"
else
  echo
  warn "================ 检测到合并冲突 ================"
  CONFLICTS="$(git diff --name-only --diff-filter=U)"
  echo "$CONFLICTS" | sed 's/^/        /' >&2
  echo >&2
  warn "分派规则（方案文档 4.3 / 5.3）："
  for f in $CONFLICTS; do
    is_hot=0
    for h in "${HOTSPOTS[@]}"; do
      [[ "$f" == "$h" ]] && is_hot=1
    done
    if [[ $is_hot -eq 1 ]]; then
      warn "  [接线点] $f —— 需人工三向合并，保留你的定制意图"
    else
      warn "  [非接线点] $f —— 一律接受上游：  git checkout --theirs '$f' && git add '$f'"
    fi
  done
  echo >&2
  warn "铁律：L5 类冲突【禁止硬解】。若确实需要自定义逻辑，"
  warn "      应把逻辑重构到独立目录（新文件），而不是在上游文件里硬拼。"
  warn "放弃本次合并：git merge --abort"
  warn "处理完提交： git add <files> && git commit"
  exit 3
fi

# ------------------------------------------------------------------ 收尾
NEW_BASE="$(git rev-parse --short "$BRANCH_UPSTREAM")"

if [[ $DO_PUSH -eq 1 ]]; then
  log "推送到 $PUSH_REMOTE ..."
  git push "$PUSH_REMOTE" "$BRANCH_UPSTREAM" || die "推送 $BRANCH_UPSTREAM 失败。本地已完成同步，可稍后重试推送。"
  git push "$PUSH_REMOTE" "$BRANCH_CUSTOM"   || die "推送 $BRANCH_CUSTOM 失败。本地已完成同步，可稍后重试推送。"
  log "推送完成。"
fi

echo
log "同步完成。新基线：$NEW_BASE"

# 推断上游版本：优先用 tag；本地通常不 fetch tag，故回退到迁移版本目录（最新的 V*.*.*）
UP_VERSION="$(git describe --tags --always --dirty "$BRANCH_UPSTREAM" 2>/dev/null || true)"
if [[ -z "$UP_VERSION" || "$UP_VERSION" =~ ^[0-9a-f]{7,}$ ]]; then
  UP_VERSION="$(git ls-tree --name-only "$BRANCH_UPSTREAM" deploy/migrations/versions/ 2>/dev/null \
    | sed 's#.*/versions/##' | grep -E '^V[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 || true)"
fi
[[ -z "$UP_VERSION" ]] && UP_VERSION="-"
AUTHOR="${SUDO_USER:-${USER:-$(git config user.name || echo unknown)}}"

echo
log "请把下面这行追加到 .custom/tracking.md 的「基线台账」表格："
echo
printf '        | %s | `%s` | %s | 已同步 | %s | %s |\n' \
  "$(date +%F)" "$NEW_BASE" "$UP_VERSION" "见本次合并" "$AUTHOR"
echo
log "提示：本次若碰了上游文件，记得在「定制登记表」新增对应行。"
echo
log "提示：本次若碰了上游文件，记得在「定制登记表」新增对应行。"
