#!/usr/bin/env bash
#
# preprocess-videos.sh
#
# 对视频（单个文件 或 目录下所有视频）进行预处理：
#   - 提取音频（16kHz 单声道 wav）
#   - 按固定间隔提取关键帧截图
#   - 用 whisper.cpp 生成中文字幕（.srt / .txt）
#
# 所有产物统一缓存到视频所在目录下的 video-notes-cache/，
# 配合 Cursor Skill 可以让 AI 助手快速消费这些素材产出文档。
#
# Usage:
#   ./preprocess-videos.sh <目录|视频文件>                预处理
#   ./preprocess-videos.sh <目录|视频文件> --model small  换模型（tiny/base/small/medium/large-v3）
#   ./preprocess-videos.sh <目录|视频文件> --status       查看缓存状态
#   ./preprocess-videos.sh <目录|视频文件> --clean        删除缓存（目录=整个缓存；单视频=只删该视频的子目录）
#   ./preprocess-videos.sh <目录|视频文件> --retry-failed 重跑失败的视频
#   ./preprocess-videos.sh --help                         显示本帮助
#
# 说明：
#   - 传目录：处理目录下所有视频（一级目录，不递归）
#   - 传视频文件：只处理这一个视频，缓存仍然放在视频所在目录的 video-notes-cache/ 下
#   - 缓存幂等：用文件大小+mtime 做指纹，视频没变则跳过
#
# Environment variables:
#   WHISPER_MODELS_DIR   whisper 模型目录（默认 $HOME/whisper-models）
#   FRAME_INTERVAL       截图间隔秒数（默认 15）
#   VIDEO_EXTENSIONS     视频扩展名（默认 mp4 mkv mov avi webm flv）
#

set -o pipefail

# ============================================================
# 常量 / 全局状态
# ============================================================
readonly SCRIPT_VERSION="1.1.0"
readonly DEFAULT_MODEL="medium"
readonly DEFAULT_FRAME_INTERVAL="${FRAME_INTERVAL:-15}"
readonly DEFAULT_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4 mkv mov avi webm flv}"
readonly WHISPER_MODELS_DIR="${WHISPER_MODELS_DIR:-$HOME/whisper-models}"
readonly CACHE_DIR_NAME="video-notes-cache"

# 颜色输出（若非终端自动关闭）
if [[ -t 1 ]]; then
    readonly C_RESET="\033[0m"
    readonly C_RED="\033[31m"
    readonly C_GREEN="\033[32m"
    readonly C_YELLOW="\033[33m"
    readonly C_BLUE="\033[34m"
    readonly C_CYAN="\033[36m"
    readonly C_DIM="\033[2m"
    readonly C_BOLD="\033[1m"
else
    readonly C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_DIM="" C_BOLD=""
fi

# 运行态参数
TARGET=""           # 原始传入：目录或视频文件
TARGET_DIR=""       # 归一化后的目录（对单视频，就是它的父目录）
TARGET_VIDEO=""     # 若传入的是视频文件，这里存它的 basename；否则为空
MODEL_NAME="$DEFAULT_MODEL"
MODE="process"      # process / status / clean / retry-failed

# ============================================================
# 输出辅助
# ============================================================
log_info()    { printf "${C_CYAN}[INFO]${C_RESET}  %s\n"  "$*"; }
log_ok()      { printf "${C_GREEN}[ OK ]${C_RESET}  %s\n" "$*"; }
log_warn()    { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
log_error()   { printf "${C_RED}[ERR ]${C_RESET}  %s\n"  "$*" >&2; }
log_step()    { printf "\n${C_BOLD}${C_BLUE}==> %s${C_RESET}\n" "$*"; }

# 打印 usage
print_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^#\s\?//'
    exit 0
}

