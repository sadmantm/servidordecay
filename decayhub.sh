#!/bin/bash
# ============================================================
#  decayhub.sh — Painel único do Servidor Dedicado Decay
#
#  MODOS:
#    ./decayhub.sh            → menu interativo (painel)
#    ./decayhub.sh __run      → LANÇADOR (uso interno do systemd)
#    ./decayhub.sh __prompt   → prompt de comandos (uso interno do tmux)
# ============================================================

set -u

# ── Configuração autodetectada ──────────────────────────────
SERVER_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
USER_OWNER="$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || id -un)"
GROUP_OWNER="$(stat -c '%G' "$SERVER_DIR" 2>/dev/null || id -gn)"

APP_NAME="decay.x86_64"
SERVICE_NAME="decay-server"

APP="$SERVER_DIR/$APP_NAME"
LOG_DIR="$SERVER_DIR/logs"
BACKUP_DIR="$SERVER_DIR/backups"
CURRENT_LOG="$LOG_DIR/current.log"
IN_FIFO="$SERVER_DIR/.server_in.fifo"
SELF="$(readlink -f "$0")"
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME.service"
SYSCTL_PATH="/etc/sysctl.d/99-decay.conf"
TMUX_SESSION="decay_console"

LOG_RETENTION_DAYS=14
BACKUP_RETENTION=20

# Pastas de save geradas pelo jogo (irmãs de <app>_Data).
SAVE_DIRS=("WorldSaves" "PlayerSaves")

# Timeouts de encerramento. O do wrapper precisa ser MENOR que o do
# systemd, senão o systemd mata antes de o wrapper terminar de esperar.
STOP_WAIT_WRAPPER=120
STOP_WAIT_SYSTEMD=150

SWAP_FILE="/swapfile_decay"
SWAP_SIZE_MB=4096

# ── Cores ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "${RED}✘ $*${NC}"; }

# ============================================================
#  MODO LANÇADOR (systemd: decayhub.sh __run)
# ============================================================
run_launcher() {
    [[ ! -f "$APP" ]] && { echo "Executável não encontrado: $APP" >&2; exit 1; }
    chmod +x "$APP" 2>/dev/null

    mkdir -p "$LOG_DIR"
    find "$LOG_DIR" -name "server_*.log" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null

    local LOG_FILE="$LOG_DIR/server_$(date '+%Y-%m-%d_%H-%M-%S').log"

    # Link estável para o log da sessão atual — é o alvo do 'tail -F'.
    ln -sfn "$LOG_FILE" "$CURRENT_LOG"

    # ── FIFO de comandos ────────────────────────────────────
    # exec 3<> abre a FIFO em LEITURA-ESCRITA num descritor do próprio
    # bash: não bloqueia e mantém o stdin do servidor sem EOF.
    #
    # ⚠️ A versão anterior usava 'sleep infinity > fifo &' como holder. Esse
    # processo era filho do bash, e o 'wait' SEM ARGUMENTO espera TODOS os
    # filhos — então quando o Unity caía por conta própria, o bash ficava
    # preso no wait para sempre, o systemd via o processo principal vivo e
    # NUNCA reiniciava. O Restart=always era letra morta.
    rm -f "$IN_FIFO"
    if ! mkfifo -m 660 "$IN_FIFO"; then
        echo "Falha ao criar FIFO em $IN_FIFO" >&2
        exit 1
    fi
    exec 3<>"$IN_FIFO"

    local SERVER_PID=""
    local ENCERRANDO=0

    # ── Encerramento gracioso ───────────────────────────────
    # Repassa SIGTERM ao Unity e ESPERA o processo sair de verdade. Sem
    # isso o bash saía na hora e o save de encerramento (players +
    # sleeping bodies + world save síncrono) era cortado no meio.
    encerrar() {
        [[ "$ENCERRANDO" == "1" ]] && return
        ENCERRANDO=1

        if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "[$(date '+%F %T')] SIGTERM -> Unity (PID $SERVER_PID). " \
                 "Aguardando até ${STOP_WAIT_WRAPPER}s pelo save final..."
            kill -TERM "$SERVER_PID" 2>/dev/null

            local i=0
            while kill -0 "$SERVER_PID" 2>/dev/null && (( i < STOP_WAIT_WRAPPER )); do
                sleep 1
                i=$((i + 1))
            done

            if kill -0 "$SERVER_PID" 2>/dev/null; then
                echo "[$(date '+%F %T')] Unity NÃO saiu em ${STOP_WAIT_WRAPPER}s." \
                     "SIGKILL — o save final provavelmente foi perdido."
                kill -KILL "$SERVER_PID" 2>/dev/null
            else
                echo "[$(date '+%F %T')] Unity encerrou após ${i}s."
            fi
        fi

        exec 3>&- 2>/dev/null
        rm -f "$IN_FIFO"
    }
    trap encerrar SIGTERM SIGINT
    trap encerrar EXIT

    echo "══════════════════════════════════════════"
    echo "[$(date '+%F %T')] Iniciando Decay Server"
    echo "Log: $LOG_FILE"
    echo "══════════════════════════════════════════"

    # ⚠️ SEM pipeline e SEM tee: '-logFile <path>' faz o próprio Unity
    # escrever no arquivo. Antes, '-logFile -' + 'tee' gravava cada linha
    # DUAS vezes no disco (arquivo + journald), e o pipeline tornava a
    # detecção de PID frágil ('jobs -p %1') e o exit code inútil (era o
    # do tee, não o do jogo).
    "$APP" -batchmode -nographics -logFile "$LOG_FILE" <&3 &
    SERVER_PID=$!

    echo "[$(date '+%F %T')] PID do servidor: $SERVER_PID"

    # wait COM argumento: retorna o exit code real do Unity.
    wait "$SERVER_PID"
    local EXIT_CODE=$?
    SERVER_PID=""

    echo "[$(date '+%F %T')] Servidor encerrou (exit $EXIT_CODE)."
    exit $EXIT_CODE
}

