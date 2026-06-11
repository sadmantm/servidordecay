#!/bin/bash
# ============================================================
#  decayhub.sh — Painel único do Servidor Dedicado Decay
#
#  MODOS:
#    ./decayhub.sh            → abre o menu interativo (painel)
#    ./decayhub.sh __run      → modo LANÇADOR (uso interno do systemd)
#
#  O servidor roda sob systemd (24/7, boot, restart em crash).
#  Este hub é o painel de controle: instalar, iniciar, parar,
#  reiniciar, status, logs e console ao vivo (enviar comandos).
# ============================================================

set -u

# ── Configuração ────────────────────────────────────────────
SERVER_DIR="/home/ubuntu/servidordecay"
USER_OWNER="ubuntu"
GROUP_OWNER="ubuntu"
APP_NAME="decay.x86_64"
SERVICE_NAME="decay-server"

APP="$SERVER_DIR/$APP_NAME"
LOG_DIR="$SERVER_DIR/logs"
IN_FIFO="$SERVER_DIR/.server_in.fifo"
SELF="$SERVER_DIR/$(basename "$0")"
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME.service"
MAX_LOGS=14

# ── Cores ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "${RED}✘ $*${NC}"; }

# ============================================================
#  MODO LANÇADOR  (chamado pelo systemd: decayhub.sh __run)
#  Sobe UMA execução do servidor em primeiro plano.
#  O systemd reinicia quando cair.
# ============================================================
run_launcher() {
    [[ ! -f "$APP" ]] && { echo "Executável não encontrado: $APP" >&2; exit 1; }
    chmod +x "$APP" 2>/dev/null
    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -name "server_*.log" -mtime +$MAX_LOGS -delete 2>/dev/null

    local LOG_FILE="$LOG_DIR/server_$(date '+%Y-%m-%d_%H-%M-%S').log"

    # FIFO de entrada (stdin do servidor = comandos do console)
    rm -f "$IN_FIFO"
    mkfifo "$IN_FIFO"
    chmod 660 "$IN_FIFO"

    # Mantém a ponta de escrita aberta para o stdin não receber EOF.
    sleep infinity > "$IN_FIFO" &
    local HOLDER_PID=$!

    local SERVER_PID=""
    cleanup_run() {
        [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
        kill "$HOLDER_PID" 2>/dev/null
        rm -f "$IN_FIFO"
    }
    trap cleanup_run SIGTERM SIGINT EXIT

    echo "══════════════════════════════════════════"
    echo "[$(date '+%F %T')] Iniciando Decay Server"
    echo "Log: $LOG_FILE"
    echo "══════════════════════════════════════════"

    "$APP" -batchmode -nographics -logFile - \
        < "$IN_FIFO" \
        2>&1 | tee "$LOG_FILE" &

    SERVER_PID=$(jobs -p %1 2>/dev/null)
    [[ -z "$SERVER_PID" ]] && SERVER_PID=$(pgrep -f "$APP_NAME" | head -n1)
    echo "[$(date '+%F %T')] PID do servidor: $SERVER_PID"

    wait
    local EXIT_CODE=$?
    echo "[$(date '+%F %T')] Servidor encerrou (exit $EXIT_CODE)."
    exit $EXIT_CODE
}

# ============================================================
#  HELPERS DO PAINEL
# ============================================================

# True se o serviço está ativo (rodando).
esta_rodando() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

precisa_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "sudo"
    fi
}

status_curto() {
    if esta_rodando; then
        local pid
        pid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
        echo -e "${GREEN}● RODANDO${NC} (PID ${pid})"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${YELLOW}○ PARADO${NC} (habilitado no boot)"
    elif [[ -f "$UNIT_PATH" ]]; then
        echo -e "${YELLOW}○ PARADO${NC}"
    else
        echo -e "${RED}✘ NÃO INSTALADO${NC}"
    fi
}

# ── 1. Instalar / ajustar permissões + serviço ──────────────
acao_instalar() {
    local SUDO; SUDO=$(precisa_sudo)

    log "Ajustando dono para $USER_OWNER:$GROUP_OWNER..."
    $SUDO chown -R "$USER_OWNER:$GROUP_OWNER" "$SERVER_DIR"

    log "Tornando executáveis..."
    chmod +x "$APP" 2>/dev/null || $SUDO chmod +x "$APP"
    chmod +x "$SELF" 2>/dev/null || $SUDO chmod +x "$SELF"

    log "Garantindo pasta de logs..."
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"

    log "Instalando unit do systemd..."
    # Gera a unit apontando para este próprio arquivo em modo __run.
    $SUDO tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Decay Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_OWNER
Group=$GROUP_OWNER
WorkingDirectory=$SERVER_DIR
ExecStart=$SELF __run
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=10
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log "Recarregando systemd e habilitando no boot..."
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SERVICE_NAME"

    ok "Instalação/permissões concluídas."
    pausar
}