# ============================================================
# 前置检查
# ============================================================
check_dependencies() {
    local missing=()
    command -v ffmpeg       >/dev/null 2>&1 || missing+=("ffmpeg")
    command -v ffprobe      >/dev/null 2>&1 || missing+=("ffprobe")
    command -v whisper-cli  >/dev/null 2>&1 || missing+=("whisper-cli (whisper-cpp)")

    if (( ${#missing[@]} > 0 )); then
        log_error "缺少必要依赖："
        for dep in "${missing[@]}"; do
            printf "        - %s\n" "$dep" >&2
        done
        cat >&2 <<EOF

macOS 安装：
  brew install ffmpeg whisper-cpp

EOF
        exit 1
    fi
}

# 确保模型已下载
ensure_model() {
    local model_file="$WHISPER_MODELS_DIR/ggml-${MODEL_NAME}.bin"
    if [[ -f "$model_file" ]]; then
        log_info "使用模型 ${C_BOLD}${MODEL_NAME}${C_RESET}: $model_file"
        return 0
    fi

    log_warn "模型文件不存在：$model_file"
    log_info "正在下载 ggml-${MODEL_NAME}.bin ..."
    mkdir -p "$WHISPER_MODELS_DIR"

    local model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
    if ! curl -L --fail --progress-bar -o "$model_file.part" "$model_url"; then
        log_error "模型下载失败: $model_url"
        rm -f "$model_file.part"
        exit 1
    fi
    mv "$model_file.part" "$model_file"
    log_ok "模型已下载到 $model_file"
}

# ============================================================
# 视频发现与指纹
# ============================================================

# 判断一个文件是否是受支持的视频文件（按扩展名）
is_video_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local lower="${file##*.}"
    # 转小写（bash 4+ 有 ${var,,}，但 macOS 自带 bash 3.2，用 tr）
    lower=$(printf '%s' "$lower" | tr '[:upper:]' '[:lower:]')
    local ext
    # shellcheck disable=SC2206
    local exts=( $DEFAULT_EXTENSIONS )
    for ext in "${exts[@]}"; do
        [[ "$lower" == "$ext" ]] && return 0
    done
    return 1
}

# 列出目录下所有视频（一级目录，不递归）
find_videos() {
    local dir="$1"
    local exts ext
    # shellcheck disable=SC2206
    exts=( $DEFAULT_EXTENSIONS )

    local name_args=()
    for ext in "${exts[@]}"; do
        name_args+=( -iname "*.$ext" -o )
    done
    # 移除最后一个 -o
    unset "name_args[-1]"

    # 用 find + null 分隔符，避免文件名空格问题
    find "$dir" -maxdepth 1 -type f \( "${name_args[@]}" \) -print0 | sort -z
}

# 获取文件指纹（大小+mtime），用于判断是否需要重跑
file_fingerprint() {
    local file="$1"
    local size mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        size=$(stat -f "%z" "$file")
        mtime=$(stat -f "%m" "$file")
    else
        size=$(stat -c "%s" "$file")
        mtime=$(stat -c "%Y" "$file")
    fi
    echo "${size}-${mtime}"
}

# 获取视频时长（秒，整数）
video_duration() {
    local file="$1"
    local dur
    dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo "0")
    printf "%.0f" "$dur" 2>/dev/null || echo "0"
}

# 把秒数格式化成 MM:SS
format_duration() {
    local secs="$1"
    printf "%02d:%02d" $((secs / 60)) $((secs % 60))
}

# ============================================================
# 单个视频处理
# ============================================================

# 处理单个视频
# $1 视频路径
# $2 缓存目录
# $3/$4 当前索引/总数（用于进度显示）
process_one_video() {
    local video="$1"
    local cache_dir="$2"
    local idx="$3"
    local total="$4"

    local basename="${video##*/}"
    local name_without_ext="${basename%.*}"
    local work_dir="$cache_dir/$name_without_ext"
    local fp_current fp_cached duration duration_str

    fp_current=$(file_fingerprint "$video")
    duration=$(video_duration "$video")
    duration_str=$(format_duration "$duration")

    log_step "[$idx/$total] $basename ($duration_str)"

    # 缓存命中检查
    if [[ -f "$work_dir/.fingerprint" ]] && [[ -f "$work_dir/transcript.srt" ]] && [[ -f "$work_dir/transcript.txt" ]]; then
        fp_cached=$(<"$work_dir/.fingerprint")
        if [[ "$fp_current" == "$fp_cached" ]]; then
            log_info "已缓存（跳过）"
            update_manifest "$cache_dir" "$basename" "cached" "$duration"
            return 0
        else
            log_warn "视频指纹变化（文件被替换），重新处理"
            rm -rf "$work_dir"
        fi
    fi

    mkdir -p "$work_dir/frames"

    # 1. 提取音频
    local audio="$work_dir/audio.wav"
    log_info "  [1/3] 提取音频..."
    if ! ffmpeg -y -i "$video" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$audio" >/dev/null 2>"$work_dir/ffmpeg-audio.log"; then
        log_error "音频提取失败，详见 $work_dir/ffmpeg-audio.log"
        update_manifest "$cache_dir" "$basename" "failed-audio" "$duration"
        return 1
    fi

    # 2. 提取关键帧
    log_info "  [2/3] 提取截图（每 ${DEFAULT_FRAME_INTERVAL}s 一张）..."
    if ! ffmpeg -y -i "$video" -vf "fps=1/${DEFAULT_FRAME_INTERVAL},scale=1280:-1" -q:v 3 "$work_dir/frames/frame_%03d.jpg" >/dev/null 2>"$work_dir/ffmpeg-frames.log"; then
        log_warn "截图提取失败（忽略，继续），详见 $work_dir/ffmpeg-frames.log"
    fi

    # 3. whisper 转写
    log_info "  [3/3] whisper 转写中文字幕（模型：${MODEL_NAME}）..."
    local model_file="$WHISPER_MODELS_DIR/ggml-${MODEL_NAME}.bin"
    local wt_start wt_end wt_secs
    wt_start=$(date +%s)

    if ! whisper-cli \
            -m "$model_file" \
            -f "$audio" \
            -l zh \
            -otxt -osrt \
            -of "$work_dir/transcript" \
            --no-prints \
            >"$work_dir/whisper.log" 2>&1; then
        log_error "转写失败，详见 $work_dir/whisper.log"
        update_manifest "$cache_dir" "$basename" "failed-whisper" "$duration"
        return 1
    fi

    wt_end=$(date +%s)
    wt_secs=$((wt_end - wt_start))

    # 清理中间文件（音频可以删，截图保留）
    rm -f "$audio"
    rm -f "$work_dir/ffmpeg-audio.log"

    # 写指纹
    echo "$fp_current" > "$work_dir/.fingerprint"

    log_ok "  完成（转写 ${wt_secs}s）"
    update_manifest "$cache_dir" "$basename" "done" "$duration"
    return 0
}

# ============================================================
# manifest（缓存索引，简单 tsv 格式）
# 字段：basename \t status \t duration_sec \t timestamp
# ============================================================

manifest_path() { echo "$1/manifest.tsv"; }

# 写入/更新一条记录
update_manifest() {
    local cache_dir="$1" basename="$2" status="$3" duration="$4"
    local manifest
    manifest=$(manifest_path "$cache_dir")
    local ts
    ts=$(date +%s)

    # 原子更新：用临时文件
    local tmp
    tmp=$(mktemp)

    if [[ -f "$manifest" ]]; then
        # 删除同名旧记录（第一列匹配）
        awk -F'\t' -v name="$basename" '$1 != name' "$manifest" > "$tmp" || true
    fi
    printf "%s\t%s\t%s\t%s\n" "$basename" "$status" "$duration" "$ts" >> "$tmp"
    mv "$tmp" "$manifest"
}

# 从 manifest 中查找指定视频的条目，找到后把字段打印到 stdout（tab 分隔），否则返回 1
lookup_manifest() {
    local cache_dir="$1" basename="$2"
    local manifest
    manifest=$(manifest_path "$cache_dir")
    [[ -f "$manifest" ]] || return 1
    local line
    line=$(awk -F'\t' -v name="$basename" '$1 == name { print; found=1; exit } END { exit !found }' "$manifest") || return 1
    printf '%s' "$line"
}

# 把 tab 分隔的 manifest 行转成人类可读的格式化行
# $1 basename $2 status $3 duration $4 ts
render_manifest_row() {
    local basename="$1" status="$2" duration="$3" ts="$4"
    local time_str
    if [[ "$(uname)" == "Darwin" ]]; then
        time_str=$(date -r "$ts" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "-")
    else
        time_str=$(date -d "@$ts" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "-")
    fi

    local status_color="$C_RESET"
    case "$status" in
        done)    status_color="$C_GREEN"  ;;
        cached)  status_color="$C_DIM"    ;;
        failed*) status_color="$C_RED"    ;;
    esac

    local dur_str
    dur_str=$(format_duration "${duration:-0}")

    printf "  %-50s  ${status_color}%-12s${C_RESET}  %-10s  %s\n" \
        "${basename:0:50}" "$status" "$dur_str" "$time_str"
}

