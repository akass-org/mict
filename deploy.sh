#!/bin/bash
# 部署米哈游词库到 fcitx5-rime
#
# 用法: ./deploy.sh [选项]
#
# 选项:
#   -n, --dry-run   模拟运行，不实际修改文件
#   -l, --link      使用符号链接代替复制 mict/ 词库
#   -h, --help      显示此帮助

set -euo pipefail

RIME_DIR="${RIME_DIR:-$HOME/.local/share/fcitx5/rime}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DICTS=(
    "genshin_impact"
    "honkai_star_rail"
)

DRY_RUN=false
USE_LINK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)     DRY_RUN=true; shift ;;
        -l|--link)        USE_LINK=true; shift ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  -n, --dry-run   模拟运行，不实际修改文件"
            echo "  -l, --link      使用符号链接代替复制 mict/ 词库"
            echo "  -h, --help      显示此帮助"
            exit 0
            ;;
        *) echo "未知参数: $1 (使用 -h 查看帮助)"; exit 1 ;;
    esac
done

# 在 Rime 搜索路径中查找文件（用户目录优先）
find_rime_file() {
    local filename="$1"
    for dir in "$RIME_DIR" /usr/share/rime-data /usr/share/fcitx5/rime; do
        if [[ -f "$dir/$filename" ]]; then
            echo "$dir/$filename"
            return 0
        fi
    done
    return 1
}

DICT_DIR="$RIME_DIR/mict"
SCHEMA="${SCHEMA:-$(awk '/previously_selected_schema/{print $2}' "$RIME_DIR/user.yaml" 2>/dev/null || true)}"

$DRY_RUN && echo "[dry-run] 模拟运行，不会实际修改文件"

echo ""
echo "=== 部署词库文件 ==="
if ! $DRY_RUN; then
    mkdir -p "$DICT_DIR"
fi

for name in "${DICTS[@]}"; do
    src="$SCRIPT_DIR/${name}.dict.yaml"
    dst="$DICT_DIR/${name}.dict.yaml"

    if [[ ! -f "$src" ]]; then
        echo "  ✗ ${name}.dict.yaml 不存在，跳过"
        continue
    fi

    if [[ -L "$dst" ]]; then
        [[ "$(readlink "$dst")" == "$src" ]] && { echo "  - ${name}.dict.yaml 链接正确，跳过"; continue; }
    fi

    if [[ -f "$dst" ]] && ! [[ -L "$dst" ]] && cmp -s "$src" "$dst"; then
        echo "  - ${name}.dict.yaml 无变化，跳过"
        continue
    fi

    if $DRY_RUN; then
        echo "  ~ ${name}.dict.yaml 将被$($USE_LINK && echo "链接" || echo "复制")"
        continue
    fi

    rm -f "$dst"
    if $USE_LINK; then
        ln -s "$src" "$dst"
        echo "  ✓ ${name}.dict.yaml (符号链接)"
    else
        cp "$src" "$dst"
        echo "  ✓ ${name}.dict.yaml (复制)"
    fi
done

# 配置当前方案的字典
echo ""
if [[ -n "${SCHEMA:-}" ]]; then
    echo "=== 配置方案: $SCHEMA ==="

    # 尝试从 schema.yaml 读取字典名，fallback 为方案名
    dict_name="$SCHEMA"
    schema_file=$(find_rime_file "$SCHEMA.schema.yaml" || true)
    if [[ -n "$schema_file" ]]; then
        parsed=$(awk '/^translator:/{flag=1} flag && /dictionary:/{print $2; exit}' "$schema_file" 2>/dev/null || true)
        [[ -n "$parsed" ]] && dict_name="$parsed"
    fi

    dict_file="$RIME_DIR/${dict_name}.dict.yaml"

    # 用户目录没有该字典时，从系统目录复制
    if [[ ! -f "$dict_file" ]]; then
        system_dict=$(find_rime_file "${dict_name}.dict.yaml" || true)
        if [[ -n "$system_dict" ]]; then
            if $DRY_RUN; then
                echo "  ~ 将从系统目录复制 ${dict_name}.dict.yaml"
            else
                cp "$system_dict" "$dict_file"
                echo "  ✓ 已复制 ${dict_name}.dict.yaml 到用户目录"
            fi
        else
            echo "  ! 找不到 ${dict_name}.dict.yaml，无法自动配置"
        fi
    elif [[ -L "$dict_file" ]]; then
        echo "  ! ${dict_name}.dict.yaml 是符号链接，跳过修改（避免修改系统文件）"
    fi

    # 在字典文件中添加 mict 词库引用
    if [[ -f "$dict_file" ]] && ! [[ -L "$dict_file" ]]; then
        # 检查缺失的条目
        missing=()
        for name in "${DICTS[@]}"; do
            if ! grep -q "mict/$name" "$dict_file"; then
                missing+=("$name")
            fi
        done

        if [[ ${#missing[@]} -eq 0 ]]; then
            echo "  - 字典已包含所有 mict 词库，跳过"
        elif $DRY_RUN; then
            echo "  ~ 将在 ${dict_name}.dict.yaml 中添加 ${#missing[@]} 个 mict 词库引用"
        else
            if grep -q "^import_tables:" "$dict_file"; then
                # 在 import_tables 列表开头插入新条目
                import_line=$(grep -n "^import_tables:" "$dict_file" | head -1 | cut -d: -f1)
                for ((i=${#missing[@]}-1; i>=0; i--)); do
                    sed -i "${import_line}a\\  - mict/${missing[$i]}" "$dict_file"
                done
            else
                # 没有 import_tables，需要创建
                tmpfile=$(mktemp)
                if tail -1 "$dict_file" | grep -q '^\.\.\.$'; then
                    # 文件末尾有 YAML 文档结束标记 ...，在它之前插入
                    head -n -1 "$dict_file" > "$tmpfile"
                    {
                        echo "import_tables:"
                        for name in "${missing[@]}"; do
                            echo "  - mict/$name"
                        done
                        echo "..."
                    } >> "$tmpfile"
                else
                    cp "$dict_file" "$tmpfile"
                    {
                        echo ""
                        echo "import_tables:"
                        for name in "${missing[@]}"; do
                            echo "  - mict/$name"
                        done
                    } >> "$tmpfile"
                fi
                mv "$tmpfile" "$dict_file"
            fi
            echo "  ✓ 已在 ${dict_name}.dict.yaml 中添加 mict 词库引用"
        fi
    fi
else
    echo "=== 配置方案 ==="
    echo "  未能检测到当前方案，请手动在 dict.yaml 中添加:"
    for name in "${DICTS[@]}"; do
        echo "    - mict/$name"
    done
fi

echo ""
if ! $DRY_RUN; then
    echo "=== 重载 fcitx5 ==="
    if fcitx5-remote -r 2>/dev/null; then
        echo "  ✓ 已通知 fcitx5 重新部署"
    elif command -v fcitx5 >/dev/null 2>&1; then
        if command -v setsid >/dev/null 2>&1; then
            setsid fcitx5 -r -d >/dev/null 2>&1 </dev/null
        else
            fcitx5 -r -d >/dev/null 2>&1 </dev/null &
        fi
        echo "  ✓ fcitx5 已重启"
    else
        echo "  ! 无法自动重载，请手动运行: fcitx5-remote -r"
    fi
fi

echo ""
echo "完成"