# ============================================================
#  HELPERS
# ============================================================
esta_rodando() { systemctl is-active --quiet "$SERVICE_NAME"; }

precisa_sudo() { [[ $EUID -ne 0 ]] && echo "sudo"; }

status_curto() {
    if esta_rodando; then
        echo -e "${GREEN}● RODANDO${NC}"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${YELLOW}○ PARADO${NC} (habilitado no boot)"
    elif [[ -f "$UNIT_PATH" ]]; then
        echo -e "${YELLOW}○ PARADO${NC}"
    else
        echo -e "${RED}✘ NÃO INSTALADO${NC}"
    fi
}

# PID do processo do JOGO. Prefere descer a partir do MainPID do systemd
# em vez de um pgrep solto pela linha de comando.
pid_do_servidor() {
    local main filho
    main=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
    if [[ -n "$main" && "$main" != "0" ]]; then
        filho=$(pgrep -P "$main" 2>/dev/null | head -n1)
        [[ -n "$filho" ]] && { echo "$filho"; return; }
    fi
    pgrep -f "$APP" 2>/dev/null | head -n1
}

barra_pct() {
    local pct=${1%.*}; local largura=${2:-20}
    [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && pct=0
    (( pct > 100 )) && pct=100
    local cheio=$(( pct * largura / 100 ))
    local cor=$GREEN
    (( pct >= 75 )) && cor=$YELLOW
    (( pct >= 90 )) && cor=$RED
    local b="" i
    for ((i=0; i<cheio; i++)); do b+="█"; done
    for ((i=cheio; i<largura; i++)); do b+="░"; done
    echo -e "${cor}${b}${NC}"
}

resumo_recursos() {
    local pid; pid=$(pid_do_servidor)
    [[ -z "$pid" ]] && { echo -e "  ${YELLOW}(sem processo do jogo)${NC}"; return; }
    local cpu mem rss
    read -r cpu mem rss < <(ps -p "$pid" -o %cpu=,%mem=,rss= 2>/dev/null)
    [[ -z "${cpu:-}" ]] && { echo -e "  ${YELLOW}(processo saiu na leitura)${NC}"; return; }
    echo -e "  Jogo: ${BOLD}CPU ${cpu}%${NC} · ${BOLD}RAM $(( ${rss:-0} / 1024 )) MB (${mem}%)${NC} · PID ${pid}"
}

pausar() { echo ""; read -r -p "Pressione ENTER para continuar..."; }

contar() {
    local padrao="$1" arquivo="$2"
    [[ -f "$arquivo" || -L "$arquivo" ]] || { echo 0; return; }
    grep -Fc -- "$padrao" "$arquivo" 2>/dev/null | head -n1
}

# ============================================================
#  1. INSTALAR / ATUALIZAR
# ============================================================
config_swap() {
    local SUDO; SUDO=$(precisa_sudo)

    if swapon --show 2>/dev/null | grep -q .; then
        ok "Swap já ativo — mantendo."
        return 0
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        warn "Swapfile existe mas está inativo. Reativando..."
        $SUDO chmod 600 "$SWAP_FILE"
        $SUDO swapon "$SWAP_FILE" 2>/dev/null && { ok "Swap reativado."; return 0; }
        $SUDO swapoff "$SWAP_FILE" 2>/dev/null
        $SUDO rm -f "$SWAP_FILE"
    fi

    local livre
    livre=$(df --output=avail -m "$(dirname "$SWAP_FILE")" 2>/dev/null | tail -n1 | tr -d ' ')
    if [[ -z "$livre" ]] || (( livre < SWAP_SIZE_MB + 1024 )); then
        err "Espaço insuficiente para swap de ${SWAP_SIZE_MB}MB (livre: ${livre:-?}MB)."
        return 1
    fi

    log "Criando swap de ${SWAP_SIZE_MB}MB..."
    $SUDO fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null \
        || $SUDO dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress

    $SUDO chmod 600 "$SWAP_FILE"
    $SUDO mkswap "$SWAP_FILE" >/dev/null || { err "mkswap falhou."; return 1; }
    $SUDO swapon "$SWAP_FILE" || { err "swapon falhou."; return 1; }

    grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null \
        || echo "$SWAP_FILE none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null

    ok "Swap de ${SWAP_SIZE_MB}MB ativo."
}

config_sysctl() {
    local SUDO; SUDO=$(precisa_sudo)

    log "Aplicando parâmetros de kernel..."
    $SUDO tee "$SYSCTL_PATH" >/dev/null <<'EOF'
# Buffers de socket. Sem isto o kernel CORTA silenciosamente os 7MB
# configurados no KcpTransport + "Maximize Socket Buffers", e o servidor
# roda com ~200KB em vez do que o Inspector mostra.
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=262144
net.core.wmem_default=262144

# Prefere estrangular a matar por OOM. O GC Boehm (IL2CPP) quase não
# devolve memória ao SO, então um pico transiente vira RSS permanente.
vm.swappiness=10
EOF
    $SUDO sysctl --system >/dev/null 2>&1
    ok "sysctl aplicado ($SYSCTL_PATH)."
}

acao_instalar() {
    local SUDO; SUDO=$(precisa_sudo)
    local estava_rodando=0
    esta_rodando && estava_rodando=1

    log "Diretório: $SERVER_DIR"
    log "Dono/grupo: $USER_OWNER:$GROUP_OWNER"

    $SUDO chown -R "$USER_OWNER:$GROUP_OWNER" "$SERVER_DIR"
    chmod +x "$APP" 2>/dev/null || $SUDO chmod +x "$APP"
    chmod +x "$SELF" 2>/dev/null || $SUDO chmod +x "$SELF"

    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    chmod 755 "$LOG_DIR" "$BACKUP_DIR"

    config_swap
    config_sysctl

    log "Instalando unit do systemd..."
    $SUDO tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=Decay Dedicated Server
After=network-online.target
Wants=network-online.target

# ⚠️ StartLimit* pertence a [Unit], NÃO a [Service]. Na seção errada o
# systemd IGNORA as duas, e um bug de startup viraria crash loop
# reiniciando a cada 5s indefinidamente.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$USER_OWNER
Group=$GROUP_OWNER
WorkingDirectory=$SERVER_DIR
ExecStart=$SELF __run

Restart=always
RestartSec=10

# 'mixed' só é seguro porque o wrapper agora repassa o SIGTERM ao Unity
# e ESPERA o processo sair. TimeoutStopSec > o do wrapper, senão o
# systemd mata no meio da espera.
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=$STOP_WAIT_SYSTEMD

# MemoryHigh ESTRANGULA e pressiona o GC. MemoryMax mataria sem save —
# de propósito ausente.
MemoryAccounting=yes
MemoryHigh=2500M
OOMScoreAdjust=-500

LimitNOFILE=65535

# O Unity escreve o log direto no arquivo (-logFile). O journald recebe
# só as linhas do wrapper, então 'systemctl status' fica legível e o
# disco não leva a mesma linha duas vezes.
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

    ok "Instalação concluída."

    if (( estava_rodando )); then
        warn "O serviço está rodando com a unit ANTIGA."
        read -r -p "  Reiniciar agora para aplicar? [s/N]: " r
        [[ "${r,,}" == "s" ]] && { $SUDO systemctl restart "$SERVICE_NAME"; ok "Reiniciado."; }
    fi
    pausar
}

# ============================================================
#  2-4. CONTROLE
# ============================================================
acao_iniciar() {
    if esta_rodando; then
        warn "Já está rodando."
    else
        local SUDO; SUDO=$(precisa_sudo)
        $SUDO systemctl start "$SERVICE_NAME"
        sleep 2
        esta_rodando && ok "Servidor iniciado." || err "Falhou — veja o diagnóstico (8)."
    fi
    pausar
}

acao_parar() {
    if ! esta_rodando; then
        warn "Não está rodando."
        pausar; return
    fi
    local SUDO; SUDO=$(precisa_sudo)
    log "Parando... o save de encerramento pode levar até ${STOP_WAIT_WRAPPER}s. NÃO interrompa."
    $SUDO systemctl stop "$SERVICE_NAME"
    esta_rodando && err "Ainda rodando?" || ok "Servidor parado."

    if grep -qF "SERVIDOR ENCERRADO CORRETAMENTE" "$CURRENT_LOG" 2>/dev/null; then
        ok "Save de encerramento confirmado no log."
    else
        warn "NÃO encontrei 'SERVIDOR ENCERRADO CORRETAMENTE' no log."
        warn "O save final pode não ter rodado — confira o diagnóstico (8)."
    fi
    pausar
}

acao_reiniciar() {
    local SUDO; SUDO=$(precisa_sudo)
    if esta_rodando; then
        warn "Jogadores conectados serão desconectados."
        read -r -p "  Confirmar reinício? [s/N]: " r
        [[ "${r,,}" != "s" ]] && { log "Cancelado."; pausar; return; }
    fi
    log "Reiniciando (aguardando o save final)..."
    $SUDO systemctl restart "$SERVICE_NAME"
    sleep 2
    esta_rodando && ok "Reiniciado." || err "Falhou — veja o diagnóstico (8)."
    pausar
}

# ============================================================
#  5. CONSOLE + LOGS
# ============================================================
enviar_comando() {
    local linha="$1"
    [[ -z "$linha" ]] && return 1
    [[ -p "$IN_FIFO" ]] || return 2
    # timeout: sem leitor na outra ponta, a escrita bloquearia o painel.
    timeout 2 bash -c "echo \"\$1\" > \"\$2\"" _ "$linha" "$IN_FIFO" || return 3
    return 0
}

run_prompt() {
    echo -e "${BOLD}Console do servidor Decay${NC}"
    echo -e "Ex.: ${GREEN}adminset Joao true${NC} · ${GREEN}players${NC}"
    echo -e "Sair do painel: ${YELLOW}Ctrl+B${NC} depois ${YELLOW}D${NC} (servidor segue rodando)."
    echo ""
    while true; do
        read -r -p "decay> " linha || break
        [[ -z "$linha" ]] && continue
        if [[ "$linha" == "sair" || "$linha" == "exit" ]]; then
            echo "Use Ctrl+B depois D para fechar o painel."
            continue
        fi
        enviar_comando "$linha"
        case $? in
            0) echo -e "${CYAN}→ enviado:${NC} $linha" ;;
            2) err "FIFO ausente — o servidor está rodando?" ;;
            3) err "Escrita na FIFO expirou — servidor travado ou sem leitor." ;;
        esac
    done
}