# ── 2. Iniciar ──────────────────────────────────────────────
acao_iniciar() {
    if esta_rodando; then
        warn "O servidor já está rodando."
    else
        local SUDO; SUDO=$(precisa_sudo)
        log "Iniciando servidor (segundo plano)..."
        $SUDO systemctl start "$SERVICE_NAME"
        sleep 1
        esta_rodando && ok "Servidor iniciado." || err "Falhou ao iniciar. Veja os logs."
    fi
    pausar
}

# ── 3. Parar ────────────────────────────────────────────────
acao_parar() {
    if ! esta_rodando; then
        warn "O servidor não está rodando."
    else
        local SUDO; SUDO=$(precisa_sudo)
        log "Parando servidor..."
        $SUDO systemctl stop "$SERVICE_NAME"
        sleep 1
        esta_rodando && err "Ainda rodando?" || ok "Servidor parado."
    fi
    pausar
}

# ── 4. Reiniciar ────────────────────────────────────────────
acao_reiniciar() {
    local SUDO; SUDO=$(precisa_sudo)
    log "Reiniciando servidor..."
    $SUDO systemctl restart "$SERVICE_NAME"
    sleep 1
    esta_rodando && ok "Servidor reiniciado." || err "Falhou. Veja os logs."
    pausar
}

# ── 5. Status detalhado ─────────────────────────────────────
acao_status() {
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || warn "Serviço não instalado."
    pausar
}

# ── 6. Acompanhar logs ──────────────────────────────────────
acao_logs() {
    echo ""
    log "Logs ao vivo (Ctrl+C para voltar ao menu)."
    echo ""
    # Ctrl+C aqui só interrompe o journalctl, não o hub.
    trap ' ' SIGINT
    journalctl -u "$SERVICE_NAME" -f --no-pager
    trap - SIGINT
}

# ── 7. Console ao vivo (enviar comandos) ────────────────────
acao_console() {
    if ! esta_rodando; then
        warn "O servidor não está rodando — inicie-o antes de usar o console."
        pausar
        return
    fi
    if [[ ! -p "$IN_FIFO" ]]; then
        err "FIFO de comandos não encontrado ($IN_FIFO)."
        warn "Se o servidor acabou de subir, aguarde 1-2s e tente de novo."
        pausar
        return
    fi

    echo ""
    echo -e "${BOLD}Console do servidor${NC} — digite comandos e ENTER."
    echo -e "Ex.: ${GREEN}adminset Joao true${NC}, ${GREEN}players${NC}"
    echo -e "Digite ${YELLOW}sair${NC} (ou Ctrl+C) para voltar ao menu."
    echo -e "Dica: abra os logs em outro terminal para ver a resposta."
    echo ""

    trap 'echo; return' SIGINT
    while true; do
        read -r -p "decay> " linha || break
        [[ "$linha" == "sair" || "$linha" == "exit" ]] && break
        [[ -z "$linha" ]] && continue
        echo "$linha" > "$IN_FIFO"
        echo -e "${CYAN}→ enviado:${NC} $linha"
    done
    trap - SIGINT
}

pausar() {
    echo ""
    read -r -p "Pressione ENTER para continuar..."
}

# ============================================================
#  MENU
# ============================================================
menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║          DECAY · PAINEL DO SERVIDOR        ║${NC}"
        echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo -e "  Estado: $(status_curto)"
        echo ""
        echo "  1) Instalar / ajustar permissões"
        echo "  2) Iniciar servidor (segundo plano)"
        echo "  3) Parar servidor"
        echo "  4) Reiniciar servidor"
        echo "  5) Status detalhado"
        echo "  6) Acompanhar logs (ao vivo)"
        echo "  7) Console — enviar comandos"
        echo "  0) Sair do painel (servidor continua rodando)"
        echo ""
        read -r -p "  Escolha: " opt

        case "$opt" in
            1) acao_instalar ;;
            2) acao_iniciar ;;
            3) acao_parar ;;
            4) acao_reiniciar ;;
            5) acao_status ;;
            6) acao_logs ;;
            7) acao_console ;;
            0) echo "Saindo. O servidor continua rodando em segundo plano."; exit 0 ;;
            *) warn "Opção inválida."; sleep 1 ;;
        esac
    done
}

# ============================================================
#  ENTRADA
# ============================================================
case "${1:-}" in
    __run)  run_launcher ;;   # uso interno do systemd
    *)      menu ;;           # painel interativo
esac
