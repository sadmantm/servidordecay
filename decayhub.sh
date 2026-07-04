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
#  reiniciar, status, logs, console ao vivo e monitor de recursos.
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

# ── PID do processo do JOGO (o executável Unity, não o wrapper) ─
# O MainPID do systemd aponta para o decayhub.sh __run; o executável
# real é filho dele. Aqui resolvemos o PID do próprio APP_NAME.
pid_do_servidor() {
    pgrep -f "$APP_NAME" | head -n1
}

# ── Barra de progresso colorida para porcentagens ───────────
barra_pct() {
    # $1 = valor (0-100, pode ter decimal); $2 = largura (default 20)
    local pct=${1%.*}; local largura=${2:-20}
    [[ -z "$pct" ]] && pct=0
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    local cheio=$(( pct * largura / 100 ))
    local vazio=$(( largura - cheio ))
    local cor=$GREEN
    (( pct >= 75 )) && cor=$YELLOW
    (( pct >= 90 )) && cor=$RED
    local b=""
    local i
    for ((i=0; i<cheio; i++)); do b+="█"; done
    for ((i=0; i<vazio; i++)); do b+="░"; done
    echo -e "${cor}${b}${NC}"
}

# ── Linha de resumo curta (usada no topo do menu) ───────────
resumo_recursos() {
    local pid; pid=$(pid_do_servidor)
    if [[ -z "$pid" ]]; then
        echo -e "  ${YELLOW}(sem processo do jogo para medir)${NC}"
        return
    fi
    # %CPU e %MEM do processo via ps; RAM residente em MB
    local cpu mem rss
    read -r cpu mem rss < <(ps -p "$pid" -o %cpu=,%mem=,rss= 2>/dev/null)
    [[ -z "$cpu" ]] && { echo -e "  ${YELLOW}(processo encerrou durante a leitura)${NC}"; return; }
    local rss_mb=$(( ${rss:-0} / 1024 ))
    echo -e "  Jogo: ${BOLD}CPU ${cpu}%${NC}  ·  ${BOLD}RAM ${mem}% (${rss_mb} MB)${NC}  ·  PID ${pid}"
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

# ── 8. Monitor de recursos (CPU / RAM / Disco / Rede) ───────
# Mostra um snapshot do processo do jogo e da máquina.
# Opção de modo "ao vivo" que atualiza a cada 2s.
acao_monitor() {
    echo ""
    echo -e "  Atualizar continuamente (ao vivo) ou só um snapshot?"
    echo -e "    ${GREEN}l${NC}) ao vivo (atualiza a cada 2s, Ctrl+C para sair)"
    echo -e "    ${GREEN}s${NC}) snapshot único"
    read -r -p "  Escolha [s]: " modo
    modo=${modo:-s}

    if [[ "$modo" == "l" || "$modo" == "L" ]]; then
        trap 'echo; return' SIGINT
        while true; do
            clear
            render_monitor
            echo ""
            echo -e "  ${YELLOW}Atualizando a cada 2s — Ctrl+C para voltar ao menu.${NC}"
            sleep 2
        done
        trap - SIGINT
    else
        echo ""
        render_monitor
        pausar
    fi
}

# Desenha o painel de métricas (uma "tela").
render_monitor() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        MONITOR DE RECURSOS · DECAY         ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}$(date '+%F %T')${NC}   ·   Estado: $(status_curto)"
    echo ""

    # ── PROCESSO DO JOGO ─────────────────────────────────────
    echo -e "${BOLD}── Processo do servidor (Unity) ──────────────${NC}"
    local pid; pid=$(pid_do_servidor)
    if [[ -z "$pid" ]]; then
        warn "Nenhum processo '$APP_NAME' em execução."
    else
        local cpu mem rss nlwp etime
        read -r cpu mem rss nlwp etime < <(ps -p "$pid" -o %cpu=,%mem=,rss=,nlwp=,etime= 2>/dev/null)
        if [[ -z "$cpu" ]]; then
            warn "Processo encerrou durante a leitura."
        else
            local rss_mb=$(( ${rss:-0} / 1024 ))
            printf "  PID............: %s\n" "$pid"
            printf "  Uptime.........: %s\n" "${etime// /}"
            printf "  Threads........: %s\n" "$nlwp"
            printf "  CPU............: %5s%%  %b\n" "$cpu" "$(barra_pct "$cpu")"
            printf "  RAM (residente): %s MB (%s%% do total)  %b\n" "$rss_mb" "$mem" "$(barra_pct "$mem")"
        fi
    fi
    echo ""

    # ── MÁQUINA: CPU ─────────────────────────────────────────
    echo -e "${BOLD}── Máquina ───────────────────────────────────${NC}"
    local ncpu; ncpu=$(nproc 2>/dev/null || echo "?")
    local load; load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    printf "  Núcleos........: %s\n" "$ncpu"
    printf "  Load (1/5/15m).: %s\n" "$load"

    # Uso de CPU agregado (amostra de 1s do /proc/stat)
    local cpu_uso
    cpu_uso=$(uso_cpu_total)
    printf "  CPU total......: %5s%%  %b\n" "$cpu_uso" "$(barra_pct "$cpu_uso")"

    # ── MÁQUINA: RAM / SWAP ──────────────────────────────────
    # Lê de /proc/meminfo para não depender do formato do `free`.
    local mem_total mem_avail mem_usado_pct swap_total swap_free swap_usado_pct
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)

    local mem_usado=$(( mem_total - mem_avail ))
    if (( mem_total > 0 )); then
        mem_usado_pct=$(( mem_usado * 100 / mem_total ))
    else
        mem_usado_pct=0
    fi
    printf "  RAM............: %s / %s MB (%s%%)  %b\n" \
        "$(( mem_usado / 1024 ))" "$(( mem_total / 1024 ))" "$mem_usado_pct" \
        "$(barra_pct "$mem_usado_pct")"

    if (( swap_total > 0 )); then
        local swap_usado=$(( swap_total - swap_free ))
        swap_usado_pct=$(( swap_usado * 100 / swap_total ))
        printf "  Swap...........: %s / %s MB (%s%%)  %b\n" \
            "$(( swap_usado / 1024 ))" "$(( swap_total / 1024 ))" "$swap_usado_pct" \
            "$(barra_pct "$swap_usado_pct")"
    else
        printf "  Swap...........: (desativado)\n"
    fi

    # ── MÁQUINA: DISCO ───────────────────────────────────────
    # Uso do disco onde fica o servidor.
    local disco
    disco=$(df -h --output=used,size,pcent "$SERVER_DIR" 2>/dev/null | tail -n1)
    if [[ -n "$disco" ]]; then
        local d_used d_size d_pct
        read -r d_used d_size d_pct <<< "$disco"
        printf "  Disco (%s): %s / %s (%s)  %b\n" \
            "$SERVER_DIR" "$d_used" "$d_size" "$d_pct" "$(barra_pct "${d_pct%\%}")"
    fi

    # Tamanho da pasta de logs (ajuda a flagrar log crescendo demais)
    if [[ -d "$LOG_DIR" ]]; then
        local logsz; logsz=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
        printf "  Pasta de logs..: %s\n" "${logsz:-?}"
    fi

    # ── MÁQUINA: REDE ────────────────────────────────────────
    # Total acumulado RX/TX desde o boot, somando interfaces físicas.
    local rede
    rede=$(rede_total)
    printf "  Rede (acum.)...: %s\n" "$rede"
}