# Fallback sem tmux: só envia comandos (logs ficam por conta do arquivo).
console_simples() {
    warn "tmux ausente — modo somente-comandos."
    echo -e "Para ver os logs, abra outro terminal: ${GREEN}tail -F $CURRENT_LOG${NC}"
    echo ""
    trap 'echo; return' SIGINT
    while true; do
        read -r -p "decay> " linha || break
        [[ "$linha" == "sair" || "$linha" == "exit" ]] && break
        [[ -z "$linha" ]] && continue
        enviar_comando "$linha" && echo -e "${CYAN}→ enviado:${NC} $linha" || err "Falha no envio."
    done
    trap - SIGINT
}

acao_console() {
    if ! esta_rodando; then
        warn "Inicie o servidor antes."
        pausar; return
    fi
    if [[ ! -p "$IN_FIFO" ]]; then
        err "FIFO não encontrada ($IN_FIFO). Aguarde 1-2s após o start."
        pausar; return
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        console_simples
        pausar; return
    fi

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux attach -t "$TMUX_SESSION"
        return
    fi

    log "Abrindo console + logs. Ctrl+B depois D para desanexar."
    sleep 1

    # 'tail -F' segue o symlink current.log e sobrevive à rotação de log
    # num restart do servidor. O journalctl não serve mais aqui: o Unity
    # escreve direto no arquivo, não no journald.
    tmux new-session -d -s "$TMUX_SESSION" -n decay \
        "tail -n 200 -F '$CURRENT_LOG'"
    tmux split-window -v -t "$TMUX_SESSION" "'$SELF' __prompt"
    tmux resize-pane -t "$TMUX_SESSION".0 -y 70%
    tmux select-pane -t "$TMUX_SESSION".1
    tmux attach -t "$TMUX_SESSION"
}