# ============================================================
# 各 MODE 的主入口
# ============================================================

mode_process() {
    check_dependencies
    ensure_model

    local cache_dir="$TARGET_DIR/$CACHE_DIR_NAME"
    mkdir -p "$cache_dir"

    local videos=()

    if [[ -n "$TARGET_VIDEO" ]]; then
        # 单视频模式
        log_step "处理单个视频：$TARGET_VIDEO"
        videos=( "$TARGET_DIR/$TARGET_VIDEO" )
    else
        # 目录模式
        log_step "扫描目录：$TARGET_DIR"
        while IFS= read -r -d '' f; do videos+=("$f"); done < <(find_videos "$TARGET_DIR")
        local total=${#videos[@]}
        if (( total == 0 )); then
            log_warn "目录下没有找到视频文件（扩展名: $DEFAULT_EXTENSIONS）"
            exit 0
        fi
        log_info "发现 $total 个视频文件"
    fi

    local total=${#videos[@]}
    local start_ts end_ts
    start_ts=$(date +%s)

    local ok=0 fail=0 cached=0 idx=0
    for v in "${videos[@]}"; do
        idx=$((idx + 1))
        # 判断这次是不是缓存命中（用于统计）
        local basename="${v##*/}"
        local name_without_ext="${basename%.*}"
        local work_dir="$cache_dir/$name_without_ext"
        local was_cached=0
        if [[ -f "$work_dir/.fingerprint" && -f "$work_dir/transcript.srt" && -f "$work_dir/transcript.txt" ]]; then
            local fp_current fp_cached
            fp_current=$(file_fingerprint "$v")
            fp_cached=$(<"$work_dir/.fingerprint")
            [[ "$fp_current" == "$fp_cached" ]] && was_cached=1
        fi

        if process_one_video "$v" "$cache_dir" "$idx" "$total"; then
            if (( was_cached == 1 )); then
                cached=$((cached + 1))
            else
                ok=$((ok + 1))
            fi
        else
            fail=$((fail + 1))
        fi
    done

    end_ts=$(date +%s)
    local elapsed=$((end_ts - start_ts))

    log_step "处理完成"
    printf "  %s%d%s 个新处理，%s%d%s 个缓存命中，%s%d%s 个失败\n" \
        "$C_GREEN" "$ok" "$C_RESET" \
        "$C_DIM" "$cached" "$C_RESET" \
        "$C_RED" "$fail" "$C_RESET"
    printf "  耗时：%s  缓存位置：%s\n" "$(format_duration "$elapsed")" "$cache_dir"
    if (( fail > 0 )); then
        printf "  重试失败的视频：%s <同一参数> --retry-failed\n" "$0"
        exit 2
    fi
}

mode_status() {
    local cache_dir="$TARGET_DIR/$CACHE_DIR_NAME"

    # 单视频：只查该视频
    if [[ -n "$TARGET_VIDEO" ]]; then
        log_step "缓存状态（单视频）：$TARGET_VIDEO"
        if [[ ! -d "$cache_dir" ]]; then
            log_warn "尚未预处理过（缓存目录不存在）：$cache_dir"
            exit 0
        fi

        local line
        if ! line=$(lookup_manifest "$cache_dir" "$TARGET_VIDEO"); then
            log_warn "该视频尚未处理（manifest 中无记录）"
            exit 0
        fi

        printf "\n  %-50s  %-12s  %-10s  %s\n" "视频" "状态" "时长" "时间"
        printf "  %-50s  %-12s  %-10s  %s\n" "$(printf '%.0s-' {1..50})" "------------" "----------" "-------------------"
        IFS=$'\t' read -r basename status duration ts <<<"$line"
        render_manifest_row "$basename" "$status" "$duration" "$ts"
        return 0
    fi

    # 目录：列出 manifest 里已有的所有条目
    if [[ ! -d "$cache_dir" ]]; then
        log_warn "该目录尚未预处理过（缓存不存在）：$cache_dir"
        exit 0
    fi

    log_step "缓存状态：$cache_dir"

    local manifest
    manifest=$(manifest_path "$cache_dir")
    if [[ ! -f "$manifest" ]]; then
        log_warn "manifest.tsv 不存在（缓存目录为空或是旧版本）"
        exit 0
    fi

    printf "\n  %-50s  %-12s  %-10s  %s\n" "视频" "状态" "时长" "时间"
    printf "  %-50s  %-12s  %-10s  %s\n" "$(printf '%.0s-' {1..50})" "------------" "----------" "-------------------"

    local total=0 done_n=0 failed_n=0 cached_n=0
    while IFS=$'\t' read -r basename status duration ts; do
        total=$((total + 1))
        case "$status" in
            done)    done_n=$((done_n + 1))   ;;
            cached)  cached_n=$((cached_n + 1)) ;;
            failed*) failed_n=$((failed_n + 1)) ;;
        esac
        render_manifest_row "$basename" "$status" "$duration" "$ts"
    done < "$manifest"

    echo
    printf "  共 ${C_BOLD}%d${C_RESET} 个条目：%d 完成 / %d 命中缓存 / %d 失败\n" \
        "$total" "$done_n" "$cached_n" "$failed_n"
}

