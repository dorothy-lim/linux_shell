#!/bin/bash
# iperf_updown.sh 에서 파생: jwf_50PA_1174-04_SMA.py 로 감쇠기(ATTEN) 값을
# ATTEN_START -> ATTEN_END 까지 ATTEN_STEP 단위로 변경해 가며 iperf_updown.sh 와
# 동일한 downlink/uplink 측정을 반복 실행하고, ATTEN 별 down/up 처리량을
# 표(CSV) 형태로 모아 저장한다. (ATTEN_START, ATTEN_END 값은 항상 결과에 포함됨)

# ===== iperf3 관련 변수 (iperf_updown.sh 와 동일) =====
SERVER_IP="192.168.1.145"   # 서버 IP 주소
PORT=""                     # 값 없으면 -p 옵션 미적용 (기본 포트 5201 사용)
DURATION=10                 # 테스트 시간(초)
PARALLEL=10                 # 병렬 스트림 개수, -P 로 지정 가능
PROTOCOL="tcp"              # tcp 또는 udp
BANDWIDTH=""                # UDP일 때 대역폭 제한 (예: 100M), 비워두면 미적용
INTERVAL=1                  # 결과 출력 간격(초)

CONNECT_TIMEOUT="3000"      # --connect-timeout (밀리초). 감쇠가 커져 연결 자체가 안 될 때
                             # 무한 대기하지 않도록 기본값을 지정함 (예: 1000). 비우면 미적용
FORMAT="m"                  # -f, --format  (k,m,g,t / K,M,G,T)
OMIT="5"                    # -O, --omit N  (시작 N초 통계 제외)

LOG_DIR="./atten_sweep_logs"   # -d 로 지정 가능, 개별 iperf3 로그 저장 디렉터리
PREFIX=""                      # -o 로 지정 가능, 값 없으면 기본 파일명(prefix) 사용

# ===== 연결 끊김/timeout 대응 변수 =====
HARD_TIMEOUT_MARGIN=15       # iperf3 가 응답 없이 멈춰도 강제 종료시키기 위한 여유 시간(초)
                              # 실제 iperf3 타임아웃 = DURATION + OMIT + HARD_TIMEOUT_MARGIN
CONSEC_FAIL_LIMIT=2           # 연결 끊김/timeout 이 이 횟수만큼 연속 발생하면 스윕을 중단하고
                              # 지금까지의 결과를 정리해서 마무리한다 (0 이면 끝까지 강행)

# ===== ATTEN(감쇠기) 스윕 변수 =====
ATTEN_START=0    # 스윕 시작 ATTEN 값(dB) - 결과에 항상 포함
ATTEN_END=63     # 스윕 끝 ATTEN 값(dB)   - 결과에 항상 포함
ATTEN_STEP=3     # ATTEN 증가 step 값(dB)

ATTEN_SCRIPT="./jwf_50PA_1174-04_SMA.py"   # 감쇠기 제어 스크립트 경로
ATTEN_SETTLE_SEC=1                          # 감쇠값 적용 후 안정화 대기 시간(초)

RESULT_FILE=""   # -R 로 지정 가능, 값 없으면 기본 파일명 사용

# ===== 스크립트 실행 인자 처리 =====
# 사용법: ./iperf_atten_sweep.sh [-d 로그디렉터리] [-o 파일명prefix] [-P 병렬스트림수]
#                                 [-s ATTEN시작값] [-e ATTEN끝값] [-t ATTEN step값] [-R 결과파일]
while getopts "d:o:P:s:e:t:R:" opt; do
    case "$opt" in
        d) LOG_DIR="$OPTARG" ;;
        o) PREFIX="$OPTARG" ;;
        P) PARALLEL="$OPTARG" ;;
        s) ATTEN_START="$OPTARG" ;;
        e) ATTEN_END="$OPTARG" ;;
        t) ATTEN_STEP="$OPTARG" ;;
        R) RESULT_FILE="$OPTARG" ;;
        *)
            echo "사용법: $0 [-d 로그디렉터리] [-o 파일명prefix] [-P 병렬스트림수]" \
                 "[-s ATTEN시작값] [-e ATTEN끝값] [-t ATTEN step값] [-R 결과파일]" >&2
            exit 1
            ;;
    esac