# ============================================================
#  6. STATUS & MONITOR
# ============================================================
uso_cpu_total() {
    local a b idle_a idle_b total_a total_b v
    read -ra a < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
    idle_a=${a[3]}; total_a=0
    for v in "${a[@]}"; do total_a=$(( total_a + v )); done
    sleep 1
    read -ra b < <(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
    idle_b=${b[3]}; total_b=0
    for v in "${b[@]}"; do total_b=$(( total_b + v )); done
    local dt=$(( total_b - total_a )) di=$(( idle_b - idle_a ))
    (( dt > 0 )) && echo $(( (dt - di) * 100 / dt )) || echo 0
}

# Taxa de rede em KB/s (a acumulada desde o boot não dizia nada útil).
rede_taxa() {
    local r1 t1 r2 t2
    read -r r1 t1 < <(awk -F'[: ]+' 'NR>2 && $2!="lo" {r+=$3; t+=$11} END{print r, t}' /proc/net/dev)
    sleep 1
    read -r r2 t2 < <(awk -F'[: ]+' 'NR>2 && $2!="lo" {r+=$3; t+=$11} END{print r, t}' /proc/net/dev)
    echo "↓ $(( (r2 - r1) / 1024 )) KB/s · ↑ $(( (t2 - t1) / 1024 )) KB/s"
}

render_monitor() {
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       STATUS & MONITOR · DECAY              ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo -e "  ${CYAN}$(date '+%F %T')${NC}  ·  $(status_curto)"
    echo ""

    echo -e "${BOLD}── Processo do jogo ─────────────────────────${NC}"
    local pid; pid=$(pid_do_servidor)
    if [[ -z "$pid" ]]; then
        warn "Nenhum processo do jogo em execução."
    else
        local cpu mem rss nlwp etime
        read -r cpu mem rss nlwp etime < <(ps -p "$pid" -o %cpu=,%mem=,rss=,nlwp=,etime= 2>/dev/null)
        if [[ -z "${cpu:-}" ]]; then
            warn "Processo saiu durante a leitura."
        else
            printf "  PID............: %s\n" "$pid"
            printf "  Uptime.........: %s\n" "${etime// /}"
            printf "  Threads........: %s\n" "$nlwp"
            printf "  CPU............: %5s%%  %b\n" "$cpu" "$(barra_pct "$cpu")"
            printf "  RAM (RSS)......: %s MB (%s%%)  %b\n" \
                "$(( ${rss:-0} / 1024 ))" "$mem" "$(barra_pct "$mem")"
            echo -e "  ${CYAN}RSS deve estabilizar num platô. Subida contínua = leak.${NC}"
        fi
    fi
    echo ""

    echo -e "${BOLD}── Máquina ──────────────────────────────────${NC}"
    printf "  Núcleos........: %s\n" "$(nproc 2>/dev/null || echo '?')"
    printf "  Load (1/5/15m).: %s\n" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    local c; c=$(uso_cpu_total)
    printf "  CPU total......: %5s%%  %b\n" "$c" "$(barra_pct "$c")"

    local mt ma st sf
    mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)

    local mu=$(( mt - ma )) mp=0
    (( mt > 0 )) && mp=$(( mu * 100 / mt ))
    printf "  RAM............: %s / %s MB (%s%%)  %b\n" \
        "$(( mu / 1024 ))" "$(( mt / 1024 ))" "$mp" "$(barra_pct "$mp")"

    if (( st > 0 )); then
        local su=$(( st - sf )) sp=$(( (st - sf) * 100 / st ))
        printf "  Swap...........: %s / %s MB (%s%%)  %b\n" \
            "$(( su / 1024 ))" "$(( st / 1024 ))" "$sp" "$(barra_pct "$sp")"
    else
        printf "  Swap...........: ${RED}DESATIVADO${NC} (risco de OOM sem save)\n"
    fi

    local d; d=$(df -h --output=used,size,pcent "$SERVER_DIR" 2>/dev/null | tail -n1)
    if [[ -n "$d" ]]; then
        local du ds dp; read -r du ds dp <<< "$d"
        printf "  Disco..........: %s / %s (%s)  %b\n" "$du" "$ds" "$dp" "$(barra_pct "${dp%\%}")"
    fi
    printf "  Logs...........: %s\n" "$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo '?')"
    printf "  Rede...........: %s\n" "$(rede_taxa)"
}