mode_clean() {
    local cache_dir="$TARGET_DIR/$CACHE_DIR_NAME"

    # 单视频：只删这一个视频对应的子目录，并从 manifest 里移除
    if [[ -n "$TARGET_VIDEO" ]]; then
        local name_without_ext="${TARGET_VIDEO%.*}"
        local work_dir="$cache_dir/$name_without_ext"
        if [[ ! -d "$work_dir" ]]; then
            log_warn "该视频没有缓存：$work_dir"
            exit 0
        fi

        local size
        size=$(du -sh "$work_dir" 2>/dev/null | awk '{print $1}')
        log_warn "将要删除单视频缓存：$work_dir （$size）"
        printf "${C_YELLOW}确认删除？[y/N]${C_RESET} "
        local ans
        read -r ans
        if [[ ! "$ans" =~ ^[yY]$ ]]; then
            log_info "已取消"
            return 0
        fi

        rm -rf "$work_dir"
        # 从 manifest 中移除该行
        local manifest
        manifest=$(manifest_path "$cache_dir")
        if [[ -f "$manifest" ]]; then
            local tmp
            tmp=$(mktemp)
            awk -F'\t' -v name="$TARGET_VIDEO" '$1 != name' "$manifest" > "$tmp" || true
            mv "$tmp" "$manifest"
        fi
        log_ok "已删除"
        return 0
    fi

    # 目录：删除整个 cache_dir
    if [[ ! -d "$cache_dir" ]]; then
        log_warn "缓存目录不存在：$cache_dir"
        exit 0
    fi

    local size
    size=$(du -sh "$cache_dir" 2>/dev/null | awk '{print $1}')
    log_warn "将要删除缓存目录：$cache_dir （$size）"
    printf "${C_YELLOW}确认删除？[y/N]${C_RESET} "
    local ans
    read -r ans
    if [[ "$ans" =~ ^[yY]$ ]]; then
        rm -rf "$cache_dir"
        log_ok "已删除"
    else
        log_info "已取消"
    fi
}

