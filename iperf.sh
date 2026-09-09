#!/bin/bash

# ===== 변수 설정 =====
SERVER_IP="192.168.1.145"   # 서버 IP 주소
PORT=""                     # 값 없으면 -p 옵션 미적용 (기본 포트 5201 사용)
DURATION=10                 # 테스트 시간(초)
PARALLEL=10                 # 병렬 스트림 개수
PROTOCOL="tcp"               # tcp 또는 udp
BANDWIDTH=""                 # UDP일 때 대역폭 제한 (예: 100M), 비워두면 미적용
REVERSE=false                # true면 -R (서버->클라이언트 방향 테스트), 스크립트 실행 시 -R 옵션으로 켤 수 있음
INTERVAL=1                   # 결과 출력 간격(초)

CONNECT_TIMEOUT=""           # --connect-timeout (밀리초 단위), 값 없으면 미적용 (예: 1000)
FORMAT=""                    # -f, --format  (k,m,g,t / K,M,G,T), 값 없으면 미적용 (예: m)
OMIT=""                      # -O, --omit N  (시작 N초 통계 제외), 값 없으면 미적용 (예: 3)

# ===== 스크립트 실행 인자 처리 =====
# 사용법: ./iperf.sh [-R]   (-R 을 주면 REVERSE=true)
while getopts "R" opt; do
    case "$opt" in
        R) REVERSE=true ;;
        *) echo "사용법: $0 [-R]" >&2; exit 1 ;;
    esac
done

# ===== 옵션 조립 =====
OPTS="-c ${SERVER_IP} -t ${DURATION} -P ${PARALLEL} -i ${INTERVAL}"

if [ -n "$PORT" ]; then
    OPTS="${OPTS} -p ${PORT}"
fi

if [ "$PROTOCOL" = "udp" ]; then
    OPTS="${OPTS} -u"
    if [ -n "$BANDWIDTH" ]; then
        OPTS="${OPTS} -b ${BANDWIDTH}"
    fi
fi

if [ "$REVERSE" = true ]; then
    OPTS="${OPTS} -R"
fi

if [ -n "$CONNECT_TIMEOUT" ]; then
    OPTS="${OPTS} --connect-timeout ${CONNECT_TIMEOUT}"
fi

if [ -n "$FORMAT" ]; then
    OPTS="${OPTS} -f ${FORMAT}"
fi

if [ -n "$OMIT" ]; then
    OPTS="${OPTS} -O ${OMIT}"
fi

# ===== 실행 =====
echo "실행 명령어: iperf3 ${OPTS}"

if [ "$PARALLEL" -gt 1 ]; then
    # 병렬 스트림 1개 초과 -> SUM 라인만 출력 (헤더 라인도 함께 표시)
    stdbuf -oL iperf3 ${OPTS} | grep --line-buffered -E "SUM|ID\]"
else
    # 병렬 스트림 1개 -> 전체 로그 출력
    iperf3 ${OPTS}
fi