acao_monitor() {
    echo ""
    echo -e "    ${GREEN}l${NC}) ao vivo (Ctrl+C para voltar)"
    echo -e "    ${GREEN}s${NC}) snapshot"
    echo -e "    ${GREEN}u${NC}) systemctl status (unit)"
    read -r -p "  Escolha [s]: " modo
    case "${modo:-s}" in
        l|L)
            trap 'echo; return' SIGINT
            while true; do clear; render_monitor
                echo -e "\n  ${YELLOW}Ctrl+C para voltar.${NC}"; done
            trap - SIGINT ;;
        u|U)
            echo ""; systemctl status "$SERVICE_NAME" --no-pager -n 30 2>/dev/null \
                || warn "Serviço não instalado."; pausar ;;
        *) echo ""; render_monitor; pausar ;;
    esac
}

# ============================================================
#  7. BACKUP DOS SAVES
# ============================================================
acao_backup() {
    mkdir -p "$BACKUP_DIR"
    local existentes=() d
    for d in "${SAVE_DIRS[@]}"; do
        [[ -d "$SERVER_DIR/$d" ]] && existentes+=("$d")
    done

    if (( ${#existentes[@]} == 0 )); then
        err "Nenhuma pasta de save encontrada em $SERVER_DIR"
        warn "Esperado: ${SAVE_DIRS[*]}. O servidor já rodou e salvou ao menos uma vez?"
        pausar; return
    fi

    local arq="$BACKUP_DIR/saves_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
    log "Compactando: ${existentes[*]}"
    if tar -czf "$arq" -C "$SERVER_DIR" "${existentes[@]}" 2>/dev/null; then
        ok "Backup: $arq ($(du -h "$arq" | cut -f1))"
    else
        err "Falha ao criar o backup."
        pausar; return
    fi

    # Mantém só os N mais recentes.
    local total
    total=$(ls -1t "$BACKUP_DIR"/saves_*.tar.gz 2>/dev/null | wc -l)
    if (( total > BACKUP_RETENTION )); then
        ls -1t "$BACKUP_DIR"/saves_*.tar.gz | tail -n +$(( BACKUP_RETENTION + 1 )) \
            | xargs -r rm -f
        log "Backups antigos removidos (mantidos $BACKUP_RETENTION)."
    fi

    echo ""
    echo -e "  Restaurar manualmente (${BOLD}com o servidor PARADO${NC}):"
    echo -e "    ${GREEN}tar -xzf $arq -C $SERVER_DIR${NC}"
    pausar
}

# ============================================================
#  8. DIAGNÓSTICO
# ============================================================
linha_diag() {
    local rotulo="$1" valor="$2" cor="${3:-$NC}"
    printf "  %-34s ${cor}%s${NC}\n" "$rotulo" "$valor"
}

acao_diagnostico() {
    clear
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║          DIAGNÓSTICO · DECAY                ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"

    # ── Arquivos de save ────────────────────────────────────
    echo -e "\n${BOLD}── Arquivos de save ─────────────────────────${NC}"
    local ws="$SERVER_DIR/WorldSaves/world_transforms.json"
    if [[ -f "$ws" ]]; then
        linha_diag "world_transforms.json" \
            "$(du -h "$ws" | cut -f1), $(date -r "$ws" '+%F %H:%M:%S')"
        local objs
        objs=$(grep -o '"worldObjectId"' "$ws" 2>/dev/null | wc -l)
        linha_diag "Objetos no save" "$objs"
    else
        linha_diag "world_transforms.json" "AUSENTE" "$RED"
    fi
    [[ -f "$ws.backup" ]] \
        && linha_diag "backup" "$(du -h "$ws.backup" | cut -f1), $(date -r "$ws.backup" '+%F %H:%M')" \
        || linha_diag "backup" "ausente" "$YELLOW"

    local tmps
    tmps=$(find "$SERVER_DIR" -name "*.tmp" 2>/dev/null | wc -l)
    (( tmps > 0 )) \
        && linha_diag ".tmp órfãos (crash na escrita)" "$tmps" "$RED" \
        || linha_diag ".tmp órfãos" "0"

    if [[ -d "$SERVER_DIR/PlayerSaves" ]]; then
        linha_diag "Saves de player" \
            "$(find "$SERVER_DIR/PlayerSaves" -name '*.json' 2>/dev/null | wc -l)"
        local corr
        corr=$(find "$SERVER_DIR/PlayerSaves" -name '*.corrupted_*' 2>/dev/null | wc -l)
        (( corr > 0 )) \
            && linha_diag "Saves CORROMPIDOS" "$corr" "$RED" \
            || linha_diag "Saves corrompidos" "0"
    fi

    # ── Marcadores no log ───────────────────────────────────
    echo -e "\n${BOLD}── Log da sessão atual ──────────────────────${NC}"
    if [[ ! -e "$CURRENT_LOG" ]]; then
        warn "Sem log de sessão ($CURRENT_LOG). O servidor já rodou com este script?"
        pausar; return
    fi
    linha_diag "Arquivo" "$(readlink -f "$CURRENT_LOG" | xargs basename)"

    echo -e "\n  ${BOLD}Saúde do save${NC}"
    local n
    n=$(contar "[WorldSave] Captura de" "$CURRENT_LOG")
    linha_diag "Saves de mundo concluídos" "$n" "$( ((n>0)) && echo "$GREEN" || echo "$YELLOW")"
    n=$(contar "Save RECUSADO" "$CURRENT_LOG")
    linha_diag "Saves recusados (queda de contagem)" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Salvar() adiado" "$CURRENT_LOG")
    linha_diag "Saves adiados (restauração)" "$n" "$( ((n>0)) && echo "$YELLOW" || echo "$GREEN")"
    n=$(contar "Restauração TRAVADA" "$CURRENT_LOG")
    linha_diag "Restauração travada" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "Save principal suspeito" "$CURRENT_LOG")
    linha_diag "Save principal suspeito" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"

    echo -e "\n  ${BOLD}Corpo duplicado / sessão${NC}"
    n=$(contar "reconectou pela conn" "$CURRENT_LOG")
    linha_diag "Conexões fantasma resolvidas" "$n" "$CYAN"
    n=$(contar "NÃO criado" "$CURRENT_LOG")
    linha_diag "Corpos recusados (esperado > 0)" "$n" "$CYAN"

    echo -e "\n  ${BOLD}Integridade de dados${NC}"
    n=$(contar "Valor INVÁLIDO" "$CURRENT_LOG")
    linha_diag "NaN/Infinity barrados" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "JSON corrompido" "$CURRENT_LOG")
    linha_diag "JSON corrompido" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "peça(s) órfã(s)" "$CURRENT_LOG")
    linha_diag "Podas de peças órfãs" "$n" "$YELLOW"

    echo -e "\n  ${BOLD}Rede${NC}"
    n=$(contar "because of exception" "$CURRENT_LOG")
    linha_diag "Disconnects por exceção (bug seu)" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"
    n=$(contar "NullReferenceException" "$CURRENT_LOG")
    linha_diag "NullReferenceException" "$n" "$( ((n>0)) && echo "$RED" || echo "$GREEN")"

    echo -e "\n${BOLD}── Últimas capturas (main thread) ───────────${NC}"
    grep -F "[WorldSave] Captura de" "$CURRENT_LOG" 2>/dev/null | tail -n 5 \
        | sed 's/^/  /' || echo "  (nenhuma ainda)"

    echo -e "\n${BOLD}── Config efetiva no boot ───────────────────${NC}"
    grep -F "SERVIDOR INICIADO" "$CURRENT_LOG" 2>/dev/null | tail -n 1 | sed 's/^/  /' \
        || echo "  (linha não encontrada)"

    echo -e "\n${BOLD}── Últimos erros ────────────────────────────${NC}"
    grep -E "^\s*\[?(WorldSave|Persistence|Net)?\]?.*(✘|ERRO|Error|Exception|RECUSADO|TRAVADA)" \
        "$CURRENT_LOG" 2>/dev/null | tail -n 8 | cut -c1-120 | sed 's/^/  /' \
        || echo "  (nenhum)"

    pausar
}