mode_retry_failed() {
    check_dependencies
    ensure_model

    local cache_dir="$TARGET_DIR/$CACHE_DIR_NAME"
    local manifest
    manifest=$(manifest_path "$cache_dir")

    # 单视频：判断该条是否 failed，是则重跑
    if [[ -n "$TARGET_VIDEO" ]]; then
        if [[ ! -f "$manifest" ]]; then
            log_warn "无 manifest，直接按常规处理"
            mode_process
            return
        fi
        local line status
        if ! line=$(lookup_manifest "$cache_dir" "$TARGET_VIDEO"); then
            log_warn "该视频不在 manifest 中，直接按常规处理"
            mode_process
            return
        fi
        status=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
        if [[ "$status" != failed* ]]; then
            log_ok "该视频状态为 $status，无需重试"
            exit 0
        fi
        # 删除旧缓存再重跑
        local name_without_ext="${TARGET_VIDEO%.*}"
        rm -rf "$cache_dir/$name_without_ext"
        local video="$TARGET_DIR/$TARGET_VIDEO"
        if process_one_video "$video" "$cache_dir" 1 1; then
            log_step "重试完成：1 成功，0 失败"
            return 0
        else
            log_step "重试完成：0 成功，1 失败"
            exit 2
        fi
    fi

    # 目录：收集所有失败项再跑
    if [[ ! -f "$manifest" ]]; then
        log_warn "无 manifest，使用常规 process 模式"
        mode_process
        return
    fi

    local failed=()
    while IFS=$'\t' read -r basename status _ _; do
        [[ "$status" == failed* ]] && failed+=("$basename")
    done < "$manifest"

    if (( ${#failed[@]} == 0 )); then
        log_ok "没有失败的视频"
        exit 0
    fi

    log_info "重试 ${#failed[@]} 个失败视频"
    local idx=0 total=${#failed[@]}
    local ok=0 fail=0
    for name in "${failed[@]}"; do
        idx=$((idx + 1))
        local video="$TARGET_DIR/$name"
        if [[ ! -f "$video" ]]; then
            log_warn "视频已不存在：$video，跳过"
            continue
        fi
        local name_without_ext="${name%.*}"
        rm -rf "$cache_dir/$name_without_ext"
        if process_one_video "$video" "$cache_dir" "$idx" "$total"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    log_step "重试完成：$ok 成功，$fail 失败"
    (( fail == 0 )) || exit 2
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    if (( $# == 0 )); then
        print_help
    fi

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                print_help
                ;;
            --model)
                [[ -z "${2:-}" ]] && { log_error "--model 需要参数"; exit 1; }
                MODEL_NAME="$2"
                shift 2
                ;;
            --status)
                MODE="status"
                shift
                ;;
            --clean)
                MODE="clean"
                shift
                ;;
            --retry-failed)
                MODE="retry-failed"
                shift
                ;;
            --version)
                echo "preprocess-videos.sh v$SCRIPT_VERSION"
                exit 0
                ;;
            --*)
                log_error "未知选项：$1"
                exit 1
                ;;
            *)
                if [[ -z "$TARGET" ]]; then
                    TARGET="$1"
                else
                    log_error "只接受一个路径参数，已经设置为 '$TARGET'"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$TARGET" ]]; then
        log_error "缺少路径参数（目录或视频文件）"
        print_help
    fi

    # 归一化 TARGET
    if [[ -d "$TARGET" ]]; then
        # 目录
        TARGET_DIR="${TARGET%/}"
        TARGET_VIDEO=""
    elif [[ -f "$TARGET" ]]; then
        # 文件
        if ! is_video_file "$TARGET"; then
            log_error "不是受支持的视频文件：$TARGET"
            log_error "支持扩展名：$DEFAULT_EXTENSIONS"
            exit 1
        fi
        # 取父目录。对相对路径如 "16-1.mp4"，dirname 返回 "."
        local dir
        dir=$(cd "$(dirname "$TARGET")" && pwd) || { log_error "无法解析父目录：$TARGET"; exit 1; }
        TARGET_DIR="$dir"
        TARGET_VIDEO="$(basename "$TARGET")"
    else
        log_error "路径不存在：$TARGET"
        exit 1
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"
    case "$MODE" in
        process)       mode_process ;;
        status)        mode_status ;;
        clean)         mode_clean ;;
        retry-failed)  mode_retry_failed ;;
        *) log_error "未知模式：$MODE"; exit 1 ;;
    esac
}

main "$@"
