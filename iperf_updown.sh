#!/bin/bash
# iperf.sh 에서 파생: downlink(-R 없음) / uplink(-R 있음)를 한 번에 측정하고 로그로 저장

# ===== 변수 설정 =====
SERVER_IP="192.168.1.145"   # 서버 IP 주소
PORT=""                     # 값 없으면 -p 옵션 미적용 (기본 포트 5201 사용)
DURATION=10                 # 테스트 시간(초)
PARALLEL=10                 # 병렬 스트림 개수
PROTOCOL="tcp"               # tcp 또는 udp
BANDWIDTH=""                 # UDP일 때 대역폭 제한 (예: 100M), 비워두면 미적용
INTERVAL=1                   # 결과 출력 간격(초)

CONNECT_TIMEOUT=""           # --connect-timeout (밀리초 단위), 값 없으면 미적용 (예: 1000)
FORMAT="m"                   # -f, --format  (k,m,g,t / K,M,G,T), 값 없으면 미적용 (예: m)
OMIT="5"                     # -O, --omit N  (시작 N초 통계 제외), 값 없으면 미적용 (예: 3)

LOG_DIR="."                  # -d 로 지정 가능, 로그 저장 디렉터리
PREFIX=""                    # -o 로 지정 가능, 값 없으면 기본 파일명(prefix) 사용

# ===== 스크립트 실행 인자 처리 =====
# 사용법: ./iperf_updown.sh [-d 로그디렉터리] [-o 파일명prefix]
while getopts "d:o:" opt; do
    case "$opt" in
        d) LOG_DIR="$OPTARG" ;;
        o) PREFIX="$OPTARG" ;;
        *) echo "사용법: $0 [-d 로그디렉터리] [-o 파일명prefix]" >&2; exit 1 ;;
    esac
done

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [ -z "$PREFIX" ]; then
    PREFIX="iperf_result_${TIMESTAMP}"
fi

mkdir -p "${LOG_DIR}"

# ===== 측정 함수 =====
# $1: 방향 이름 (downlink 또는 uplink) - downlink 는 -R 미적용, uplink 는 -R 적용
run_iperf() {
    local direction="$1"
    local output_file="${LOG_DIR}/${PREFIX}_${direction}.log"

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
        # 병렬 스트림 1개 초과 -> SUM 라인만 출력 (헤더 라인도 함께 표시)
        stdbuf -oL iperf3 ${opts} | grep --line-buffered -E "SUM|ID\]" | tee -a "${output_file}"
    else
        # 병렬 스트림 1개 -> 전체 로그 출력
        stdbuf -oL iperf3 ${opts} | tee -a "${output_file}"
    fi
}

# ===== 실행: downlink -> uplink 순서로 한 번에 측정 =====
run_iperf "downlink"
run_iperf "uplink"