# ============================================================
#  MENU
# ============================================================
menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║         DECAY · PAINEL DO SERVIDOR          ║${NC}"
        echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════╝${NC}"
        echo -e "  ${SERVER_DIR}"
        echo -e "  Estado: $(status_curto)"
        esta_rodando && resumo_recursos
        echo ""
        echo "  1) Instalar / atualizar (permissões, swap, sysctl, unit)"
        echo "  2) Iniciar servidor"
        echo "  3) Parar servidor (aguarda o save final)"
        echo "  4) Reiniciar servidor"
        echo -e "  5) Console + Logs ${GREEN}(tmux)${NC}"
        echo "  6) Status & Monitor"
        echo -e "  7) Backup dos saves ${YELLOW}(antes de cada deploy)${NC}"
        echo -e "  8) Diagnóstico ${CYAN}(saúde do save e da rede)${NC}"
        echo "  0) Sair (servidor continua rodando)"
        echo ""
        read -r -p "  Escolha: " opt

        case "$opt" in
            1) acao_instalar ;;
            2) acao_iniciar ;;
            3) acao_parar ;;
            4) acao_reiniciar ;;
            5) acao_console ;;
            6) acao_monitor ;;
            7) acao_backup ;;
            8) acao_diagnostico ;;
            0) echo "Saindo. O servidor continua em segundo plano."; exit 0 ;;
            *) warn "Opção inválida."; sleep 1 ;;
        esac
    done
}

# ============================================================
case "${1:-}" in
    __run)     run_launcher ;;
    __prompt)  run_prompt ;;
    *)         menu ;;
esac