done

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [ -z "$PREFIX" ]; then
    PREFIX="iperf_result_${TIMESTAMP}"
fi
if [ -z "$RESULT_FILE" ]; then
    RESULT_FILE="atten_sweep_result_${TIMESTAMP}.csv"
fi

mkdir -p "${LOG_DIR}"

# ===== ATTEN 값 리스트 생성 (시작/끝 값은 반드시 포함) =====
build_atten_list() {
    local start="$1" end="$2" step="$3"
    local list=()
    local v

    if [ "$step" -eq 0 ]; then
        echo "ATTEN_STEP 값은 0일 수 없습니다." >&2
        exit 1
    fi

    if [ "$start" -le "$end" ]; then
        step="${step#-}"   # 음수로 넣었어도 정방향으로 보정
        v="$start"
        while [ "$v" -le "$end" ]; do
            list+=("$v")
            v=$((v + step))
        done
    else
        step="-${step#-}"  # 역방향(큰 값 -> 작은 값) 스윕도 지원
        v="$start"
        while [ "$v" -ge "$end" ]; do
            list+=("$v")
            v=$((v + step))
        done
    fi

    # 끝 값이 step 에 의해 정확히 떨어지지 않아 리스트에 없다면 강제로 추가
    if [ "${list[-1]}" != "$end" ]; then
        list+=("$end")
    fi

    echo "${list[@]}"
}

# ===== 감쇠기 설정 함수 =====
# $1: 설정할 ATTEN 값(dB), 4채널 모두 동일 값으로 설정
set_atten() {
    local atten="$1"
    python3 "$ATTEN_SCRIPT" -a "$atten"
}

# ===== 측정 함수 (iperf_updown.sh 의 run_iperf 기반) =====
# $1: 방향 이름 (downlink 또는 uplink), $2: 이번 ATTEN 값이 포함된 파일 prefix
# iperf3 의 종료 코드는 전역 변수 IPERF_STATUS 로 전달한다.
IPERF_STATUS=0

run_iperf() {
    local direction="$1"
    local file_prefix="$2"
    local output_file="${LOG_DIR}/${file_prefix}_${direction}.log"

    # 연결이 끊기거나 패킷을 못 받아 iperf3 가 멈춰도 스윕이 무한 대기하지 않도록
    # 하드 타임아웃을 건다 (테스트 시간 + omit 구간 + 여유시간).
    local hard_timeout=$((DURATION + OMIT + HARD_TIMEOUT_MARGIN))

    local opts="-c ${SERVER_IP} -t ${DURATION} -P ${PARALLEL} -i ${INTERVAL}"

    if [ -n "$PORT" ]; then
        opts="${opts} -p ${PORT}"
    fi

    if [ "$PROTOCOL" = "udp" ]; then
        opts="${opts} -u"
        if [ -n "$BANDWIDTH" ]; then
            opts="${opts} -b ${BANDWIDTH}"
        fi
    fi

    if [ "$direction" = "uplink" ]; then
        opts="${opts} -R"
    fi

    if [ -n "$CONNECT_TIMEOUT" ]; then
        opts="${opts} --connect-timeout ${CONNECT_TIMEOUT}"
    fi

    if [ -n "$FORMAT" ]; then
        opts="${opts} -f ${FORMAT}"
    fi

    if [ -n "$OMIT" ]; then
        opts="${opts} -O ${OMIT}"
    fi

    echo "===== [${direction}] 실행 명령어: iperf3 ${opts} (timeout ${hard_timeout}s) =====" | tee "${output_file}"
    echo "[${direction}] 결과 저장 파일: ${output_file}" | tee -a "${output_file}"

    if [ "$PARALLEL" -gt 1 ]; then
        stdbuf -oL timeout "${hard_timeout}s" iperf3 ${opts} | grep --line-buffered -E "SUM|ID\]" | tee -a "${output_file}"
        IPERF_STATUS=${PIPESTATUS[0]}
    else
        stdbuf -oL timeout "${hard_timeout}s" iperf3 ${opts} | tee -a "${output_file}"
        IPERF_STATUS=${PIPESTATUS[0]}
    fi

    if [ "$IPERF_STATUS" -eq 124 ]; then
        echo "!! [${direction}] iperf3 가 ${hard_timeout}초 동안 응답이 없어 강제 종료됨 (timeout)" | tee -a "${output_file}"
    elif [ "$IPERF_STATUS" -ne 0 ]; then
        echo "!! [${direction}] iperf3 비정상 종료 (exit=${IPERF_STATUS}, 연결 끊김 가능성)" | tee -a "${output_file}"
    fi
}

