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

CONNECT_TIMEOUT=""          # --connect-timeout (밀리초 단위), 값 없으면 미적용 (예: 1000)
FORMAT="m"                  # -f, --format  (k,m,g,t / K,M,G,T)
OMIT="5"                    # -O, --omit N  (시작 N초 통계 제외)

LOG_DIR="./atten_sweep_logs"   # -d 로 지정 가능, 개별 iperf3 로그 저장 디렉터리
PREFIX=""                      # -o 로 지정 가능, 값 없으면 기본 파일명(prefix) 사용

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

# ===== 측정 함수 (iperf_updown.sh 의 run_iperf 와 동일) =====
# $1: 방향 이름 (downlink 또는 uplink), $2: 이번 ATTEN 값이 포함된 파일 prefix
run_iperf() {
    local direction="$1"
    local file_prefix="$2"
    local output_file="${LOG_DIR}/${file_prefix}_${direction}.log"

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

    echo "===== [${direction}] 실행 명령어: iperf3 ${opts} =====" | tee "${output_file}"
    echo "[${direction}] 결과 저장 파일: ${output_file}" | tee -a "${output_file}"

    if [ "$PARALLEL" -gt 1 ]; then
        stdbuf -oL iperf3 ${opts} | grep --line-buffered -E "SUM|ID\]" | tee -a "${output_file}"
    else
        stdbuf -oL iperf3 ${opts} | tee -a "${output_file}"
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
LAST_DOWN=""
LAST_UP=""

measure_one_atten() {
    local atten="$1"
    local file_prefix="${PREFIX}_atten${atten}"

    echo
    echo "########## [ATTEN = ${atten} dB] 측정 시작 ##########"
    set_atten "$atten"
    sleep "${ATTEN_SETTLE_SEC}"

    run_iperf "downlink" "${file_prefix}"
    run_iperf "uplink" "${file_prefix}"

    LAST_DOWN="$(extract_mbps "${LOG_DIR}/${file_prefix}_downlink.log")"
    LAST_UP="$(extract_mbps "${LOG_DIR}/${file_prefix}_uplink.log")"

    [ -z "$LAST_DOWN" ] && LAST_DOWN="0"
    [ -z "$LAST_UP" ] && LAST_UP="0"

    printf ">>> [ATTEN = %s dB] down = %s Mbits/sec, up = %s Mbits/sec\n" \
        "$atten" "$LAST_DOWN" "$LAST_UP"
}

# ===== 실행: ATTEN 스윕 =====
main() {
    if [ "$ATTEN_STEP" -eq 0 ]; then
        echo "ATTEN_STEP 값은 0일 수 없습니다." >&2
        exit 1
    fi

    local atten_list
    read -r -a atten_list <<< "$(build_atten_list "$ATTEN_START" "$ATTEN_END" "$ATTEN_STEP")"
    local total="${#atten_list[@]}"

    echo "ATTEN,down,up" > "${RESULT_FILE}"
    printf "%-8s %-12s %-12s\n" "ATTEN" "down" "up"

    local idx=0
    for atten in "${atten_list[@]}"; do
        idx=$((idx + 1))
        echo "----- (${idx}/${total}) ATTEN=${atten} 측정 진행 중 -----"

        measure_one_atten "$atten"

        # 결과가 나오는 즉시 CSV 파일에 append (다른 터미널에서 `tail -f` 로도 실시간 확인 가능)
        echo "${atten},${LAST_DOWN},${LAST_UP}" >> "${RESULT_FILE}"

        # 지금까지의 결과를 표 형태로 실시간 갱신 출력
        printf "%-8s %-12s %-12s\n" "$atten" "$LAST_DOWN" "$LAST_UP"
    done

    echo
    echo "===== ATTEN 스윕 최종 결과 (${RESULT_FILE}) ====="
    if command -v column >/dev/null 2>&1; then
        column -s',' -t "${RESULT_FILE}"
    else
        awk -F',' '{ printf "%-8s %-12s %-12s\n", $1, $2, $3 }' "${RESULT_FILE}"
    fi
}

main
