#!/bin/bash
# ============================================================
#  Servidor Dedicado – Decay
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="decay.x86_64"
APP="$DIR/$APP_NAME"
LOG_DIR="$DIR/logs"
PID_FILE="$DIR/server.pid"
MAX_LOGS=14          # dias de log retidos
RESTART_DELAY=5      # segundos antes de reiniciar
MAX_CRASHES=10       # crashes consecutivos antes de pausar
CRASH_WINDOW=60      # janela (segundos) para contar crashes consecutivos
PAUSE_ON_CRASH=300   # pausa (segundos) após muitos crashes seguidos

# ── Cores ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# ── Funções utilitárias ──────────────────────────────────────
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}"; }

# ── Pré-checks ───────────────────────────────────────────────
preflight() {
    [[ ! -f "$APP" ]] && { err "Executável não encontrado: $APP"; exit 1; }
    chmod +x "$APP"
    mkdir -p "$LOG_DIR"
}

# ── Limpeza de logs antigos ──────────────────────────────────
rotate_logs() {
    find "$LOG_DIR" -name "server_*.log" -mtime +$MAX_LOGS -delete 2>/dev/null
    local count
    count=$(find "$LOG_DIR" -name "server_*.log" | wc -l)
    log "Logs existentes: $count (retendo últimos $MAX_LOGS dias)"
}

# ── Salvar PID ───────────────────────────────────────────────
save_pid() { echo "$1" > "$PID_FILE"; }
clear_pid() { rm -f "$PID_FILE"; }

# ── Sinal de encerramento limpo ──────────────────────────────
STOP=0
handle_signal() {
    warn "Sinal de parada recebido. Encerrando..."
    STOP=1
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
}
trap handle_signal SIGTERM SIGINT

# ── Loop principal ───────────────────────────────────────────
main() {
    preflight
    rotate_logs

    local crashes=0
    local window_start
    window_start=$(date +%s)

    log "Iniciando loop de supervisão para '$APP_NAME'"

    while [[ $STOP -eq 0 ]]; do
        local LOG_FILE="$LOG_DIR/server_$(date '+%Y-%m-%d_%H-%M-%S').log"

        echo ""
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        log "Iniciando Unity Linux Server"
        log "Log: $LOG_FILE"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"

        # Inicia o servidor e captura o PID
        "$APP" \
            -batchmode \
            -nographics \
            -logFile - \
            2>&1 | tee "$LOG_FILE" &
        local PIPE_PID=$!

        # PID real do servidor (filho do pipe)
        SERVER_PID=$(pgrep -P $PIPE_PID "$APP_NAME" 2>/dev/null || echo $PIPE_PID)
        save_pid "$SERVER_PID"
        log "PID do servidor: $SERVER_PID"

        wait $PIPE_PID
        local EXIT_CODE=$?
        clear_pid

        [[ $STOP -eq 1 ]] && { ok "Encerramento solicitado. Saindo."; break; }

        # ── Contagem de crashes ──────────────────────────────
        local now
        now=$(date +%s)
        local elapsed=$(( now - window_start ))

        if (( elapsed <= CRASH_WINDOW )); then
            (( crashes++ ))
        else
            crashes=1
            window_start=$now
        fi

        warn "Servidor encerrou (exit $EXIT_CODE). Crash #$crashes na janela de ${CRASH_WINDOW}s."

        if (( crashes >= MAX_CRASHES )); then
            err "Muitos crashes consecutivos ($crashes). Pausando ${PAUSE_ON_CRASH}s antes de tentar novamente..."
            crashes=0
            window_start=$(date +%s)
            sleep $PAUSE_ON_CRASH
        else
            log "Reiniciando em ${RESTART_DELAY}s..."
            sleep $RESTART_DELAY
        fi
    done
}

main