# ===== 로그 파일에서 receiver 기준 처리량(Mbits/sec) 값만 추출 =====
extract_mbps() {
    local output_file="$1"
    grep -i "receiver" "${output_file}" \
        | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]+Mbits/sec' \
        | awk '{print $1}' \
        | tail -1
}

# ===== ATTEN 값 하나에 대해 감쇠기 설정 + downlink/uplink 측정 수행 =====
# 결과는 command substitution 으로 감싸지 않고 전역 변수(LAST_DOWN/LAST_UP)로
# 넘긴다 -> run_iperf 의 실시간(iperf3 interval) 출력이 그대로 터미널에 표시되어
# 진행 상황을 실시간으로 모니터링할 수 있다.
# LAST_FAILED=1 이면 연결 끊김/timeout/무응답으로 이번 ATTEN 측정에 실패했다는 뜻이다.
LAST_DOWN=""
LAST_UP=""
LAST_FAILED=0

measure_one_atten() {
    local atten="$1"
    local file_prefix="${PREFIX}_atten${atten}"
    local down_status up_status

    echo
    echo "########## [ATTEN = ${atten} dB] 측정 시작 ##########"
    set_atten "$atten"
    sleep "${ATTEN_SETTLE_SEC}"

    run_iperf "downlink" "${file_prefix}"
    down_status="$IPERF_STATUS"

    run_iperf "uplink" "${file_prefix}"
    up_status="$IPERF_STATUS"

    LAST_DOWN="$(extract_mbps "${LOG_DIR}/${file_prefix}_downlink.log")"
    LAST_UP="$(extract_mbps "${LOG_DIR}/${file_prefix}_uplink.log")"

    LAST_FAILED=0

    # exit code 가 0이 아니거나(연결 끊김/timeout), receiver 라인 자체가 없으면
    # (연결은 됐지만 패킷을 못 받은 경우) 실패로 간주하고 N/A 로 기록한다.
    if [ "$down_status" -ne 0 ] || [ -z "$LAST_DOWN" ]; then
        echo "!! [ATTEN = ${atten} dB] downlink 측정 실패 (연결 끊김/timeout)" >&2
        LAST_DOWN="N/A"
        LAST_FAILED=1
    fi
    if [ "$up_status" -ne 0 ] || [ -z "$LAST_UP" ]; then
        echo "!! [ATTEN = ${atten} dB] uplink 측정 실패 (연결 끊김/timeout)" >&2
        LAST_UP="N/A"
        LAST_FAILED=1
    fi

    printf ">>> [ATTEN = %s dB] down = %s Mbits/sec, up = %s Mbits/sec\n" \
        "$atten" "$LAST_DOWN" "$LAST_UP"
}

# ===== 경과 시간 처리 =====
# 스윕이 시작된 시각(main 진입 시 설정). trap 안에서도 참조할 수 있도록 전역 변수로 둔다.
SWEEP_START_TS=0