# Uso de CPU total em % a partir de duas amostras do /proc/stat.
uso_cpu_total() {
    local a b idle_a idle_b total_a total_b
    a=($(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat))
    idle_a=${a[3]}
    total_a=0; for v in "${a[@]}"; do total_a=$(( total_a + v )); done
    sleep 1
    b=($(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat))
    idle_b=${b[3]}
    total_b=0; for v in "${b[@]}"; do total_b=$(( total_b + v )); done

    local d_total=$(( total_b - total_a ))
    local d_idle=$(( idle_b - idle_a ))
    if (( d_total > 0 )); then
        echo $(( (d_total - d_idle) * 100 / d_total ))
    else
        echo 0
    fi
}

# Soma RX/TX (em MB/GB) das interfaces, ignorando loopback.
rede_total() {
    local rx_total=0 tx_total=0 iface rx tx
    while read -r iface rx tx; do
        [[ "$iface" == "lo" ]] && continue
        rx_total=$(( rx_total + rx ))
        tx_total=$(( tx_total + tx ))
    done < <(awk -F'[: ]+' 'NR>2 {print $2, $3, $11}' /proc/net/dev)

    # bytes → MB
    local rx_mb=$(( rx_total / 1024 / 1024 ))
    local tx_mb=$(( tx_total / 1024 / 1024 ))
    echo "↓ ${rx_mb} MB  ·  ↑ ${tx_mb} MB"
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
        # Resumo rápido de CPU/RAM do jogo, só quando está rodando.
        if esta_rodando; then
            resumo_recursos
        fi
        echo ""
        echo "  1) Instalar / ajustar permissões"
        echo "  2) Iniciar servidor (segundo plano)"
        echo "  3) Parar servidor"
        echo "  4) Reiniciar servidor"
        echo "  5) Status detalhado"
        echo "  6) Acompanhar logs (ao vivo)"
        echo "  7) Console — enviar comandos"
        echo "  8) Monitor de recursos (CPU/RAM/disco/rede)"
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
            8) acao_monitor ;;
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