# 초 단위 정수 -> "HH:MM:SS" 형태로 변환
format_hms() {
    local total_sec="$1"
    printf "%02d:%02d:%02d" $((total_sec / 3600)) $(((total_sec % 3600) / 60)) $((total_sec % 60))
}

# ===== 지금까지의 결과를 정리해서 표로 출력 (정상 종료/중단 공통으로 사용) =====
finalize_report() {
    echo
    echo "===== ATTEN 스윕 결과 정리 (${RESULT_FILE}) ====="
    if [ ! -f "${RESULT_FILE}" ]; then
        echo "(저장된 결과가 없습니다)"
        return
    fi
    if command -v column >/dev/null 2>&1; then
        column -s',' -t "${RESULT_FILE}"
    else
        awk -F',' '{ printf "%-8s %-12s %-12s %-10s\n", $1, $2, $3, $4 }' "${RESULT_FILE}"
    fi

    if [ "$SWEEP_START_TS" -ne 0 ]; then
        local total_elapsed=$(($(date +%s) - SWEEP_START_TS))
        echo "총 경과 시간: $(format_hms "$total_elapsed") (${total_elapsed}초)"
    fi
}

# 사용자가 Ctrl+C 등으로 중단해도 지금까지의 결과를 정리하고 마무리한다.
trap 'echo; echo "!! 사용자 중단 감지 - 지금까지 결과를 정리합니다."; finalize_report; exit 130' INT TERM

# ===== 실행: ATTEN 스윕 =====
main() {
    if [ "$ATTEN_STEP" -eq 0 ]; then
        echo "ATTEN_STEP 값은 0일 수 없습니다." >&2
        exit 1
    fi

    SWEEP_START_TS=$(date +%s)

    local atten_list
    read -r -a atten_list <<< "$(build_atten_list "$ATTEN_START" "$ATTEN_END" "$ATTEN_STEP")"
    local total="${#atten_list[@]}"

    echo "ATTEN,down,up,elapsed" > "${RESULT_FILE}"
    printf "%-8s %-12s %-12s %-10s\n" "ATTEN" "down" "up" "elapsed"

    local idx=0
    local fail_streak=0
    for atten in "${atten_list[@]}"; do
        idx=$((idx + 1))
        local step_elapsed
        step_elapsed="$(format_hms "$(($(date +%s) - SWEEP_START_TS))")"
        echo "----- (${idx}/${total}) ATTEN=${atten} 측정 진행 중 (경과 ${step_elapsed}) -----"

        measure_one_atten "$atten"

        local row_elapsed
        row_elapsed="$(format_hms "$(($(date +%s) - SWEEP_START_TS))")"

        # 결과가 나오는 즉시 CSV 파일에 append (다른 터미널에서 `tail -f` 로도 실시간 확인 가능)
        echo "${atten},${LAST_DOWN},${LAST_UP},${row_elapsed}" >> "${RESULT_FILE}"

        # 지금까지의 결과를 표 형태로 실시간 갱신 출력
        printf "%-8s %-12s %-12s %-10s\n" "$atten" "$LAST_DOWN" "$LAST_UP" "$row_elapsed"

        if [ "$LAST_FAILED" -eq 1 ]; then
            fail_streak=$((fail_streak + 1))
        else
            fail_streak=0
        fi

        # 연결 끊김/timeout 이 연속으로 발생하면(신호가 이미 끊긴 상태) 더 진행해도
        # 의미가 없으므로 스윕을 중단하고 지금까지의 결과를 정리해서 마무리한다.
        if [ "$CONSEC_FAIL_LIMIT" -gt 0 ] && [ "$fail_streak" -ge "$CONSEC_FAIL_LIMIT" ]; then
            echo
            echo "!! ATTEN=${atten} 까지 연결 끊김/timeout 이 ${fail_streak}회 연속 발생하여 스윕을 중단합니다."
            break
        fi
    done

    finalize_report
}

main
